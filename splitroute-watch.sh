#!/bin/bash
# splitroute-watch.sh — Monitor VPN state and reconcile every subsystem
# (routes, PAC, system auto-proxy, /etc/resolver, /etc/hosts) to match the
# config file. Kept alive by launchd.
#
# Architecture:
#   - reconcile_full(vpn_if)  : runs on VPN transitions and config changes.
#                               Re-installs everything from scratch.
#   - reconcile_drift(vpn_if) : runs every 30s. Cheap idempotent checks —
#                               only re-applies what's actually drifted.
#   - The main loop watches three triggers (VPN-state change, config mtime,
#     periodic timer) and dispatches the right reconcile.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTES_SCRIPT="$SCRIPT_DIR/splitroute-routes.sh"

# shellcheck source=splitroute-lib.sh
source "$SCRIPT_DIR/splitroute-lib.sh"
# shellcheck source=splitroute-pac.sh
source "$SCRIPT_DIR/splitroute-pac.sh"
# shellcheck source=splitroute-sysproxy.sh
source "$SCRIPT_DIR/splitroute-sysproxy.sh"
# shellcheck source=splitroute-resolver.sh
source "$SCRIPT_DIR/splitroute-resolver.sh"
# shellcheck source=splitroute-hosts.sh
source "$SCRIPT_DIR/splitroute-hosts.sh"

CONF="$SPLITROUTE_CONF"
LOG="$SPLITROUTE_LOG"
LAST_CONF_MTIME=0
DRIFT_INTERVAL=30   # seconds between periodic drift checks

get_conf_mtime() {
    [ -f "$CONF" ] || { echo 0; return; }
    stat -f %m "$CONF" 2>/dev/null || echo 0
}

# Wipe legacy VPN-service HTTP/HTTPS/SOCKS proxy (only if proxy=true mode).
legacy_cleanup_proxy() {
    [ "${PROXY_ENABLED:-false}" = "true" ] || return 0
    local svc
    svc=$(scutil --nc list 2>/dev/null | grep Disconnected | sed 's/.*"\(.*\)".*/\1/' | head -1)
    if [ -z "$svc" ]; then
        svc=$(networksetup -listallnetworkservices | tail -n +2 | grep -iE 'vpn|l2tp|ipsec|ppp|wireguard' | head -1)
    fi
    if [ -n "$svc" ]; then
        sudo networksetup -setwebproxystate "$svc" off 2>/dev/null || true
        sudo networksetup -setsecurewebproxystate "$svc" off 2>/dev/null || true
        sudo networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
        echo "$(log_ts): Cleaned up legacy proxy on '$svc'" >> "$LOG"
    fi
}

# Full teardown on SIGTERM/SIGINT (launchd bootout, splitroute uninstall).
full_teardown() {
    echo "$(log_ts): vpn-watch stopping — tearing down PAC/sysproxy/resolver/hosts" >> "$LOG"
    if [ "${AUTO_SET_SYSTEM_PROXY:-true}" = "true" ]; then
        sysproxy_revert 2>/dev/null || true
    fi
    pac_stop 2>/dev/null || true
    resolver_cleanup_all 2>/dev/null || true
    hosts_teardown 2>/dev/null || true
    legacy_cleanup_proxy
    exit 0
}
trap full_teardown SIGTERM SIGINT

# Bring PAC + system autoproxy up. Idempotent.
apply_pac_stack() {
    pac_is_enabled || return 0
    pac_apply || true
    if [ "${AUTO_SET_SYSTEM_PROXY:-true}" = "true" ]; then
        sysproxy_apply "$(pac_url)?v=$(pac_mtime)"
    fi
}

# Tear down PAC stack when config disabled it (e.g. user removed all
# domain:/host:/dns: lines).
teardown_pac_stack() {
    sysproxy_revert 2>/dev/null || true
    pac_stop 2>/dev/null || true
}

# Full reconciliation — every subsystem rebuilt from scratch. Runs on
# VPN-state transitions and config-file changes.
reconcile_full() {
    local vpn_if="${1:-}"
    load_config "$CONF" 2>/dev/null || true

    if pac_is_enabled; then
        apply_pac_stack
    else
        teardown_pac_stack
    fi

    if [ -n "$vpn_if" ]; then
        # ROUTE_IPS go via splitroute-routes.sh (subprocess).
        bash "$ROUTES_SCRIPT" 2>> "$LOG" || true

        if resolver_is_enabled; then
            resolver_cleanup_all 2>/dev/null || true
            resolver_apply "$vpn_if"
        else
            resolver_cleanup_all 2>/dev/null || true
        fi

        # host: entries — installs /etc/hosts pins + per-IP routes.
        hosts_apply "$vpn_if" 2>/dev/null || true
    else
        # VPN down: stale /etc/resolver entries would time out lookups for
        # internal suffixes, so clear them. /etc/hosts pins persist
        # (they're user intent that re-activates on reconnect).
        resolver_cleanup_all 2>/dev/null || true
    fi
}

# Periodic drift check — runs every $DRIFT_INTERVAL seconds. Only does
# work when something actually drifted.
reconcile_drift() {
    local vpn_if="${1:-}"
    load_config "$CONF" 2>/dev/null || true

    # Re-apply PAC autoproxy across active services. Cheap; catches
    # newly-added services (Wi-Fi -> Ethernet handoff, USB tethering, etc.).
    if pac_is_enabled; then
        if ! pac_is_running; then
            echo "$(log_ts): PAC server not running, restarting" >> "$LOG"
            apply_pac_stack
        elif [ "${AUTO_SET_SYSTEM_PROXY:-true}" = "true" ]; then
            sysproxy_apply "$(pac_url)?v=$(pac_mtime)"
        fi
    fi

    if [ -n "$vpn_if" ]; then
        # Re-install routes only if any are missing (cheap netstat check).
        if [ "${#ROUTE_IPS[@]}" -gt 0 ] && ! verify_routes "$vpn_if"; then
            echo "$(log_ts): Route drift detected on $vpn_if, re-applying" >> "$LOG"
            bash "$ROUTES_SCRIPT" 2>> "$LOG" || true
        fi
        # hosts_apply diffs against state and only acts on real changes.
        hosts_apply "$vpn_if" 2>/dev/null || true
    fi
}

# --- main loop ---

load_config "$CONF" 2>/dev/null || true
LAST_CONF_MTIME=$(get_conf_mtime)
echo "$(log_ts): vpn-watch started" >> "$LOG"
if pac_is_enabled; then
    sysproxy_warn_if_conflict
fi

tracked_if=$(get_vpn_interface 2>/dev/null || true)
[ -n "$tracked_if" ] && \
    echo "$(log_ts): VPN already up on $tracked_if at startup" >> "$LOG"
reconcile_full "$tracked_if"
last_drift_ts=$SECONDS

while true; do
    sleep 5
    current_if=$(get_vpn_interface 2>/dev/null || true)
    cur_mtime=$(get_conf_mtime)

    # Trigger 1: VPN state transition (connect / disconnect / iface change)
    if [ "$current_if" != "$tracked_if" ]; then
        echo "$(log_ts): VPN transition ${tracked_if:-<none>} -> ${current_if:-<none>}" >> "$LOG"
        # On disconnect, release per-host state (OS auto-cleared the
        # interface routes; we just clear our bookkeeping). /etc/hosts
        # pins stay — they're user intent.
        if [ -z "$current_if" ] && [ -n "$tracked_if" ]; then
            hosts_release 2>/dev/null || true
            legacy_cleanup_proxy
        fi
        tracked_if="$current_if"
        reconcile_full "$tracked_if"
        last_drift_ts=$SECONDS
        continue
    fi

    # Trigger 2: config file changed (hot-reload)
    if [ "$cur_mtime" != "$LAST_CONF_MTIME" ]; then
        echo "$(log_ts): config changed (mtime $LAST_CONF_MTIME -> $cur_mtime), reconciling" >> "$LOG"
        LAST_CONF_MTIME="$cur_mtime"
        reconcile_full "$tracked_if"
        last_drift_ts=$SECONDS
        continue
    fi

    # Trigger 3: periodic drift check
    if [ "$((SECONDS - last_drift_ts))" -ge "$DRIFT_INTERVAL" ]; then
        reconcile_drift "$tracked_if"
        last_drift_ts=$SECONDS
    fi
done
