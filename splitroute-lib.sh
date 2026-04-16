#!/bin/bash
# splitroute-lib.sh — Shared functions and constants for splitroute
# shellcheck disable=SC2034  # SPLITROUTE_LOG is consumed by sourcing scripts (routes, watch)

SPLITROUTE_DIR="$HOME/.splitroute"
SPLITROUTE_CONF="$SPLITROUTE_DIR/splitroute.conf"
SPLITROUTE_LOG="/tmp/splitroute.log"

# PAC subsystem paths (used when pac_enabled = true)
SPLITROUTE_PAC_DIR="$SPLITROUTE_DIR/pac"
SPLITROUTE_PAC_FILE="$SPLITROUTE_PAC_DIR/proxy.pac"
SPLITROUTE_PAC_PID="$SPLITROUTE_DIR/pac.pid"
SPLITROUTE_STATE_DIR="$SPLITROUTE_DIR/state"
SPLITROUTE_RESOLVER_MARKER="# managed-by: splitroute"

# Formatted timestamp for log entries
log_ts() { date '+%Y-%m-%d %H:%M:%S %Z'; }

# Wait for a launchd service to finish unloading after `launchctl bootout`.
# bootout is asynchronous — it signals SIGTERM and returns immediately, but
# the service label stays bootstrapped until the process actually exits.
# Calling `launchctl bootstrap` before that completes fails with
# "Load failed: 5: Input/output error" (EIO). This helper polls
# `launchctl print` until the label is gone, or times out after ~5 seconds.
# Returns 0 when unloaded, 1 on timeout.
launchd_wait_unload() {
    local label="$1"
    local domain="${2:-gui/$(id -u)}"
    local i=0
    while launchctl print "$domain/$label" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 50 ]; then
            return 1
        fi
        sleep 0.1
    done
    return 0
}

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
# Sets: ROUTE_IPS, VPN_INTERFACE, PROXY_ENABLED, HTTP_PORT, SOCKS_PORT,
#       DOMAINS, DNS_SUFFIXES, DNS_NAMESERVERS, PAC_ENABLED, PAC_PORT,
#       UPSTREAM_PROXY, MANAGE_RESOLVER, AUTO_SET_SYSTEM_PROXY
load_config() {
    local conf="${1:-$SPLITROUTE_CONF}"

    # Defaults
    ROUTE_IPS=()
    VPN_INTERFACE="auto"
    PROXY_ENABLED="false"
    HTTP_PORT="7890"
    SOCKS_PORT="7891"

    # PAC subsystem defaults (v1: browser-friendly split routing via PAC)
    DOMAINS=()
    DNS_SUFFIXES=()
    DNS_NAMESERVERS=()   # parallel to DNS_SUFFIXES (value may be "auto")
    PAC_ENABLED="auto"   # auto = enabled when at least one domain/dns line is present
    PAC_PORT="7899"
    UPSTREAM_PROXY=""    # empty = auto-detect at runtime
    MANAGE_RESOLVER="true"
    AUTO_SET_SYSTEM_PROXY="true"

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
    local line key value rest suffix ns
    while IFS= read -r line; do
        # Strip inline comments
        line="${line%%#*}"
        line="$(trim "$line")"
        [ -z "$line" ] && continue

        # Prefixed rule lines
        if [[ "$line" == domain:* ]]; then
            rest="$(trim "${line#domain:}")"
            [ -n "$rest" ] && DOMAINS+=("$rest")
            continue
        fi
        if [[ "$line" == dns:* ]]; then
            rest="$(trim "${line#dns:}")"
            # Expect: "<suffix> [<nameserver>|auto]"
            suffix="${rest%%[[:space:]]*}"
            ns="$(trim "${rest#"$suffix"}")"
            [ -z "$ns" ] && ns="auto"
            if [ -n "$suffix" ]; then
                DNS_SUFFIXES+=("$suffix")
                DNS_NAMESERVERS+=("$ns")
            fi
            continue
        fi

        if [[ "$line" == *=* ]]; then
            key="$(trim "${line%%=*}")"
            value="$(trim "${line#*=}")"
            case "$key" in
                interface)              VPN_INTERFACE="$value" ;;
                proxy)                  PROXY_ENABLED="$value" ;;
                http_port)              HTTP_PORT="$value" ;;
                socks_port)             SOCKS_PORT="$value" ;;
                pac_enabled)            PAC_ENABLED="$value" ;;
                pac_port)               PAC_PORT="$value" ;;
                upstream_proxy)         UPSTREAM_PROXY="$value" ;;
                manage_resolver)        MANAGE_RESOLVER="$value" ;;
                auto_set_system_proxy)  AUTO_SET_SYSTEM_PROXY="$value" ;;
            esac
        elif [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            ROUTE_IPS+=("$line")
        fi
    done < "$conf"

    # Resolve PAC_ENABLED=auto → true when any domain/dns rule is present
    if [ "$PAC_ENABLED" = "auto" ]; then
        if [ ${#DOMAINS[@]} -gt 0 ] || [ ${#DNS_SUFFIXES[@]} -gt 0 ]; then
            PAC_ENABLED="true"
        else
            PAC_ENABLED="false"
        fi
    fi

    return 0
}

# Whether PAC subsystem should run (bash 3.2-safe)
pac_is_enabled() {
    [ "${PAC_ENABLED:-false}" = "true" ]
}

# Whether /etc/resolver management should run
resolver_is_enabled() {
    [ "${MANAGE_RESOLVER:-true}" = "true" ] && [ "${#DNS_SUFFIXES[@]}" -gt 0 ]
}

# Return the PAC URL (no trailing query string; caller adds ?v=<mtime>).
pac_url() {
    echo "http://127.0.0.1:${PAC_PORT:-7899}/proxy.pac"
}

# Return mtime (used as cache-buster query for the PAC URL)
pac_mtime() {
    if [ -f "${SPLITROUTE_PAC_FILE:-}" ]; then
        stat -f %m "$SPLITROUTE_PAC_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Detect upstream proxy (host:port). Returns:
# - explicit UPSTREAM_PROXY from config if set
# - probe 127.0.0.1:7890 (Clash Verge / ClashX Meta / Stash)
# - probe 127.0.0.1:7897 (Clash Verge alt mixed)
# - empty string if none found (PAC emits DIRECT fallback)
detect_upstream_proxy() {
    if [ -n "${UPSTREAM_PROXY:-}" ]; then
        echo "$UPSTREAM_PROXY"
        return 0
    fi
    local host port
    for port in 7890 7897 6152; do
        if nc -z -G 1 127.0.0.1 "$port" 2>/dev/null; then
            echo "127.0.0.1:$port"
            return 0
        fi
    done
    host=""
    echo "$host"
    return 1
}

# Read VPN-pushed DNS nameserver (first scoped to the given VPN interface,
# or any ppp/utun VPN if no interface is passed). Returns empty on no match.
detect_vpn_dns() {
    local vpn_if="${1:-}"
    if [ -z "$vpn_if" ]; then
        vpn_if=$(get_vpn_interface 2>/dev/null) || true
    fi
    local line have_vpn=0 ns=""
    while IFS= read -r line; do
        if [[ "$line" == resolver* ]]; then
            if [ "$have_vpn" = "1" ] && [ -n "$ns" ]; then
                echo "$ns"
                return 0
            fi
            have_vpn=0
            ns=""
            continue
        fi
        if [[ "$line" == *"nameserver["*"]"* ]] && [ -z "$ns" ]; then
            ns="${line##* : }"
        elif [[ "$line" == *if_index* ]]; then
            if [ -n "$vpn_if" ] && [[ "$line" == *"($vpn_if"* ]]; then
                have_vpn=1
            elif [ -z "$vpn_if" ] && { [[ "$line" == *"(ppp"* ]] || [[ "$line" == *"(utun"* ]]; }; then
                have_vpn=1
            fi
        fi
    done < <(scutil --dns 2>/dev/null)
    if [ "$have_vpn" = "1" ] && [ -n "$ns" ]; then
        echo "$ns"
        return 0
    fi
    return 1
}

# Enumerate active network services (skip disabled ones marked with *).
# Outputs one service name per line.
active_network_services() {
    networksetup -listallnetworkservices 2>/dev/null \
        | tail -n +2 \
        | grep -v '^\*' \
        || true
}

# CIDR → (base_ip, netmask) for PAC isInNet(). Echoes "base mask" space-separated.
cidr_to_netmask() {
    local cidr="$1"
    local ip prefix mask
    if [[ "$cidr" != */* ]]; then
        # Single host → /32
        echo "$cidr 255.255.255.255"
        return 0
    fi
    ip="${cidr%/*}"
    prefix="${cidr#*/}"
    # Compute netmask from prefix (0..32)
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || [ "$prefix" -gt 32 ]; then
        return 1
    fi
    local full=$(( 0xFFFFFFFF ))
    local shifted
    if [ "$prefix" -eq 0 ]; then
        shifted=0
    else
        shifted=$(( (full << (32 - prefix)) & full ))
    fi
    mask="$(( (shifted >> 24) & 0xFF )).$(( (shifted >> 16) & 0xFF )).$(( (shifted >> 8) & 0xFF )).$(( shifted & 0xFF ))"
    echo "$ip $mask"
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
