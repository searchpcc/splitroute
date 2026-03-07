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

has_vpn() {
    # ppp interfaces only exist during L2TP connection — safe to grep
    if ifconfig -l | tr ' ' '\n' | grep -q ppp; then
        return 0
    fi
    # System VPN (IKEv2, L2TP via macOS settings)
    if scutil --nc list 2>/dev/null | grep -q Connected; then
        return 0
    fi
    # Third-party VPN apps (WireGuard App, Tunnelblick, OpenVPN Connect)
    # These don't register with scutil, but create utun with P2P inet
    if find_vpn_utun >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

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
    if has_vpn; then
        bash "$ROUTES_SCRIPT"
        # Wait for VPN disconnect
        while has_vpn; do
            sleep 5
        done
        echo "$(log_ts): VPN disconnected" >> "$LOG"
        cleanup_proxy
    fi
    sleep 3
done
