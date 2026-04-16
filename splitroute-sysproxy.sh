#!/bin/bash
# splitroute-sysproxy.sh — manage macOS system auto-proxy URL across all
# active network services. Sourced by splitroute-watch.sh.
#
# Depends on lib helpers: active_network_services, log_ts, SPLITROUTE_*.

# Filesystem-safe filename for a network service name.
_sysproxy_slug() {
    # Replace anything that is not alnum/._- with _
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Save current auto-proxy URL + state for a service (one file per service).
_sysproxy_save_state() {
    local svc="$1"
    mkdir -p "$SPLITROUTE_STATE_DIR"
    local slug file
    slug=$(_sysproxy_slug "$svc")
    file="$SPLITROUTE_STATE_DIR/${slug}.autoproxy"
    # Only save if we haven't saved before (first-run wins, subsequent refreshes
    # don't overwrite the original state).
    if [ -f "$file" ]; then
        return 0
    fi
    networksetup -getautoproxyurl "$svc" > "$file" 2>/dev/null || true
}

# Restore auto-proxy URL + state from saved file; fallback to "off".
_sysproxy_restore_state() {
    local svc="$1"
    local slug file url enabled
    slug=$(_sysproxy_slug "$svc")
    file="$SPLITROUTE_STATE_DIR/${slug}.autoproxy"
    if [ -f "$file" ]; then
        url=$(grep '^URL:' "$file" | sed 's/^URL:[[:space:]]*//')
        enabled=$(grep '^Enabled:' "$file" | sed 's/^Enabled:[[:space:]]*//')
        if [ -n "$url" ] && [ "$url" != "(null)" ]; then
            sudo networksetup -setautoproxyurl "$svc" "$url" 2>/dev/null || true
        fi
        if [ "$enabled" = "Yes" ]; then
            sudo networksetup -setautoproxystate "$svc" on 2>/dev/null || true
        else
            sudo networksetup -setautoproxystate "$svc" off 2>/dev/null || true
        fi
        rm -f "$file"
    else
        sudo networksetup -setautoproxystate "$svc" off 2>/dev/null || true
    fi
}

# Apply PAC URL across all active services. Safe to call repeatedly — only
# saves state the first time per service.
sysproxy_apply() {
    local url="$1"
    [ -n "$url" ] || return 1
    local svc count=0
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        _sysproxy_save_state "$svc"
        sudo networksetup -setautoproxyurl "$svc" "$url" 2>/dev/null || continue
        sudo networksetup -setautoproxystate "$svc" on 2>/dev/null || continue
        count=$((count + 1))
    done < <(active_network_services)
    echo "$(log_ts): sysproxy_apply: set autoproxy on $count service(s) -> $url" >> "$SPLITROUTE_LOG"
}

# Revert across all services (restores saved state or disables).
sysproxy_revert() {
    local svc count=0
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        _sysproxy_restore_state "$svc"
        count=$((count + 1))
    done < <(active_network_services)
    echo "$(log_ts): sysproxy_revert: reverted autoproxy on $count service(s)" >> "$SPLITROUTE_LOG"
}

# Detect Clash-style HTTP/HTTPS proxy on any service and log a warning.
# Does not modify anything. Auto-proxy URL we set takes precedence in practice.
sysproxy_warn_if_conflict() {
    local svc url
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        url=$(networksetup -getwebproxy "$svc" 2>/dev/null | awk -F': ' '/^Server:/{s=$2} /^Port:/{p=$2} END{if(s&&p) print s":"p}')
        if [ -n "$url" ] && [[ "$url" == 127.0.0.1:* ]]; then
            echo "$(log_ts): WARN: service '$svc' has HTTP proxy $url set (likely Clash). Auto-proxy (PAC) will take precedence; you can leave this as-is." >> "$SPLITROUTE_LOG"
            return 0
        fi
    done < <(active_network_services)
    return 1
}
