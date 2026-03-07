#!/bin/bash
# splitroute-routes.sh — Add routes for specified IPs/CIDRs through VPN tunnel
# Supports L2TP (ppp), IKEv2, WireGuard, OpenVPN (utun) interfaces

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=splitroute-lib.sh
source "$SCRIPT_DIR/splitroute-lib.sh"

VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
CONF="$SPLITROUTE_CONF"
LOG="$SPLITROUTE_LOG"

# Log rotation: clear if > 1MB
[ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && : > "$LOG"

# Version flag
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "splitroute $VERSION"
    exit 0
fi

# Load config
if ! load_config "$CONF"; then
    echo "$(log_ts): Config file $CONF not found. Run: splitroute help" >> "$LOG"
    exit 1
fi

if [ ${#ROUTE_IPS[@]} -eq 0 ]; then
    echo "$(log_ts): No routes configured, nothing to do" >> "$LOG"
    exit 0
fi

# Detect VPN interface (retry up to 15 seconds)
detect_vpn_if() {
    local iface=""
    for _ in $(seq 1 15); do
        if [ "$VPN_INTERFACE" = "auto" ]; then
            # Try ppp first (L2TP), then utun with P2P check
            iface=$(ifconfig -l | tr ' ' '\n' | grep ppp | tail -1)
            if [ -z "$iface" ]; then
                iface=$(find_vpn_utun)
            fi
        elif [ "$VPN_INTERFACE" = "ppp" ]; then
            iface=$(ifconfig -l | tr ' ' '\n' | grep ppp | tail -1)
        elif [ "$VPN_INTERFACE" = "utun" ]; then
            iface=$(find_vpn_utun)
        else
            # Exact interface name (e.g., utun3, ppp0)
            ifconfig "$VPN_INTERFACE" &>/dev/null && iface="$VPN_INTERFACE"
        fi
        [ -n "$iface" ] && echo "$iface" && return 0
        sleep 1
    done
    return 1
}

VPN_IF=$(detect_vpn_if)
if [ -z "$VPN_IF" ]; then
    echo "$(log_ts): VPN interface not found after 15s (type=$VPN_INTERFACE), exiting" >> "$LOG"
    exit 1
fi

# Wait for interface to stabilize after detection
sleep 2

VPN_GW=$(ifconfig "$VPN_IF" | grep 'inet ' | awk '{print $4}')
echo "$(log_ts): [v$VERSION] VPN interface=$VPN_IF gateway=$VPN_GW" >> "$LOG"

# Add routes (supports host IPs and CIDR subnets)
ROUTE_TABLE=$(netstat -rn)
for entry in "${ROUTE_IPS[@]}"; do
    # Use fixed-string word-boundary matching to avoid regex and partial IP issues
    if echo "$ROUTE_TABLE" | grep -qFw "$entry"; then
        echo "$(log_ts): Route exists $entry -> $VPN_IF, skipped" >> "$LOG"
    elif [[ "$entry" == */* ]]; then
        sudo route -n add -net "$entry" -interface "$VPN_IF" 2>> "$LOG"
        echo "$(log_ts): Added net route $entry -> $VPN_IF" >> "$LOG"
    else
        sudo route -n add -host "$entry" -interface "$VPN_IF" 2>> "$LOG"
        echo "$(log_ts): Added host route $entry -> $VPN_IF" >> "$LOG"
    fi
done

# Optional: set system proxy on VPN network service
if [ "$PROXY_ENABLED" != "true" ]; then
    exit 0
fi

VPN_SERVICE=$(scutil --nc list 2>/dev/null | grep Connected | sed 's/.*"\(.*\)".*/\1/' | head -1)

if [ -z "$VPN_SERVICE" ]; then
    VPN_SERVICE=$(networksetup -listallnetworkservices | tail -n +2 | grep -iE 'vpn|l2tp|ipsec|ppp|wireguard' | head -1)
fi

if [ -n "$VPN_SERVICE" ]; then
    sudo networksetup -setwebproxy "$VPN_SERVICE" 127.0.0.1 "$HTTP_PORT"
    sudo networksetup -setwebproxystate "$VPN_SERVICE" on
    sudo networksetup -setsecurewebproxy "$VPN_SERVICE" 127.0.0.1 "$HTTP_PORT"
    sudo networksetup -setsecurewebproxystate "$VPN_SERVICE" on
    sudo networksetup -setsocksfirewallproxy "$VPN_SERVICE" 127.0.0.1 "$SOCKS_PORT"
    sudo networksetup -setsocksfirewallproxystate "$VPN_SERVICE" on
    echo "$(log_ts): Proxy set on '$VPN_SERVICE' HTTP=$HTTP_PORT SOCKS=$SOCKS_PORT" >> "$LOG"
else
    echo "$(log_ts): Warning — VPN network service not found. Services:" >> "$LOG"
    networksetup -listallnetworkservices >> "$LOG"
fi
