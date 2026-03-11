#!/bin/bash
# splitroute-watch.sh — Monitor VPN connection and trigger route setup
# Kept alive by launchd KeepAlive

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTES_SCRIPT="$SCRIPT_DIR/splitroute-routes.sh"

# shellcheck source=splitroute-lib.sh
source "$SCRIPT_DIR/splitroute-lib.sh"

CONF="$SPLITROUTE_CONF"
LOG="$SPLITROUTE_LOG"

# Graceful shutdown
cleanup_and_exit() {
    echo "$(log_ts): vpn-watch stopping" >> "$LOG"
    exit 0
}
trap cleanup_and_exit SIGTERM SIGINT

get_proxy_enabled() {
    if [ -f "$CONF" ]; then
        (
            # shellcheck source=/dev/null
            load_config "$CONF"
            echo "${PROXY_ENABLED:-false}"
        )
    else
        echo "false"
    fi
}

cleanup_proxy() {
    if [ "$(get_proxy_enabled)" != "true" ]; then
        return
    fi
    local svc
    # After VPN disconnects, the service shows as "Disconnected"
    svc=$(scutil --nc list 2>/dev/null | grep Disconnected | sed 's/.*"\(.*\)".*/\1/' | head -1)
    if [ -z "$svc" ]; then
        svc=$(networksetup -listallnetworkservices | tail -n +2 | grep -iE 'vpn|l2tp|ipsec|ppp|wireguard' | head -1)
    fi
    if [ -n "$svc" ]; then
        sudo networksetup -setwebproxystate "$svc" off 2>/dev/null
        sudo networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
        sudo networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
        echo "$(log_ts): Cleaned up proxy on '$svc'" >> "$LOG"
    fi
}

echo "$(log_ts): vpn-watch started" >> "$LOG"

while true; do
    current_if=$(get_vpn_interface 2>/dev/null || true)
    if [ -n "$current_if" ]; then
        tracked_if="$current_if"
        echo "$(log_ts): VPN detected on $tracked_if, applying routes" >> "$LOG"
        if bash "$ROUTES_SCRIPT"; then
            echo "$(log_ts): Routes applied successfully on $tracked_if" >> "$LOG"
        else
            echo "$(log_ts): WARNING: route script exited with error on $tracked_if" >> "$LOG"
        fi

        # Inner loop: monitor for disconnect or interface change
        local_tick=0
        while true; do
            sleep 5
            current_if=$(get_vpn_interface 2>/dev/null || true)

            # VPN disconnected
            if [ -z "$current_if" ]; then
                echo "$(log_ts): VPN disconnected (was $tracked_if)" >> "$LOG"
                cleanup_proxy
                break
            fi

            # Interface changed (e.g. utun3 -> utun5 after reconnect)
            if [ "$current_if" != "$tracked_if" ]; then
                echo "$(log_ts): Interface changed $tracked_if -> $current_if, re-applying routes" >> "$LOG"
                tracked_if="$current_if"
                if bash "$ROUTES_SCRIPT"; then
                    echo "$(log_ts): Routes re-applied on $tracked_if" >> "$LOG"
                else
                    echo "$(log_ts): WARNING: route script exited with error on $tracked_if" >> "$LOG"
                fi
                local_tick=0
            fi

            # Periodic route verification every 30 seconds (6 ticks * 5s)
            local_tick=$((local_tick + 1))
            if [ $local_tick -ge 6 ]; then
                local_tick=0
                load_config "$CONF" 2>/dev/null || true
                if [ ${#ROUTE_IPS[@]} -gt 0 ] && ! verify_routes "$tracked_if"; then
                    echo "$(log_ts): Route verification failed on $tracked_if, re-applying" >> "$LOG"
                    bash "$ROUTES_SCRIPT"
                fi
            fi
        done
    fi
    sleep 3
done
