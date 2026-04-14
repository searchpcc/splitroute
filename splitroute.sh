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
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
        launchctl load "$PLIST"
    fi
    echo "Service reloaded"
}

# --- uninstall ---

cmd_uninstall() {
    echo "=== Uninstalling splitroute ==="
    # Stop service
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    # Backup config
    if [ -f "$CONF" ]; then
        cp "$CONF" "$HOME/.splitroute.conf.bak"
        echo "Config backed up to ~/.splitroute.conf.bak"
    fi
    # Remove install directory
    rm -rf "$SPLITROUTE_DIR"
    # Remove CLI and sudoers
    sudo rm -f /usr/local/bin/splitroute
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
    printf "  [1/6] Daemon .............. "
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
    printf "  [2/6] Config .............. "
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
    printf "  [3/6] VPN ................. "
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
    printf "  [4/6] Routes .............. "
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
    printf "  [5/6] Connectivity ........ "
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

    # 6. Proxy listener (only when proxy bridging is enabled)
    printf "  [6/6] Proxy listener ...... "
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

# --- help ---

cmd_help() {
    local ver
    ver=$(get_version)
    echo "splitroute $ver — macOS VPN split tunneling"
    echo ""
    echo "Usage: splitroute <command>"
    echo ""
    echo "Getting started:"
    echo "  add <IP>       Add an IP or subnet to route through VPN"
    echo "  remove <IP>    Remove an IP or subnet from routes"
    echo "  list           List all configured routes"
    echo "  edit           Open config file in editor"
    echo ""
    echo "Diagnostics:"
    echo "  status         Show service, VPN, and route status"
    echo "  doctor [--fix] Run 5-step diagnostic (optional auto-fix)"
    echo "  test <IP>      Check how an IP is currently routed"
    echo "  logs           Show recent log entries"
    echo ""
    echo "Management:"
    echo "  apply          Manually inject routes now"
    echo "  reload         Restart the background service"
    echo "  uninstall      Uninstall splitroute"
    echo "  version        Show version"
    echo "  help           Show this help"
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
    help|--help|-h)       cmd_help ;;
    *)                    echo "Unknown command: $1"; echo ""; cmd_help; exit 1 ;;
esac
