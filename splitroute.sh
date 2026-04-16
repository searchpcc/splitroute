#!/bin/bash
# splitroute — macOS VPN split tunneling CLI

set -u

SPLITROUTE_DIR="$HOME/.splitroute"
CONF="$SPLITROUTE_DIR/splitroute.conf"
LOG="/tmp/splitroute.log"
PLIST_LABEL="com.splitroute.watch"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# shellcheck source=splitroute-lib.sh
source "$SPLITROUTE_DIR/splitroute-lib.sh" 2>/dev/null || {
    echo "splitroute is not installed. See: https://github.com/searchpcc/splitroute"
    exit 1
}

# Optional PAC subsystem modules (present in v1+). Keep tolerant so the CLI
# still works on partial installs.
for _mod in splitroute-pac.sh splitroute-sysproxy.sh splitroute-resolver.sh; do
    # shellcheck source=/dev/null
    [ -f "$SPLITROUTE_DIR/$_mod" ] && source "$SPLITROUTE_DIR/$_mod"
done
unset _mod

get_version() {
    cat "$SPLITROUTE_DIR/VERSION" 2>/dev/null || echo "unknown"
}

# --- status ---

cmd_status() {
    local ver
    ver=$(get_version)
    echo "splitroute v$ver"
    echo ""

    # Service status
    if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
        echo "  Service    running"
    else
        echo "  Service    not running"
    fi

    # VPN status
    local vpn_if=""
    vpn_if=$(get_vpn_interface 2>/dev/null || true)

    if [ -n "$vpn_if" ]; then
        local vpn_gw
        vpn_gw=$(ifconfig "$vpn_if" 2>/dev/null | grep 'inet ' | awk '{print $4}')
        echo "  VPN        connected ($vpn_if${vpn_gw:+, gw $vpn_gw})"
    else
        echo "  VPN        not connected"
    fi

    # Load config for display
    if load_config "$CONF" 2>/dev/null; then
        # Proxy status
        if [ "$PROXY_ENABLED" = "true" ]; then
            echo "  Proxy      enabled (HTTP:$HTTP_PORT SOCKS:$SOCKS_PORT)"
        else
            echo "  Proxy      off"
        fi

        # Routes
        echo ""
        if [ ${#ROUTE_IPS[@]} -eq 0 ]; then
            echo "  Routes     (none configured)"
            echo ""
            echo "  Add routes: splitroute add <IP>"
        else
            echo "  Routes (${#ROUTE_IPS[@]}):"
            local route_table
            route_table=$(netstat -rn 2>/dev/null || true)
            for entry in "${ROUTE_IPS[@]}"; do
                if [ -n "$vpn_if" ] && echo "$route_table" | grep -Fw "$entry" | grep -qw "$vpn_if"; then
                    printf "    %-24s -> %-8s [OK]\n" "$entry" "$vpn_if"
                elif echo "$route_table" | grep -qFw "$entry"; then
                    # Route exists but points to wrong/old interface
                    local actual_if
                    actual_if=$(echo "$route_table" | grep -Fw "$entry" | awk '{print $NF}' | head -1)
                    printf "    %-24s -> %-8s [STALE]\n" "$entry" "$actual_if"
                else
                    printf "    %-24s    (inactive)\n" "$entry"
                fi
            done
        fi

        # PAC (browser split routing)
        if type pac_is_enabled >/dev/null 2>&1 && pac_is_enabled; then
            echo ""
            local pac_running=no pac_pid=""
            if pac_is_running; then
                pac_running=yes
                pac_pid=$(cat "$SPLITROUTE_PAC_PID" 2>/dev/null)
            fi
            echo "  PAC        enabled (port $PAC_PORT, ${#DOMAINS[@]} domain, ${#DOMAIN_IPS[@]} ip, ${#DNS_SUFFIXES[@]} dns)"
            echo "    URL      $(pac_url)"
            if [ "$pac_running" = "yes" ]; then
                echo "    Server   running (pid $pac_pid)"
            else
                echo "    Server   not running"
            fi
            if [ "${#DOMAINS[@]}" -gt 0 ]; then
                echo "    Domains:"
                for d in "${DOMAINS[@]}"; do
                    echo "      $d"
                done
            fi
            if [ "${#DOMAIN_IPS[@]}" -gt 0 ]; then
                echo "    IPs (PAC-only):"
                for d in "${DOMAIN_IPS[@]}"; do
                    echo "      $d"
                done
            fi
            if [ "${#DNS_SUFFIXES[@]}" -gt 0 ]; then
                echo "    DNS:"
                for i in $(seq 0 $((${#DNS_SUFFIXES[@]} - 1))); do
                    echo "      ${DNS_SUFFIXES[$i]} -> ${DNS_NAMESERVERS[$i]}"
                done
            fi
        fi
    else
        echo ""
        echo "  Config     $CONF not found"
        echo "  Run: splitroute edit"
    fi
    echo ""
}

# --- list ---

cmd_list() {
    if ! load_config "$CONF" 2>/dev/null; then
        echo "No config file. Run: splitroute edit"
        exit 1
    fi
    if [ ${#ROUTE_IPS[@]} -eq 0 ]; then
        echo "No routes configured. Add with: splitroute add <IP>"
        exit 0
    fi
    for entry in "${ROUTE_IPS[@]}"; do
        echo "$entry"
    done
}

# --- add ---

cmd_add() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: splitroute add <IP or CIDR>"
        echo "  e.g. splitroute add 10.0.1.100"
        echo "  e.g. splitroute add 192.168.0.0/16"
        exit 1
    fi
    if ! is_valid_route "$ip"; then
        echo "Invalid format: $ip"
        echo "Expected: IP address (10.0.1.100) or CIDR (192.168.0.0/16)"
        exit 1
    fi

    # Create config if it doesn't exist
    if [ ! -f "$CONF" ]; then
        mkdir -p "$SPLITROUTE_DIR"
        {
            echo "# splitroute configuration"
            echo ""
            echo "interface = auto"
            echo "proxy = false"
            echo "http_port = 7890"
            echo "socks_port = 7891"
            echo ""
            echo "# === Routes ==="
        } > "$CONF"
    fi

    if config_has_route "$ip" "$CONF"; then
        echo "$ip is already in the config"
        exit 0
    fi

    # Detect config format and add
    if grep -q 'ROUTE_IPS=(' "$CONF" 2>/dev/null; then
        # Legacy bash format: insert before closing )
        # Find the last ) in ROUTE_IPS block and insert before it
        sed -i '' '/^ROUTE_IPS=(/,/^)/ {
            /^)/ i\
\    "'"$ip"'"
        }' "$CONF"
    else
        # New simple format: append to end
        echo "$ip" >> "$CONF"
    fi

    echo "Added: $ip"
    echo "Takes effect on next VPN connection."
}

# --- remove ---

cmd_remove() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: splitroute remove <IP or CIDR>"
        exit 1
    fi

    if [ ! -f "$CONF" ]; then
        echo "No config file found"
        exit 1
    fi

    if ! config_has_route "$ip" "$CONF"; then
        echo "$ip is not in the config"
        exit 1
    fi

    if grep -q 'ROUTE_IPS=(' "$CONF" 2>/dev/null; then
        # Legacy format: remove line containing the IP (with quotes)
        sed -i '' "/\"$ip\"/d" "$CONF"
    else
        # New format: remove exact line
        # Escape / in CIDR for sed
        local escaped
        escaped=$(echo "$ip" | sed 's/\//\\\//g')
        sed -i '' "/^[[:space:]]*${escaped}[[:space:]]*$/d" "$CONF"
    fi

    echo "Removed: $ip"
    echo "Takes effect on next VPN connection."
}

# --- edit ---

cmd_edit() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$SPLITROUTE_DIR"
        cp "$SPLITROUTE_DIR/../splitroute.conf.example" "$CONF" 2>/dev/null || {
            # Generate minimal config
            {
                echo "# splitroute configuration"
                echo ""
                echo "interface = auto"
                echo "proxy = false"
                echo "http_port = 7890"
                echo "socks_port = 7891"
                echo ""
                echo "# === Routes ==="
            } > "$CONF"
        }
    fi
    ${EDITOR:-nano} "$CONF"
}

# --- test ---

cmd_test() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: splitroute test <IP>"
        echo "Check if an IP is routed through VPN."
        exit 1
    fi

    local result iface
    result=$(route -n get "$ip" 2>/dev/null) || {
        echo "Cannot get route for $ip"
        exit 1
    }
    iface=$(echo "$result" | grep 'interface:' | awk '{print $2}')

    if [[ "$iface" == ppp* ]] || [[ "$iface" == utun* ]]; then
        echo "$ip -> VPN ($iface)"
    else
        echo "$ip -> direct (${iface:-unknown})"
        if config_has_route "$ip" "$CONF" 2>/dev/null; then
            echo "  This IP is in your routes but VPN may not be connected."
        else
            echo "  Not in your routes. Add with: splitroute add $ip"
        fi
    fi
}

# --- logs ---

cmd_logs() {
    if [ -f "$LOG" ]; then
        tail -20 "$LOG"
    else
        echo "No logs yet. Connect VPN to generate log entries."
    fi
}

# --- version ---

cmd_version() {
    echo "splitroute $(get_version)"
}

# --- reload ---

cmd_reload() {
    if [ ! -f "$PLIST" ]; then
        echo "splitroute is not installed"
        exit 1
    fi
    local domain
    domain="gui/$(id -u)"
    launchctl bootout "$domain/$PLIST_LABEL" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null || true
    # bootout is async — wait for the label to actually be gone before
    # bootstrap, otherwise launchd returns EIO (Input/output error).
    launchd_wait_unload "$PLIST_LABEL" "$domain" || true
    if launchctl bootstrap "$domain" "$PLIST" 2>/dev/null; then
        echo "Service reloaded"
    elif launchctl load "$PLIST" 2>/dev/null; then
        echo "Service reloaded (legacy API)"
    else
        echo "Reload failed — service may still be shutting down. Retry in a moment,"
        echo "or run 'splitroute doctor' for diagnostics."
        return 1
    fi
}

# --- uninstall ---

cmd_uninstall() {
    echo "=== Uninstalling splitroute ==="
    # Stop service (SIGTERM to watch triggers full_teardown: sysproxy, PAC, resolver).
    local domain
    domain="gui/$(id -u)"
    launchctl bootout "$domain/$PLIST_LABEL" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null || true
    launchd_wait_unload "$PLIST_LABEL" "$domain" || true
    rm -f "$PLIST"

    # Belt-and-suspenders cleanup in case the trap didn't run.
    if type sysproxy_revert >/dev/null 2>&1; then
        sysproxy_revert 2>/dev/null || true
    fi
    if type pac_stop >/dev/null 2>&1; then
        pac_stop 2>/dev/null || true
    fi
    if [ -x /usr/local/bin/splitroute-priv ]; then
        sudo /usr/local/bin/splitroute-priv cleanup-resolver 2>/dev/null || true
    fi

    # Backup config
    if [ -f "$CONF" ]; then
        cp "$CONF" "$HOME/.splitroute.conf.bak"
        echo "Config backed up to ~/.splitroute.conf.bak"
    fi
    # Remove install directory
    rm -rf "$SPLITROUTE_DIR"
    # Remove CLI, privileged helper, and sudoers
    sudo rm -f /usr/local/bin/splitroute
    sudo rm -f /usr/local/bin/splitroute-priv
    sudo rm -f /etc/sudoers.d/splitroute
    echo "Done"
}

# --- doctor ---

cmd_doctor() {
    local fix=false
    if [ "${1:-}" = "--fix" ]; then
        fix=true
    fi

    local pass=0 fail=0 warn=0

    # 1. Daemon check
    printf "  [1/7] Daemon .............. "
    if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
        echo "running"
        pass=$((pass + 1))
    else
        echo "NOT running"
        fail=$((fail + 1))
        if $fix && [ -f "$PLIST" ]; then
            echo "        -> Fixing: restarting service"
            cmd_reload
        fi
    fi

    # 2. Config check
    printf "  [2/7] Config .............. "
    if load_config "$CONF" 2>/dev/null && [ ${#ROUTE_IPS[@]} -gt 0 ]; then
        echo "ok (${#ROUTE_IPS[@]} routes)"
        pass=$((pass + 1))
    elif [ ! -f "$CONF" ]; then
        echo "MISSING ($CONF)"
        fail=$((fail + 1))
        echo "        -> Run: splitroute edit"
    else
        echo "no routes configured"
        warn=$((warn + 1))
        echo "        -> Run: splitroute add <IP>"
    fi

    # 3. VPN check
    printf "  [3/7] VPN ................. "
    local vpn_if
    vpn_if=$(get_vpn_interface 2>/dev/null || true)
    if [ -n "$vpn_if" ]; then
        echo "connected ($vpn_if)"
        pass=$((pass + 1))
    else
        echo "NOT connected"
        fail=$((fail + 1))
        echo "        -> Connect your VPN first"
    fi

    # 4. Route table verification
    printf "  [4/7] Routes .............. "
    if [ -z "$vpn_if" ] || [ ${#ROUTE_IPS[@]} -eq 0 ]; then
        echo "skipped (no VPN or no routes)"
        warn=$((warn + 1))
    else
        local route_table ok_count stale_count missing_count
        route_table=$(netstat -rn 2>/dev/null || true)
        ok_count=0
        stale_count=0
        missing_count=0
        for entry in "${ROUTE_IPS[@]}"; do
            if echo "$route_table" | grep -Fw "$entry" | grep -qw "$vpn_if"; then
                ok_count=$((ok_count + 1))
            elif echo "$route_table" | grep -qFw "$entry"; then
                stale_count=$((stale_count + 1))
            else
                missing_count=$((missing_count + 1))
            fi
        done
        if [ $stale_count -eq 0 ] && [ $missing_count -eq 0 ]; then
            echo "all ${ok_count} routes OK on $vpn_if"
            pass=$((pass + 1))
        else
            echo "${ok_count} ok, ${stale_count} stale, ${missing_count} missing"
            fail=$((fail + 1))
            if $fix; then
                echo "        -> Fixing: re-applying routes"
                bash "$SPLITROUTE_DIR/splitroute-routes.sh" 2>/dev/null
            else
                echo "        -> Run: splitroute doctor --fix"
            fi
        fi
    fi

    # 5. Connectivity test (first route)
    printf "  [5/7] Connectivity ........ "
    if [ -z "$vpn_if" ] || [ ${#ROUTE_IPS[@]} -eq 0 ]; then
        echo "skipped"
        warn=$((warn + 1))
    else
        local test_ip="${ROUTE_IPS[0]}"
        # Strip CIDR for ping test
        test_ip="${test_ip%%/*}"
        local result_if
        result_if=$(route -n get "$test_ip" 2>/dev/null | grep 'interface:' | awk '{print $2}')
        if [ "$result_if" = "$vpn_if" ]; then
            echo "ok ($test_ip -> $vpn_if)"
            pass=$((pass + 1))
        else
            echo "$test_ip -> ${result_if:-unknown} (expected $vpn_if)"
            fail=$((fail + 1))
        fi
    fi

    # 6. Proxy listener (only when legacy proxy bridging is enabled)
    printf "  [6/7] Proxy listener ...... "
    if [ "$PROXY_ENABLED" != "true" ]; then
        echo "skipped (proxy bridging disabled)"
        warn=$((warn + 1))
    else
        local ports_to_check
        if [ "$HTTP_PORT" = "$SOCKS_PORT" ]; then
            ports_to_check="$HTTP_PORT"
        else
            ports_to_check="$HTTP_PORT $SOCKS_PORT"
        fi
        local missing=()
        for p in $ports_to_check; do
            if ! nc -z -G 1 127.0.0.1 "$p" 2>/dev/null; then
                missing+=("$p")
            fi
        done
        if [ ${#missing[@]} -eq 0 ]; then
            echo "ok ($ports_to_check listening)"
            pass=$((pass + 1))
        else
            echo "no listener on ${missing[*]}"
            fail=$((fail + 1))
            echo "        -> Start your proxy tool, or run 'splitroute edit' to adjust ports"
        fi
    fi

    # 7. PAC server + autoproxy (only when PAC enabled)
    printf "  [7/7] PAC server .......... "
    if ! type pac_is_enabled >/dev/null 2>&1 || ! pac_is_enabled; then
        echo "skipped (PAC disabled)"
        warn=$((warn + 1))
    else
        local pac_ok=true
        if ! pac_is_running; then
            echo "server not running"
            fail=$((fail + 1))
            pac_ok=false
        elif ! curl -fsS --max-time 1 "http://127.0.0.1:$PAC_PORT/proxy.pac" >/dev/null 2>&1; then
            echo "server unreachable on $PAC_PORT"
            fail=$((fail + 1))
            pac_ok=false
        fi
        if $pac_ok; then
            # Check at least one service has autoproxy pointing to us
            local any_svc="" url_svc
            while IFS= read -r svc; do
                [ -n "$svc" ] || continue
                url_svc=$(networksetup -getautoproxyurl "$svc" 2>/dev/null | awk -F': ' '/^URL:/{print $2}')
                if [ "${url_svc%%\?*}" = "http://127.0.0.1:$PAC_PORT/proxy.pac" ]; then
                    any_svc="$svc"
                    break
                fi
            done < <(active_network_services)
            if [ -n "$any_svc" ]; then
                echo "ok (${#DOMAINS[@]} domain, ${#DOMAIN_IPS[@]} ip, ${#DNS_SUFFIXES[@]} dns)"
                pass=$((pass + 1))
            else
                echo "autoproxy not set on any service"
                fail=$((fail + 1))
                if $fix; then
                    echo "        -> Fixing: setting autoproxy URL"
                    sysproxy_apply "$(pac_url)?v=$(pac_mtime)" >/dev/null 2>&1 || true
                else
                    echo "        -> Run: splitroute doctor --fix  (or: splitroute reload)"
                fi
            fi
        fi
    fi

    echo ""
    echo "  Result: $pass passed, $fail failed, $warn skipped"
    if [ $fail -gt 0 ] && ! $fix; then
        echo "  Run 'splitroute doctor --fix' to attempt auto-repair"
    fi
    return $fail
}

# --- apply ---

cmd_apply() {
    local vpn_if
    vpn_if=$(get_vpn_interface 2>/dev/null || true)
    if [ -z "$vpn_if" ]; then
        echo "No VPN connection detected"
        exit 1
    fi
    echo "Applying routes on $vpn_if ..."
    if bash "$SPLITROUTE_DIR/splitroute-routes.sh"; then
        echo "Done. Run 'splitroute status' to verify."
    else
        echo "Route script exited with error. Check: splitroute logs"
        exit 1
    fi
}

# --- domain ---

_is_legacy_conf() {
    [ -f "$CONF" ] && grep -q 'ROUTE_IPS=(' "$CONF" 2>/dev/null
}

_require_new_format() {
    if _is_legacy_conf; then
        echo "Your $CONF uses the legacy bash format, which does not support"
        echo "domain/dns rules. Run 'splitroute edit' and convert to the new"
        echo "simple format, or remove the legacy ROUTE_IPS=(...) block."
        exit 1
    fi
}

_ensure_conf() {
    if [ ! -f "$CONF" ]; then
        mkdir -p "$SPLITROUTE_DIR"
        {
            echo "# splitroute configuration"
            echo ""
            echo "interface = auto"
            echo "proxy = false"
            echo "http_port = 7890"
            echo "socks_port = 7891"
            echo ""
            echo "# === Routes ==="
        } > "$CONF"
    fi
}

cmd_domain() {
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add|a)        _cmd_domain_add "${1:-}" ;;
        remove|rm|r)  _cmd_domain_remove "${1:-}" ;;
        list|ls|"")   _cmd_domain_list ;;
        *)
            echo "Usage: splitroute domain {add|remove|list} [pattern-or-IP]"
            exit 1 ;;
    esac
}

_cmd_domain_add() {
    local pattern="${1:-}"
    [ -z "$pattern" ] && { echo "Usage: splitroute domain add <pattern-or-IP>"; exit 1; }
    _require_new_format
    _ensure_conf
    load_config "$CONF" 2>/dev/null || true
    local d
    for d in "${DOMAINS[@]+"${DOMAINS[@]}"}" "${DOMAIN_IPS[@]+"${DOMAIN_IPS[@]}"}"; do
        if [ "$d" = "$pattern" ]; then
            echo "Already present: $pattern"
            exit 0
        fi
    done
    echo "domain: $pattern" >> "$CONF"
    if is_valid_route "$pattern"; then
        echo "Added domain IP: $pattern (PAC-only; use \`splitroute add\` if you also need a route)"
    else
        echo "Added domain: $pattern"
    fi
    echo "Takes effect within 30s (watch hot-reloads config)."
}

_cmd_domain_remove() {
    local pattern="${1:-}"
    [ -z "$pattern" ] && { echo "Usage: splitroute domain remove <pattern>"; exit 1; }
    [ -f "$CONF" ] || { echo "No config file"; exit 1; }
    _require_new_format
    local tmp="$CONF.tmp.$$"
    awk -v pat="$pattern" '
        {
            raw = $0
            l = $0
            sub(/#.*/, "", l)
            gsub(/^[ \t]+|[ \t]+$/, "", l)
            if (index(l, "domain:") == 1) {
                val = substr(l, length("domain:") + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", val)
                if (val == pat) next
            }
            print raw
        }
    ' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    echo "Removed domain: $pattern"
}

_cmd_domain_list() {
    load_config "$CONF" 2>/dev/null || { echo "No config"; return; }
    if [ "${#DOMAINS[@]}" -eq 0 ] && [ "${#DOMAIN_IPS[@]}" -eq 0 ]; then
        echo "(no domain rules)"
        return
    fi
    local d
    if [ "${#DOMAINS[@]}" -gt 0 ]; then
        echo "# Domain patterns (PAC shExpMatch)"
        for d in "${DOMAINS[@]}"; do
            echo "$d"
        done
    fi
    if [ "${#DOMAIN_IPS[@]}" -gt 0 ]; then
        [ "${#DOMAINS[@]}" -gt 0 ] && echo ""
        echo "# IP rules (PAC isInNet, no macOS route)"
        for d in "${DOMAIN_IPS[@]}"; do
            echo "$d"
        done
    fi
}

# --- dns ---

cmd_dns() {
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add|a)        _cmd_dns_add "$@" ;;
        remove|rm|r)  _cmd_dns_remove "${1:-}" ;;
        list|ls|"")   _cmd_dns_list ;;
        *)
            echo "Usage: splitroute dns {add <suffix> [<ns>|auto] | remove <suffix> | list}"
            exit 1 ;;
    esac
}

_cmd_dns_add() {
    local suffix="${1:-}" ns="${2:-auto}"
    [ -z "$suffix" ] && { echo "Usage: splitroute dns add <suffix> [<ns>|auto]"; exit 1; }
    _require_new_format
    _ensure_conf
    load_config "$CONF" 2>/dev/null || true
    local i
    for (( i = 0; i < ${#DNS_SUFFIXES[@]}; i++ )); do
        if [ "${DNS_SUFFIXES[$i]}" = "$suffix" ]; then
            echo "Already present: $suffix -> ${DNS_NAMESERVERS[$i]}"
            exit 0
        fi
    done
    echo "dns: $suffix $ns" >> "$CONF"
    echo "Added dns: $suffix -> $ns"
}

_cmd_dns_remove() {
    local suffix="${1:-}"
    [ -z "$suffix" ] && { echo "Usage: splitroute dns remove <suffix>"; exit 1; }
    [ -f "$CONF" ] || { echo "No config file"; exit 1; }
    _require_new_format
    local tmp="$CONF.tmp.$$"
    awk -v pat="$suffix" '
        {
            raw = $0
            l = $0
            sub(/#.*/, "", l)
            gsub(/^[ \t]+|[ \t]+$/, "", l)
            if (index(l, "dns:") == 1) {
                val = substr(l, length("dns:") + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", val)
                n = index(val, " ")
                if (n > 0) val = substr(val, 1, n - 1)
                if (val == pat) next
            }
            print raw
        }
    ' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    echo "Removed dns: $suffix"
}

_cmd_dns_list() {
    load_config "$CONF" 2>/dev/null || { echo "No config"; return; }
    if [ "${#DNS_SUFFIXES[@]}" -eq 0 ]; then
        echo "(no dns rules)"
        return
    fi
    local i
    for (( i = 0; i < ${#DNS_SUFFIXES[@]}; i++ )); do
        echo "${DNS_SUFFIXES[$i]} ${DNS_NAMESERVERS[$i]}"
    done
}

# --- pac ---

cmd_pac() {
    local sub="${1:-status}"
    case "$sub" in
        url)
            load_config "$CONF" 2>/dev/null || true
            echo "$(pac_url)?v=$(pac_mtime)"
            ;;
        show|cat)
            if [ -f "$SPLITROUTE_PAC_FILE" ]; then
                cat "$SPLITROUTE_PAC_FILE"
            else
                echo "PAC file not generated yet: $SPLITROUTE_PAC_FILE"
            fi
            ;;
        status|"")
            load_config "$CONF" 2>/dev/null || true
            if pac_is_enabled; then
                echo "PAC:     enabled"
                echo "URL:     $(pac_url)"
                echo "File:    $SPLITROUTE_PAC_FILE"
                if pac_is_running; then
                    echo "Server:  running (pid $(cat "$SPLITROUTE_PAC_PID"))"
                else
                    echo "Server:  NOT running"
                fi
                echo "Domains: ${#DOMAINS[@]}"
                echo "IPs:     ${#DOMAIN_IPS[@]} (PAC-only)"
                echo "DNS:     ${#DNS_SUFFIXES[@]}"
            else
                echo "PAC disabled (add 'domain:' or 'dns:' lines to enable)"
            fi
            ;;
        *)
            echo "Usage: splitroute pac {url|show|status}"
            exit 1 ;;
    esac
}

# --- help ---

cmd_help() {
    local ver
    ver=$(get_version)
    echo "splitroute $ver — macOS VPN split tunneling"
    echo ""
    echo "Usage: splitroute <command>"
    echo ""
    echo "Getting started:"
    echo "  add <IP>              Add an IP or subnet to route through VPN"
    echo "  remove <IP>           Remove an IP or subnet from routes"
    echo "  list                  List all configured routes"
    echo "  edit                  Open config file in editor"
    echo ""
    echo "Browser split routing (PAC):"
    echo "  domain add <pat|IP>   Add a domain pattern or IPv4/CIDR (browser via VPN; PAC only)"
    echo "  domain remove <pat>   Remove a domain pattern or IP"
    echo "  domain list           List domain patterns and PAC-only IPs"
    echo "  dns add <suffix> [ns] Map an internal DNS suffix to a nameserver (or 'auto')"
    echo "  dns remove <suffix>   Remove a DNS override"
    echo "  dns list              List DNS overrides"
    echo "  pac [url|show|status] Inspect the PAC endpoint and file"
    echo ""
    echo "Diagnostics:"
    echo "  status                Show service, VPN, route, and PAC status"
    echo "  doctor [--fix]        Run diagnostic (optional auto-fix)"
    echo "  test <IP>             Check how an IP is currently routed"
    echo "  logs                  Show recent log entries"
    echo ""
    echo "Management:"
    echo "  apply                 Manually inject routes now"
    echo "  reload                Restart the background service"
    echo "  uninstall             Uninstall splitroute"
    echo "  version               Show version"
    echo "  help                  Show this help"
    echo ""
    echo "Config: $CONF"
}

# --- main ---

case "${1:-help}" in
    status)               cmd_status ;;
    list|ls)              cmd_list ;;
    add)                  cmd_add "${2:-}" ;;
    remove|rm)            cmd_remove "${2:-}" ;;
    edit)                 cmd_edit ;;
    test)                 cmd_test "${2:-}" ;;
    doctor)               cmd_doctor "${2:-}" ;;
    apply)                cmd_apply ;;
    logs|log)             cmd_logs ;;
    version|--version|-v) cmd_version ;;
    reload)               cmd_reload ;;
    uninstall)            cmd_uninstall ;;
    domain)               shift; cmd_domain "$@" ;;
    dns)                  shift; cmd_dns "$@" ;;
    pac)                  shift; cmd_pac "$@" ;;
    help|--help|-h)       cmd_help ;;
    *)                    echo "Unknown command: $1"; echo ""; cmd_help; exit 1 ;;
esac
