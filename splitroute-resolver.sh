#!/bin/bash
# splitroute-resolver.sh — manage /etc/resolver/<suffix> entries so that
# internal company domains resolve via VPN-scoped DNS servers.
#
# Sourced by splitroute-watch.sh. Delegates privileged FS ops to
# /usr/local/bin/splitroute-priv (via sudo). Only touches files that carry
# the splitroute marker header.

_priv() {
    # Locate splitroute-priv: prefer installed path, fallback to repo path
    if [ -x /usr/local/bin/splitroute-priv ]; then
        sudo /usr/local/bin/splitroute-priv "$@"
    elif [ -x "$SPLITROUTE_DIR/splitroute-priv" ]; then
        sudo "$SPLITROUTE_DIR/splitroute-priv" "$@"
    else
        echo "$(log_ts): splitroute-priv not found — /etc/resolver management disabled" >> "$SPLITROUTE_LOG"
        return 1
    fi
}

# Resolve the effective nameserver IP for a DNS_SUFFIXES entry.
# value is either a literal IP or the string "auto".
# Echoes "" (and returns non-zero) if unresolved.
_resolver_effective_ns() {
    local value="$1" vpn_if="$2"
    if [ "$value" = "auto" ] || [ -z "$value" ]; then
        detect_vpn_dns "$vpn_if" 2>/dev/null
        return $?
    fi
    echo "$value"
}

# Apply /etc/resolver entries. Intended to be called after VPN comes up so
# that "auto" nameservers can be read from scutil --dns.
resolver_apply() {
    local vpn_if="${1:-}"
    local i suffix value ns applied=0 skipped=0
    [ "${#DNS_SUFFIXES[@]}" -gt 0 ] || return 0
    for (( i = 0; i < ${#DNS_SUFFIXES[@]}; i++ )); do
        suffix="${DNS_SUFFIXES[$i]}"
        value="${DNS_NAMESERVERS[$i]}"
        ns=$(_resolver_effective_ns "$value" "$vpn_if")
        if [ -z "$ns" ]; then
            echo "$(log_ts): resolver_apply: no nameserver resolved for '$suffix' (value=$value), skipping" >> "$SPLITROUTE_LOG"
            skipped=$((skipped + 1))
            continue
        fi
        if _priv write-resolver "$suffix" "$ns"; then
            echo "$(log_ts): resolver_apply: $suffix -> $ns" >> "$SPLITROUTE_LOG"
            applied=$((applied + 1))
        else
            echo "$(log_ts): resolver_apply: failed to write /etc/resolver/$suffix" >> "$SPLITROUTE_LOG"
            skipped=$((skipped + 1))
        fi
    done
    echo "$(log_ts): resolver_apply: applied=$applied skipped=$skipped" >> "$SPLITROUTE_LOG"
}

# Remove /etc/resolver entries for currently-configured suffixes.
resolver_revert() {
    local i suffix removed=0
    [ "${#DNS_SUFFIXES[@]}" -gt 0 ] || return 0
    for (( i = 0; i < ${#DNS_SUFFIXES[@]}; i++ )); do
        suffix="${DNS_SUFFIXES[$i]}"
        if _priv delete-resolver "$suffix"; then
            removed=$((removed + 1))
        fi
    done
    echo "$(log_ts): resolver_revert: removed=$removed" >> "$SPLITROUTE_LOG"
}

# Remove ALL splitroute-managed /etc/resolver entries (regardless of config).
# Used on uninstall / shutdown to mop up any residue from previous configs.
resolver_cleanup_all() {
    _priv cleanup-resolver
    echo "$(log_ts): resolver_cleanup_all" >> "$SPLITROUTE_LOG"
}
