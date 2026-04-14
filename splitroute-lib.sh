#!/bin/bash
# splitroute-lib.sh — Shared functions and constants for splitroute
# shellcheck disable=SC2034  # SPLITROUTE_LOG is consumed by sourcing scripts (routes, watch)

SPLITROUTE_DIR="$HOME/.splitroute"
SPLITROUTE_CONF="$SPLITROUTE_DIR/splitroute.conf"
SPLITROUTE_LOG="/tmp/splitroute.log"

# Formatted timestamp for log entries
log_ts() { date '+%Y-%m-%d %H:%M:%S %Z'; }

# Find a utun interface that belongs to a VPN (has point-to-point inet address)
# System utun interfaces (iCloud Private Relay, etc.) do not have P2P inet.
find_vpn_utun() {
    local iface
    for iface in $(ifconfig -l | tr ' ' '\n' | grep utun); do
        if ifconfig "$iface" | grep -q 'inet.*-->'; then
            echo "$iface"
            return 0
        fi
    done
    return 1
}

# Trim leading and trailing whitespace
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# Load config file (supports both new simple format and legacy bash format)
# Sets: ROUTE_IPS, VPN_INTERFACE, PROXY_ENABLED, HTTP_PORT, SOCKS_PORT
load_config() {
    local conf="${1:-$SPLITROUTE_CONF}"

    # Defaults
    ROUTE_IPS=()
    VPN_INTERFACE="auto"
    PROXY_ENABLED="false"
    HTTP_PORT="7890"
    SOCKS_PORT="7891"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    # Legacy bash format: contains ROUTE_IPS=(
    if grep -q 'ROUTE_IPS=(' "$conf" 2>/dev/null; then
        # shellcheck source=/dev/null
        source "$conf"
        VPN_INTERFACE="${VPN_INTERFACE:-auto}"
        PROXY_ENABLED="${PROXY_ENABLED:-false}"
        HTTP_PORT="${HTTP_PORT:-7890}"
        SOCKS_PORT="${SOCKS_PORT:-7891}"
        return 0
    fi

    # New simple format
    local line key value
    while IFS= read -r line; do
        # Strip inline comments
        line="${line%%#*}"
        line="$(trim "$line")"
        [ -z "$line" ] && continue

        if [[ "$line" == *=* ]]; then
            key="$(trim "${line%%=*}")"
            value="$(trim "${line#*=}")"
            case "$key" in
                interface)   VPN_INTERFACE="$value" ;;
                proxy)       PROXY_ENABLED="$value" ;;
                http_port)   HTTP_PORT="$value" ;;
                socks_port)  SOCKS_PORT="$value" ;;
            esac
        elif [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            ROUTE_IPS+=("$line")
        fi
    done < "$conf"

    return 0
}

# Check if an IP/CIDR is already in the config file
config_has_route() {
    local ip="$1"
    local conf="${2:-$SPLITROUTE_CONF}"
    [ ! -f "$conf" ] && return 1

    if grep -q 'ROUTE_IPS=(' "$conf" 2>/dev/null; then
        # Legacy format: look inside the array
        grep -qFw "$ip" "$conf"
    else
        # New format: exact line match (ignoring whitespace)
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(trim "$line")"
            [ "$line" = "$ip" ] && return 0
        done < "$conf"
        return 1
    fi
}

# Validate IP or CIDR format (basic check)
is_valid_route() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]
}

# Return current VPN interface name (e.g. utun3, ppp0), or empty if none.
# Checks ppp first, then scutil, then utun with P2P heuristic.
get_vpn_interface() {
    local iface
    # L2TP creates ppp interfaces
    iface=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep ppp | tail -1)
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi
    # System VPN (IKEv2, L2TP via macOS settings) — find associated utun
    if scutil --nc list 2>/dev/null | grep -q Connected; then
        iface=$(find_vpn_utun 2>/dev/null || true)
        if [ -n "$iface" ]; then
            echo "$iface"
            return 0
        fi
    fi
    # Third-party VPN apps (WireGuard, Tunnelblick, OpenVPN)
    iface=$(find_vpn_utun 2>/dev/null || true)
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi
    return 1
}

# Verify that at least one configured route exists on the given interface.
# Returns 0 if at least one route points to the correct interface, 1 otherwise.
verify_routes() {
    local expected_if="$1"
    local route_table
    route_table=$(netstat -rn 2>/dev/null) || return 1

    # Need config loaded
    if [ ${#ROUTE_IPS[@]} -eq 0 ]; then
        return 1
    fi

    for entry in "${ROUTE_IPS[@]}"; do
        # Check if this route exists AND points to the expected interface
        if echo "$route_table" | grep -Fw "$entry" | grep -qw "$expected_if"; then
            return 0
        fi
    done
    return 1
}
