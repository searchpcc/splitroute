#!/bin/bash
# splitroute-watch.sh — Monitor VPN connection and drive the splitroute stack
# (routes + PAC + system auto-proxy + /etc/resolver). Kept alive by launchd.

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

CONF="$SPLITROUTE_CONF"
LOG="$SPLITROUTE_LOG"
LAST_CONF_MTIME=0

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

# Full teardown on SIGTERM/SIGINT (launchd bootout, splitctl stop).
full_teardown() {
    echo "$(log_ts): vpn-watch stopping — tearing down PAC/sysproxy/resolver" >> "$LOG"
    if [ "${AUTO_SET_SYSTEM_PROXY:-true}" = "true" ]; then
        sysproxy_revert 2>/dev/null || true
    fi
    pac_stop 2>/dev/null || true
    resolver_cleanup_all 2>/dev/null || true
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

# Reload config + re-sync PAC/resolver/sysproxy to match new rules.
reload_stack() {
    load_config "$CONF" 2>/dev/null || return 1
    if pac_is_enabled; then
        pac_rewrite || true
        if [ "${AUTO_SET_SYSTEM_PROXY:-true}" = "true" ]; then
            sysproxy_apply "$(pac_url)?v=$(pac_mtime)"
        fi
        if resolver_is_enabled; then
            local vif
            vif=$(get_vpn_interface 2>/dev/null || true)
            resolver_cleanup_all
            [ -n "$vif" ] && resolver_apply "$vif"
        else
            resolver_cleanup_all 2>/dev/null || true
        fi
    else
        sysproxy_revert 2>/dev/null || true
        pac_stop 2>/dev/null || true
        resolver_cleanup_all 2>/dev/null || true
    fi
}

# --- startup ---
load_config "$CONF" 2>/dev/null || true
LAST_CONF_MTIME=$(get_conf_mtime)
echo "$(log_ts): vpn-watch started" >> "$LOG"
if pac_is_enabled; then
    sysproxy_warn_if_conflict
    apply_pac_stack
fi

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

        # PAC layer: now that VPN is up, write /etc/resolver entries (auto DNS works now).
        if pac_is_enabled && resolver_is_enabled; then
            resolver_apply "$tracked_if"
        fi

        # Inner loop: watch for disconnect / interface change / conf change.
        local_tick=0
        while true; do
            sleep 5
            current_if=$(get_vpn_interface 2>/dev/null || true)

            if [ -z "$current_if" ]; then
                echo "$(log_ts): VPN disconnected (was $tracked_if)" >> "$LOG"
                legacy_cleanup_proxy
                resolver_cleanup_all 2>/dev/null || true
                break
            fi

            if [ "$current_if" != "$tracked_if" ]; then
                echo "$(log_ts): Interface changed $tracked_if -> $current_if, re-applying" >> "$LOG"
                tracked_if="$current_if"
                bash "$ROUTES_SCRIPT" || true
                if pac_is_enabled && resolver_is_enabled; then
                    resolver_cleanup_all
                    resolver_apply "$tracked_if"
                fi
                local_tick=0
            fi

            local_tick=$((local_tick + 1))
            if [ "$local_tick" -ge 6 ]; then
                local_tick=0

                # Hot reload on config change
                cur_mtime=$(get_conf_mtime)
                if [ "$cur_mtime" != "$LAST_CONF_MTIME" ]; then
                    echo "$(log_ts): config changed (mtime $LAST_CONF_MTIME -> $cur_mtime), reloading" >> "$LOG"
                    LAST_CONF_MTIME="$cur_mtime"
                    reload_stack
                fi

                # Route verification (existing behavior)
                load_config "$CONF" 2>/dev/null || true
                if [ "${#ROUTE_IPS[@]}" -gt 0 ] && ! verify_routes "$tracked_if"; then
                    echo "$(log_ts): Route verification failed on $tracked_if, re-applying" >> "$LOG"
                    bash "$ROUTES_SCRIPT" || true
                fi

                # Catch newly-added network services for PAC autoproxy
                if pac_is_enabled && [ "${AUTO_SET_SYSTEM_PROXY:-true}" = "true" ]; then
                    sysproxy_apply "$(pac_url)?v=$(pac_mtime)"
                fi
            fi
        done
    else
        # VPN off: still keep PAC/sysproxy alive + track config
        cur_mtime=$(get_conf_mtime)
        if [ "$cur_mtime" != "$LAST_CONF_MTIME" ]; then
            echo "$(log_ts): config changed (VPN off), reloading" >> "$LOG"
            LAST_CONF_MTIME="$cur_mtime"
            reload_stack
        fi
        if pac_is_enabled && ! pac_is_running; then
            echo "$(log_ts): PAC server not running, restarting" >> "$LOG"
            apply_pac_stack
        fi
    fi
    sleep 3
done
