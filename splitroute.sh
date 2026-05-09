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
for _mod in splitroute-pac.sh splitroute-sysproxy.sh splitroute-resolver.sh splitroute-hosts.sh; do
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
            echo "  PAC        enabled (port $PAC_PORT, ${#DOMAINS[@]} domain, ${#HOSTS[@]} host, ${#DOMAIN_IPS[@]} ip, ${#DNS_SUFFIXES[@]} dns)"
            echo "    URL      $(pac_url)"
            if [ "$pac_running" = "yes" ]; then
                echo "    Server   running (pid $pac_pid)"
            else
                echo "    Server   not running"
            fi
            if [ "${#HOSTS[@]}" -gt 0 ]; then
                echo "    Hosts:"
                # Pull current resolved IPs from the watch loop's state file.
                local hosts_state="" hi hfixed hips htag
                if type hosts_state_dump >/dev/null 2>&1; then
                    hosts_state=$(hosts_state_dump 2>/dev/null || true)
                fi
                for (( hi = 0; hi < ${#HOSTS[@]}; hi++ )); do
                    d="${HOSTS[$hi]}"
                    hfixed="${HOST_FIXED_IPS[$hi]:-}"
                    hips=""
                    if [ -n "$hosts_state" ]; then
                        hips=$(echo "$hosts_state" | awk -F'\t' -v hh="$d" '$1==hh{print $2}' | paste -sd ',' -)
                    fi
                    if [ -n "$hfixed" ]; then
                        htag="[$hfixed]  (pinned)"
                    elif [ -n "$hips" ]; then
                        htag="[$hips]"
                    else
                        htag="(unresolved)"
                    fi
                    printf "      %-32s %s\n" "$d" "$htag"
                done
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
    local total=$(( ${#ROUTE_IPS[@]} + ${#HOSTS[@]} + ${#DOMAINS[@]} + ${#DOMAIN_IPS[@]} ))
    if [ "$total" -eq 0 ]; then
        echo "Nothing configured. Add with: splitroute add <IP|hostname|*.pattern>"
        exit 0
    fi
    if [ "${#ROUTE_IPS[@]}" -gt 0 ]; then
        echo "# Routes (IP/CIDR)"
        for entry in "${ROUTE_IPS[@]}"; do
            echo "$entry"
        done
    fi
    if [ "${#HOSTS[@]}" -gt 0 ]; then
        [ "${#ROUTE_IPS[@]}" -gt 0 ] && echo ""
        echo "# Hosts (PAC + DNS + route)"
        for entry in "${HOSTS[@]}"; do
            echo "$entry"
        done
    fi
    if [ "${#DOMAINS[@]}" -gt 0 ]; then
        echo ""
        echo "# Domain patterns (PAC only)"
        for entry in "${DOMAINS[@]}"; do
            echo "$entry"
        done
    fi
    if [ "${#DOMAIN_IPS[@]}" -gt 0 ]; then
        echo ""
        echo "# IPs (PAC only)"
        for entry in "${DOMAIN_IPS[@]}"; do
            echo "$entry"
        done
    fi
}

# --- add ---
#
# Smart dispatcher: one verb covers every target type so users don't have to
# remember `add` vs `domain add` vs `dns add`.
#   IP / CIDR        -> ROUTE_IPS (route table)
#   *.pattern        -> domain:  (PAC shExpMatch only)
#   bare hostname    -> host:    (PAC + auto-DNS suffix + route after resolve)

cmd_add() {
    # Parse positional args + flags. Flags may appear in any position.
    # Positional 1: target (IP/CIDR/hostname/pattern)
    # Positional 2: optional fixed IP (only meaningful with hostname target)
    local input="" extra="" no_auto_dns=false arg
    for arg in "$@"; do
        case "$arg" in
            --no-auto-dns|--no-dns)
                no_auto_dns=true ;;
            --*)
                echo "Unknown flag: $arg"
                exit 1 ;;
            *)
                if [ -z "$input" ]; then
                    input="$arg"
                elif [ -z "$extra" ]; then
                    extra="$arg"
                else
                    echo "Too many arguments: $arg"
                    exit 1
                fi ;;
        esac
    done

    if [ -z "$input" ]; then
        cat <<'EOF'
Usage: splitroute add <target> [ip] [--no-auto-dns]

Target forms:
  10.0.1.100                            IP — route table
  192.168.0.0/16                        CIDR — route table
  git.addnewer.com                      hostname — browser + ssh/git via VPN
                                          (auto-resolves; auto-adds dns: parent_suffix)
  git.addnewer.com 10.0.1.5             hostname + fixed IP — pinned via /etc/hosts
                                          (no DNS lookup; auto-DNS suffix not added)
  '*.corp.internal'                     wildcard — browser-only PAC pattern

Flags:
  --no-auto-dns    Don't auto-add `dns: <parent_suffix> auto` for hostname targets.
                   Use when you want to manage DNS for the parent suffix manually,
                   or you don't want the suffix's other subdomains to resolve via VPN DNS.
EOF
        exit 1
    fi

    if is_valid_route "$input"; then
        if [ -n "$extra" ]; then
            echo "Extra argument '$extra' is only valid when the target is a hostname."
            exit 1
        fi
        _cmd_add_route "$input"
    elif [[ "$input" == *\** ]] || [[ "$input" == *\?* ]]; then
        if [ -n "$extra" ]; then
            echo "Extra argument '$extra' is only valid when the target is a hostname."
            exit 1
        fi
        _cmd_add_pattern "$input"
    elif is_valid_hostname "$input"; then
        if [ -n "$extra" ]; then
            if ! is_valid_route "$extra" || [[ "$extra" == */* ]]; then
                echo "Invalid IP for host: $extra"
                echo "Expected an IPv4 address (no CIDR)."
                exit 1
            fi
            _cmd_add_host "$input" "$extra" "$no_auto_dns"
        else
            _cmd_add_host "$input" "" "$no_auto_dns"
        fi
    else
        echo "Unrecognized target: $input"
        echo "Expected an IP, CIDR, hostname, or *.wildcard pattern."
        exit 1
    fi
}

_cmd_add_route() {
    local ip="$1"
    _ensure_conf
    if config_has_route "$ip" "$CONF"; then
        echo "$ip is already in the config"
        exit 0
    fi
    if grep -q 'ROUTE_IPS=(' "$CONF" 2>/dev/null; then
        sed -i '' '/^ROUTE_IPS=(/,/^)/ {
            /^)/ i\
\    "'"$ip"'"
        }' "$CONF"
    else
        echo "$ip" >> "$CONF"
    fi
    echo "Added route: $ip"
    echo "Takes effect on next VPN connection."
}

_cmd_add_pattern() {
    local pattern="$1"
    _require_new_format
    _ensure_conf
    load_config "$CONF" 2>/dev/null || true
    local d
    for d in "${DOMAINS[@]+"${DOMAINS[@]}"}"; do
        if [ "$d" = "$pattern" ]; then
            echo "Already present: $pattern"
            exit 0
        fi
    done
    echo "domain: $pattern" >> "$CONF"
    echo "Added pattern: $pattern  (browser only — PAC shExpMatch)"
    echo "Takes effect within 30s (watch hot-reloads config)."
}

# Append a host: line. With an explicit IP, the watch loop pins it via
# /etc/hosts and skips DNS entirely. Without one, the parent DNS suffix is
# auto-added so DIRECT lookups go through VPN-pushed DNS, and the watch
# loop dynamically resolves the hostname.
_cmd_add_host() {
    local host="$1" ip="${2:-}" no_auto_dns="${3:-false}"
    _require_new_format
    _ensure_conf
    load_config "$CONF" 2>/dev/null || true

    local i
    for (( i = 0; i < ${#HOSTS[@]}; i++ )); do
        if [ "${HOSTS[$i]}" = "$host" ]; then
            echo "Already present: $host${HOST_FIXED_IPS[$i]:+ -> ${HOST_FIXED_IPS[$i]}}"
            exit 0
        fi
    done

    if [ -n "$ip" ]; then
        echo "host: $host $ip" >> "$CONF"
        echo "Added host: $host -> $ip  (pinned via /etc/hosts; no DNS lookup needed)"
        echo "Takes effect within 30s after VPN connects."
        return 0
    fi

    echo "host: $host" >> "$CONF"
    echo "Added host: $host"

    if [ "$no_auto_dns" = "true" ]; then
        echo "Skipping auto-DNS suffix (--no-auto-dns).  You must ensure $host resolves to the VPN-side IP yourself."
    else
        local suffix
        suffix=$(derive_parent_suffix "$host" 2>/dev/null || true)
        if [ -n "$suffix" ]; then
            local s have=0
            for s in "${DNS_SUFFIXES[@]+"${DNS_SUFFIXES[@]}"}"; do
                if [ "$s" = "$suffix" ]; then have=1; break; fi
            done
            if [ "$have" = "0" ]; then
                echo "dns: $suffix auto" >> "$CONF"
                echo "Added dns: $suffix auto  (so DIRECT lookups use VPN-pushed DNS — pass --no-auto-dns to skip)"
            fi
        fi
    fi

    echo "Takes effect within 30s after VPN connects (hostname is resolved over VPN DNS)."
}

# --- remove ---

cmd_remove() {
    local input="${1:-}"
    if [ -z "$input" ]; then
        echo "Usage: splitroute remove <IP | CIDR | hostname | pattern>"
        exit 1
    fi
    if [ ! -f "$CONF" ]; then
        echo "No config file found"
        exit 1
    fi

    if is_valid_route "$input"; then
        _cmd_remove_route "$input"
    elif [[ "$input" == *\** ]] || [[ "$input" == *\?* ]]; then
        _cmd_domain_remove "$input"
    elif is_valid_hostname "$input"; then
        _cmd_remove_host "$input"
    else
        echo "Unrecognized target: $input"
        exit 1
    fi
}

_cmd_remove_route() {
    local ip="$1"
    if ! config_has_route "$ip" "$CONF"; then
        echo "$ip is not in the config"
        exit 1
    fi
    if grep -q 'ROUTE_IPS=(' "$CONF" 2>/dev/null; then
        sed -i '' "/\"$ip\"/d" "$CONF"
    else
        local escaped
        escaped=$(echo "$ip" | sed 's/\//\\\//g')
        sed -i '' "/^[[:space:]]*${escaped}[[:space:]]*$/d" "$CONF"
    fi
    echo "Removed route: $ip"
    echo "Takes effect on next VPN connection."
}

_cmd_remove_host() {
    local host="$1"
    _require_new_format
    load_config "$CONF" 2>/dev/null || true
    local h found=0
    for h in "${HOSTS[@]+"${HOSTS[@]}"}"; do
        [ "$h" = "$host" ] && { found=1; break; }
    done
    if [ "$found" = "0" ]; then
        echo "Not in config: $host"
        exit 1
    fi
    local tmp="$CONF.tmp.$$"
    awk -v pat="$host" '
        {
            raw = $0
            l = $0
            sub(/#.*/, "", l)
            gsub(/^[ \t]+|[ \t]+$/, "", l)
            if (index(l, "host:") == 1) {
                val = substr(l, length("host:") + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", val)
                # Match on first whitespace-separated token (the hostname),
                # so `host: name ip` lines remove correctly too.
                n = index(val, " ")
                if (n == 0) n = index(val, "\t")
                name = (n > 0) ? substr(val, 1, n - 1) : val
                if (name == pat) next
            }
            print raw
        }
    ' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    echo "Removed host: $host"

    # If the auto-added dns: parent suffix is now orphaned (no remaining
    # host: under it), drop it too. Manually-added dns: rules survive.
    local suffix
    suffix=$(derive_parent_suffix "$host" 2>/dev/null || true)
    [ -z "$suffix" ] && return 0
    load_config "$CONF" 2>/dev/null || true
    local still h2
    still=0
    for h2 in "${HOSTS[@]+"${HOSTS[@]}"}"; do
        if [ "$(derive_parent_suffix "$h2" 2>/dev/null)" = "$suffix" ]; then
            still=1
            break
        fi
    done
    if [ "$still" = "0" ]; then
        local i ns_for=""
        for (( i = 0; i < ${#DNS_SUFFIXES[@]}; i++ )); do
            if [ "${DNS_SUFFIXES[$i]}" = "$suffix" ]; then
                ns_for="${DNS_NAMESERVERS[$i]}"
                break
            fi
        done
        if [ "$ns_for" = "auto" ]; then
            tmp="$CONF.tmp.$$"
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
            echo "Removed orphaned dns: $suffix"
        fi
    fi
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
    local target="${1:-}"
    if [ -z "$target" ]; then
        echo "Usage: splitroute test <IP | hostname>"
        echo "Check if a target is routed through VPN."
        exit 1
    fi

    local ips=""
    if is_valid_route "$target"; then
        ips="${target%%/*}"
    else
        # Resolve hostname to IPs (tries dig then getent).
        if command -v dig >/dev/null 2>&1; then
            ips=$(dig +short +time=2 +tries=1 "$target" A 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        fi
        if [ -z "$ips" ]; then
            ips=$(getent hosts "$target" 2>/dev/null \
                | awk '{print $1}' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        fi
        if [ -z "$ips" ]; then
            echo "Cannot resolve $target"
            echo "  If this is an internal host, connect VPN first."
            exit 1
        fi
        echo "$target resolves to:"
        echo "$ips" | sed 's/^/  /'
    fi

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        local result iface
        result=$(route -n get "$ip" 2>/dev/null) || {
            echo "$ip: cannot get route"
            continue
        }
        iface=$(echo "$result" | grep 'interface:' | awk '{print $2}')
        if [[ "$iface" == ppp* ]] || [[ "$iface" == utun* ]]; then
            echo "$ip -> VPN ($iface)"
        else
            echo "$ip -> direct (${iface:-unknown})"
            if config_has_route "$ip" "$CONF" 2>/dev/null; then
                echo "  In routes, but VPN may not be connected."
            elif ! is_valid_route "$target"; then
                echo "  (resolved from $target — VPN may not be connected, or hostname not yet routed)"
            fi
        fi
    done <<< "$ips"
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

    # Decide up front whether to back up. Interactive: ask, default Yes.
    # Non-interactive: always back up (preserves prior behavior).
    local backup_path="$HOME/.splitroute.conf.bak"
    local do_backup=true
    if [ -f "$CONF" ] && [ -t 0 ] && [ -t 1 ]; then
        echo ""
        echo "Your config will be deleted along with the install:"
        echo "  $CONF"
        local reply
        read -rp "Save a backup to $backup_path? [Y/n]: " reply
        reply="${reply:-y}"
        if [[ ! "$reply" =~ ^[Yy] ]]; then
            do_backup=false
        fi
        echo ""
    fi

    # Stop service (SIGTERM to watch triggers full_teardown: sysproxy, PAC, resolver, hosts).
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
        sudo /usr/local/bin/splitroute-priv hosts-cleanup    2>/dev/null || true
    fi

    # Back up config (rotate any existing .bak so repeated uninstall cycles
    # don't clobber the older save).
    if [ -f "$CONF" ] && $do_backup; then
        if [ -f "$backup_path" ]; then
            local ts
            ts=$(date +%Y%m%d-%H%M%S)
            mv "$backup_path" "${backup_path}.${ts}"
            echo "Previous backup rotated to ${backup_path}.${ts}"
        fi
        cp "$CONF" "$backup_path"
        echo "Config backed up to $backup_path"
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
    printf "  [1/8] Daemon .............. "
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
    printf "  [2/8] Config .............. "
    if load_config "$CONF" 2>/dev/null; then
        local total=$(( ${#ROUTE_IPS[@]} + ${#HOSTS[@]} + ${#DOMAINS[@]} + ${#DOMAIN_IPS[@]} ))
        if [ "$total" -gt 0 ]; then
            echo "ok (${#ROUTE_IPS[@]} routes, ${#HOSTS[@]} hosts, ${#DOMAINS[@]} domains, ${#DNS_SUFFIXES[@]} dns)"
            pass=$((pass + 1))
        else
            echo "no routes/hosts configured"
            warn=$((warn + 1))
            echo "        -> Run: splitroute add <target>"
        fi
    elif [ ! -f "$CONF" ]; then
        echo "MISSING ($CONF)"
        fail=$((fail + 1))
        echo "        -> Run: splitroute edit"
    else
        echo "load failed"
        fail=$((fail + 1))
    fi

    # 3. VPN check
    printf "  [3/8] VPN ................. "
    local vpn_if vpn_gw
    vpn_if=$(get_vpn_interface 2>/dev/null || true)
    if [ -n "$vpn_if" ]; then
        vpn_gw=$(get_vpn_gateway "$vpn_if" 2>/dev/null || true)
        if [ -n "$vpn_gw" ]; then
            echo "connected ($vpn_if, peer $vpn_gw)"
        else
            echo "connected ($vpn_if, no distinct peer — utun-style)"
        fi
        pass=$((pass + 1))
    else
        echo "NOT connected"
        fail=$((fail + 1))
        echo "        -> Connect your VPN first"
    fi

    # 4. Route table verification + IFSCOPE detection
    printf "  [4/8] Routes .............. "
    if [ -z "$vpn_if" ] || [ ${#ROUTE_IPS[@]} -eq 0 ]; then
        echo "skipped (no VPN or no IP/CIDR routes)"
        warn=$((warn + 1))
    else
        local route_table ok_count stale_count missing_count ifscope_count flags
        route_table=$(netstat -rn -f inet 2>/dev/null || true)
        ok_count=0
        stale_count=0
        missing_count=0
        ifscope_count=0
        for entry in "${ROUTE_IPS[@]}"; do
            # netstat field 3 is the flags column; 'I' = IFSCOPE
            flags=$(echo "$route_table" | awk -v ip="$entry" -v iface="$vpn_if" \
                '$1==ip && $NF==iface{print $3; exit}')
            if [ -n "$flags" ]; then
                ok_count=$((ok_count + 1))
                [[ "$flags" == *I* ]] && ifscope_count=$((ifscope_count + 1))
            elif echo "$route_table" | grep -qFw "$entry"; then
                stale_count=$((stale_count + 1))
            else
                missing_count=$((missing_count + 1))
            fi
        done
        if [ $stale_count -eq 0 ] && [ $missing_count -eq 0 ] && [ $ifscope_count -eq 0 ]; then
            echo "all ${ok_count} routes OK on $vpn_if"
            pass=$((pass + 1))
        elif [ $ifscope_count -gt 0 ] && [ $stale_count -eq 0 ] && [ $missing_count -eq 0 ]; then
            echo "${ok_count} routes present, but ${ifscope_count} are IFSCOPE'd (legacy)"
            fail=$((fail + 1))
            echo "        IFSCOPE routes are scoped to the VPN interface and invisible"
            echo "        to apps that aren't bound to it (ssh/curl/git fall through to en0)."
            if $fix; then
                echo "        -> Fixing: re-installing routes via peer gateway"
                bash "$SPLITROUTE_DIR/splitroute-routes.sh" 2>/dev/null
            else
                echo "        -> Run: splitroute doctor --fix  (or: splitroute reload)"
            fi
        else
            local extra=""
            [ "$ifscope_count" -gt 0 ] && extra=", ${ifscope_count} IFSCOPE-scoped"
            echo "${ok_count} ok, ${stale_count} stale, ${missing_count} missing${extra}"
            fail=$((fail + 1))
            if $fix; then
                echo "        -> Fixing: re-applying routes"
                bash "$SPLITROUTE_DIR/splitroute-routes.sh" 2>/dev/null
            else
                echo "        -> Run: splitroute doctor --fix"
            fi
        fi
    fi

    # 5. Hosts (resolution status, route status, /etc/hosts sync)
    printf "  [5/8] Hosts ............... "
    if [ "${#HOSTS[@]}" -eq 0 ]; then
        echo "skipped (no host: entries)"
        warn=$((warn + 1))
    elif [ -z "$vpn_if" ]; then
        echo "skipped (VPN not connected)"
        warn=$((warn + 1))
    else
        local hosts_state="" hi h hf hips fixed_count=0 dyn_count=0 unresolved=0
        local route_ok=0 etchosts_ok=0 etchosts_missing=0 etchosts_content=""
        if type hosts_state_dump >/dev/null 2>&1; then
            hosts_state=$(hosts_state_dump 2>/dev/null || true)
        fi
        [ -r /etc/hosts ] && etchosts_content=$(cat /etc/hosts 2>/dev/null || true)
        for (( hi = 0; hi < ${#HOSTS[@]}; hi++ )); do
            h="${HOSTS[$hi]}"
            hf="${HOST_FIXED_IPS[$hi]:-}"
            if [ -n "$hf" ]; then
                fixed_count=$((fixed_count + 1))
                # Pinned host should be in /etc/hosts and routed
                if echo "$etchosts_content" | grep -qE "^[[:space:]]*${hf//./\\.}[[:space:]]+${h//./\\.}([[:space:]]|$)"; then
                    etchosts_ok=$((etchosts_ok + 1))
                else
                    etchosts_missing=$((etchosts_missing + 1))
                fi
                if [ -n "$route_table" ] && echo "$route_table" \
                    | awk -v ip="$hf" -v iface="$vpn_if" '$1==ip && $NF==iface' \
                    | grep -q .; then
                    route_ok=$((route_ok + 1))
                fi
            else
                dyn_count=$((dyn_count + 1))
                hips=$(echo "$hosts_state" | awk -F'\t' -v hh="$h" '$1==hh{print $2}')
                if [ -z "$hips" ]; then
                    unresolved=$((unresolved + 1))
                else
                    while IFS= read -r ip; do
                        [ -n "$ip" ] || continue
                        if echo "$route_table" | awk -v dip="$ip" -v iface="$vpn_if" '$1==dip && $NF==iface' | grep -q .; then
                            route_ok=$((route_ok + 1))
                        fi
                    done <<< "$hips"
                fi
            fi
        done
        local summary
        summary="${#HOSTS[@]} host"
        [ "${#HOSTS[@]}" -ne 1 ] && summary="${summary}s"
        [ "$fixed_count" -gt 0 ] && summary="$summary, ${fixed_count} pinned"
        [ "$dyn_count" -gt 0 ] && summary="$summary, ${dyn_count} dynamic"
        if [ "$unresolved" -eq 0 ] && [ "$etchosts_missing" -eq 0 ]; then
            echo "$summary, all routed"
            pass=$((pass + 1))
        else
            echo "$summary; ${unresolved} unresolved, ${etchosts_missing} missing in /etc/hosts"
            fail=$((fail + 1))
            if [ "$unresolved" -gt 0 ]; then
                echo "        -> Dynamic hosts didn't resolve. VPN DNS reachable?"
                echo "           Run: splitroute logs | grep hosts_apply"
            fi
            if [ "$etchosts_missing" -gt 0 ]; then
                if $fix; then
                    echo "        -> Fixing: triggering hosts re-sync"
                    bash "$SPLITROUTE_DIR/splitroute-routes.sh" 2>/dev/null
                else
                    echo "        -> Run: splitroute reload   (re-syncs /etc/hosts)"
                fi
            fi
        fi
    fi

    # 6. Connectivity test (first route)
    printf "  [6/8] Connectivity ........ "
    if [ -z "$vpn_if" ] || [ ${#ROUTE_IPS[@]} -eq 0 ]; then
        echo "skipped"
        warn=$((warn + 1))
    else
        local test_ip="${ROUTE_IPS[0]}"
        test_ip="${test_ip%%/*}"
        local result_if
        result_if=$(route -n get "$test_ip" 2>/dev/null | grep 'interface:' | awk '{print $2}')
        if [ "$result_if" = "$vpn_if" ]; then
            echo "ok ($test_ip -> $vpn_if)"
            pass=$((pass + 1))
        else
            echo "$test_ip -> ${result_if:-unknown} (expected $vpn_if)"
            fail=$((fail + 1))
            echo "        Likely IFSCOPE'd routes — see step 4."
        fi
    fi

    # 7. Proxy listener (only when legacy proxy bridging is enabled)
    printf "  [7/8] Proxy listener ...... "
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

    # 8. PAC server + autoproxy (only when PAC enabled)
    printf "  [8/8] PAC server .......... "
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

# --- host ---
#
# Explicit subcommand for managing `host:` entries. The smart `add`/`remove`
# verbs already dispatch hostnames here, so this exists mostly to give a
# clear list view and a discoverable command surface.

cmd_host() {
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add|a)        _cmd_add_host "${1:-}" ;;
        remove|rm|r)  _cmd_remove_host "${1:-}" ;;
        list|ls|"")   _cmd_host_list ;;
        *)
            echo "Usage: splitroute host {add|remove|list} [hostname]"
            exit 1 ;;
    esac
}

_cmd_host_list() {
    load_config "$CONF" 2>/dev/null || { echo "No config"; return; }
    if [ "${#HOSTS[@]}" -eq 0 ]; then
        echo "(no hosts configured)"
        echo "Add one with: splitroute add <hostname> [ip]"
        return
    fi
    local hosts_state="" i h fixed ips tag
    if type hosts_state_dump >/dev/null 2>&1; then
        hosts_state=$(hosts_state_dump 2>/dev/null || true)
    fi
    for (( i = 0; i < ${#HOSTS[@]}; i++ )); do
        h="${HOSTS[$i]}"
        fixed="${HOST_FIXED_IPS[$i]:-}"
        ips=""
        if [ -n "$hosts_state" ]; then
            ips=$(echo "$hosts_state" | awk -F'\t' -v hh="$h" '$1==hh{print $2}' | paste -sd ',' -)
        fi
        if [ -n "$fixed" ]; then
            tag="[$fixed]  (pinned)"
        elif [ -n "$ips" ]; then
            tag="[$ips]"
        else
            tag="(unresolved)"
        fi
        printf "%-32s %s\n" "$h" "$tag"
    done
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
    echo "Getting started (smart add — figures out the right layer for you):"
    echo "  add <target> [ip]     Add an IP, CIDR, hostname, or *.pattern"
    echo "                          IP/CIDR        -> route table (any app)"
    echo "                          hostname       -> PAC + DNS + route after resolve"
    echo "                          hostname + ip  -> PAC + /etc/hosts pin + route (no DNS lookup)"
    echo "                          *.pattern      -> PAC only (browser)"
    echo "  remove <target>       Remove an IP/CIDR/hostname/pattern"
    echo "  list                  List everything currently configured"
    echo "  edit                  Open config file in editor"
    echo ""
    echo "Explicit subcommands (when you want them):"
    echo "  host add/remove/list  Manage hostnames (PAC + DNS suffix + route bundle)"
    echo "  domain add/remove/ls  Manage *.pattern / IP entries (PAC only)"
    echo "  dns add/remove/list   Manage /etc/resolver overrides"
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
    add)                  shift; cmd_add "$@" ;;
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
    host|hosts)           shift; cmd_host "$@" ;;
    dns)                  shift; cmd_dns "$@" ;;
    pac)                  shift; cmd_pac "$@" ;;
    help|--help|-h)       cmd_help ;;
    *)                    echo "Unknown command: $1"; echo ""; cmd_help; exit 1 ;;
esac
