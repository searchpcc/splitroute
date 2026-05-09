#!/bin/bash
# splitroute-hosts.sh — resolve `host:` entries to IPs and inject macOS
# routes via the VPN interface. Maintains a state file so re-resolution can
# add new IPs and clean up stale ones when DNS records change.
#
# Sourced by splitroute-watch.sh. Depends on lib helpers (load_config,
# get_vpn_interface, detect_vpn_dns) and SPLITROUTE_* path constants.

# Resolve a hostname to one or more IPv4 addresses, preferring the
# VPN-pushed nameserver so internal records win over public DNS.
# Echoes IPs one per line. Empty output = unresolved.
_hosts_resolve() {
    local host="$1" vpn_if="$2" ns ips=""
    ns=$(detect_vpn_dns "$vpn_if" 2>/dev/null || true)
    if [ -n "$ns" ] && command -v dig >/dev/null 2>&1; then
        ips=$(dig +short +time=2 +tries=1 "@$ns" "$host" A 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    fi
    # Fallback: system resolver (works once /etc/resolver entry is in place
    # or the host is in public DNS).
    if [ -z "$ips" ]; then
        if command -v dig >/dev/null 2>&1; then
            ips=$(dig +short +time=2 +tries=1 "$host" A 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        fi
    fi
    if [ -z "$ips" ]; then
        ips=$(getent hosts "$host" 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    fi
    [ -n "$ips" ] && echo "$ips"
}

# Read current state into a global associative-style list:
# HOSTS_STATE_LINES[i] = "hostname<TAB>ip"
_hosts_state_load() {
    HOSTS_STATE_LINES=()
    [ -f "$SPLITROUTE_HOSTS_STATE" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && HOSTS_STATE_LINES+=("$line")
    done < "$SPLITROUTE_HOSTS_STATE"
}

_hosts_state_save() {
    mkdir -p "$SPLITROUTE_STATE_DIR"
    local tmp="$SPLITROUTE_HOSTS_STATE.tmp.$$"
    : > "$tmp"
    local entry
    for entry in "${HOSTS_STATE_LINES[@]+"${HOSTS_STATE_LINES[@]}"}"; do
        echo "$entry" >> "$tmp"
    done
    mv -f "$tmp" "$SPLITROUTE_HOSTS_STATE"
}

# Print previously-recorded IPs for a host (one per line).
_hosts_state_ips_for() {
    local host="$1" entry
    for entry in "${HOSTS_STATE_LINES[@]+"${HOSTS_STATE_LINES[@]}"}"; do
        if [ "${entry%%	*}" = "$host" ]; then
            echo "${entry#*	}"
        fi
    done
}

# Drop all state entries for a host (used before rewriting after resolve).
_hosts_state_drop_host() {
    local host="$1" entry new=()
    for entry in "${HOSTS_STATE_LINES[@]+"${HOSTS_STATE_LINES[@]}"}"; do
        if [ "${entry%%	*}" != "$host" ]; then
            new+=("$entry")
        fi
    done
    HOSTS_STATE_LINES=("${new[@]+"${new[@]}"}")
}

_hosts_state_add() {
    local host="$1" ip="$2"
    HOSTS_STATE_LINES+=("$host	$ip")
}

# True if an IP is already covered by a configured ROUTE_IPS or DOMAIN_IPS
# CIDR/host entry, so we don't double-install routes.
_hosts_ip_already_routed() {
    local ip="$1" entry table
    for entry in "${ROUTE_IPS[@]+"${ROUTE_IPS[@]}"}"; do
        [ "$entry" = "$ip" ] && return 0
    done
    table=$(netstat -rn 2>/dev/null || true)
    if echo "$table" | grep -Fw "$ip" | grep -qE 'ppp|utun'; then
        return 0
    fi
    return 1
}

_hosts_route_add() {
    local ip="$1" vpn_if="$2" vpn_gw="${3:-}"
    # Always delete first so a reload after a splitroute upgrade migrates
    # stale IFSCOPE'd entries (added by older versions via `-interface`).
    sudo route -n delete -host "$ip" 2>/dev/null || true
    if [ -n "$vpn_gw" ]; then
        sudo route -n add -host "$ip" "$vpn_gw" 2>> "$SPLITROUTE_LOG"
    else
        # Fallback: no peer IP available. Likely IFSCOPE'd, but still
        # better than nothing for protocols/setups without a peer address.
        sudo route -n add -host "$ip" -interface "$vpn_if" 2>> "$SPLITROUTE_LOG"
    fi
}

_hosts_route_del() {
    local ip="$1"
    sudo route -n delete -host "$ip" 2>> "$SPLITROUTE_LOG" || true
}

# Locate the splitroute-priv helper. Same logic as splitroute-resolver.sh's
# _priv (kept here to avoid circular sourcing concerns).
_hosts_priv() {
    if [ -x /usr/local/bin/splitroute-priv ]; then
        sudo /usr/local/bin/splitroute-priv "$@"
    elif [ -x "$SPLITROUTE_DIR/splitroute-priv" ]; then
        sudo "$SPLITROUTE_DIR/splitroute-priv" "$@"
    else
        echo "$(log_ts): splitroute-priv not found — /etc/hosts management disabled" >> "$SPLITROUTE_LOG"
        return 1
    fi
}

# Push the current set of fixed-IP hosts to /etc/hosts in one atomic rewrite.
# Empty input clears the marked block (still harmless if nothing was managed).
_hosts_etc_sync() {
    local i payload="" name ip
    for (( i = 0; i < ${#HOSTS[@]}; i++ )); do
        name="${HOSTS[$i]}"
        ip="${HOST_FIXED_IPS[$i]:-}"
        [ -z "$ip" ] && continue
        payload+="$ip	$name"$'\n'
    done
    if [ -z "$payload" ]; then
        _hosts_priv hosts-cleanup 2>/dev/null || true
    else
        printf '%s' "$payload" | _hosts_priv hosts-sync 2>> "$SPLITROUTE_LOG" || true
    fi
}

# Resolve every `host:` entry, install missing routes, drop stale ones.
# Safe to call repeatedly; idempotent. No-op if HOSTS is empty.
#
# Hosts split into two paths:
#   - Fixed IP (`host: name ip`) → use IP directly, no dig, write /etc/hosts.
#   - Dynamic (`host: name`)     → resolve over VPN DNS each tick.
hosts_apply() {
    local vpn_if="${1:-}"
    [ "${#HOSTS[@]}" -gt 0 ] || return 0
    if [ -z "$vpn_if" ]; then
        vpn_if=$(get_vpn_interface 2>/dev/null || true)
    fi
    [ -n "$vpn_if" ] || return 0

    local vpn_gw
    vpn_gw=$(get_vpn_gateway "$vpn_if" 2>/dev/null || true)

    # Push fixed-IP hosts to /etc/hosts up-front so DNS lookups (browser,
    # ssh, git) hit the local map before we even try to install routes.
    _hosts_etc_sync

    _hosts_state_load
    local i host fixed ips ip prev_ips added=0 removed=0 unresolved=0
    for (( i = 0; i < ${#HOSTS[@]}; i++ )); do
        host="${HOSTS[$i]}"
        fixed="${HOST_FIXED_IPS[$i]:-}"

        if [ -n "$fixed" ]; then
            ips="$fixed"
        else
            ips=$(_hosts_resolve "$host" "$vpn_if" || true)
            if [ -z "$ips" ]; then
                unresolved=$((unresolved + 1))
                echo "$(log_ts): hosts_apply: unresolved $host (will retry)" >> "$SPLITROUTE_LOG"
                continue
            fi
        fi

        prev_ips=$(_hosts_state_ips_for "$host")
        _hosts_state_drop_host "$host"

        # Install routes for new IPs and rebuild state.
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            _hosts_state_add "$host" "$ip"
            if echo "$prev_ips" | grep -qx "$ip"; then
                continue
            fi
            if _hosts_ip_already_routed "$ip"; then
                echo "$(log_ts): hosts_apply: $host -> $ip (already routed, skipped)" >> "$SPLITROUTE_LOG"
                continue
            fi
            if _hosts_route_add "$ip" "$vpn_if" "$vpn_gw"; then
                echo "$(log_ts): hosts_apply: route add $host -> $ip via ${vpn_gw:-$vpn_if}${fixed:+ (fixed)}" >> "$SPLITROUTE_LOG"
                added=$((added + 1))
            fi
        done <<< "$ips"

        # Tear down routes for IPs that disappeared (DNS change, or fixed IP rewritten).
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            if echo "$ips" | grep -qx "$ip"; then
                continue
            fi
            _hosts_route_del "$ip"
            echo "$(log_ts): hosts_apply: route del $host -> $ip (no longer current)" >> "$SPLITROUTE_LOG"
            removed=$((removed + 1))
        done <<< "$prev_ips"
    done

    _hosts_state_save
    echo "$(log_ts): hosts_apply: added=$added removed=$removed unresolved=$unresolved" >> "$SPLITROUTE_LOG"
    [ "$unresolved" -eq 0 ]
}

# Tear down every route currently tracked in state. Called on disconnect /
# uninstall. The OS already drops `-interface` routes when the link goes
# away, so this is mostly bookkeeping.
# Light cleanup on VPN disconnect / interface change. Routes via `-interface`
# are auto-removed by the OS when the link goes away — we just drop the
# state file so the next hosts_apply rebuilds from a clean slate. Crucially
# we KEEP /etc/hosts entries: they represent user intent and become live
# again on reconnect.
hosts_release() {
    HOSTS_STATE_LINES=()
    rm -f "$SPLITROUTE_HOSTS_STATE"
}

# Full cleanup: used from SIGTERM (full_teardown) and uninstall. Removes
# routes, state, and the /etc/hosts marked block.
hosts_teardown() {
    _hosts_state_load
    local entry ip
    for entry in "${HOSTS_STATE_LINES[@]+"${HOSTS_STATE_LINES[@]}"}"; do
        ip="${entry#*	}"
        [ -n "$ip" ] && _hosts_route_del "$ip"
    done
    HOSTS_STATE_LINES=()
    rm -f "$SPLITROUTE_HOSTS_STATE"
    _hosts_priv hosts-cleanup 2>/dev/null || true
}

# List current state for `splitroute status`. Echoes "host<TAB>ip" lines.
hosts_state_dump() {
    _hosts_state_load
    local entry
    for entry in "${HOSTS_STATE_LINES[@]+"${HOSTS_STATE_LINES[@]}"}"; do
        echo "$entry"
    done
}
