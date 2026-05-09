#!/usr/bin/env bats
# Tests for splitroute-priv. Each test rewrites HOSTS_FILE/RESOLVER_DIR
# constants in a per-test copy so we never touch the real /etc.

load test_helper

setup() {
    _sandbox_setup
    # Per-test copy of the helper, with $HOSTS_FILE / $RESOLVER_DIR pointed
    # into the sandbox. Reads stdin where applicable.
    HOSTS_FAKE="$TEST_HOME/etc-hosts"
    RESOLVER_FAKE="$TEST_HOME/etc-resolver"
    mkdir -p "$RESOLVER_FAKE"
    cat > "$HOSTS_FAKE" <<'EOF'
##
# Host Database
127.0.0.1	localhost
255.255.255.255	broadcasthost
EOF
    PRIV="$TEST_HOME/priv-test"
    sed \
        -e "s|HOSTS_FILE=\"/etc/hosts\"|HOSTS_FILE=\"$HOSTS_FAKE\"|" \
        -e "s|RESOLVER_DIR=\"/etc/resolver\"|RESOLVER_DIR=\"$RESOLVER_FAKE\"|" \
        "$REPO_ROOT/splitroute-priv" > "$PRIV"
    chmod +x "$PRIV"
}

@test "hosts-sync inserts marker-tagged lines" {
    printf '10.0.1.5\tgit.example.com\n' | "$PRIV" hosts-sync
    grep -q '^10.0.1.5	git.example.com	# managed-by: splitroute$' "$HOSTS_FAKE"
}

@test "hosts-sync preserves user's existing lines" {
    printf '10.0.1.5\tgit.example.com\n' | "$PRIV" hosts-sync
    grep -q '^127.0.0.1	localhost$' "$HOSTS_FAKE"
    grep -q '^255.255.255.255	broadcasthost$' "$HOSTS_FAKE"
}

@test "hosts-sync replaces prior managed block atomically" {
    printf '10.0.1.5\tgit.example.com\n' | "$PRIV" hosts-sync
    printf '10.0.1.99\tgit.example.com\n' | "$PRIV" hosts-sync
    [ "$(grep -c 'git.example.com' "$HOSTS_FAKE")" -eq 1 ]
    grep -q '^10.0.1.99	git.example.com' "$HOSTS_FAKE"
}

@test "hosts-sync drops removed entries when input shrinks" {
    printf '10.0.1.5\tgit.example.com\n10.0.1.6\tbastion.example.com\n' | "$PRIV" hosts-sync
    printf '10.0.1.5\tgit.example.com\n' | "$PRIV" hosts-sync
    [ "$(grep -c 'managed-by: splitroute' "$HOSTS_FAKE")" -eq 1 ]
    grep -q 'git.example.com' "$HOSTS_FAKE"
    ! grep -q 'bastion.example.com' "$HOSTS_FAKE"
}

@test "hosts-sync rejects invalid IP and aborts atomically" {
    printf '10.0.1.5\tgit.example.com\n' | "$PRIV" hosts-sync
    run sh -c "printf 'not-an-ip\thost.example.com\n' | $PRIV hosts-sync"
    [ "$status" -ne 0 ]
    # Original managed line still intact (unchanged on rejection)
    grep -q 'git.example.com' "$HOSTS_FAKE"
}

@test "hosts-sync rejects malformed hostname (double dot)" {
    run sh -c "printf '10.0.1.5\thost..example.com\n' | $PRIV hosts-sync"
    [ "$status" -ne 0 ]
}

@test "hosts-sync with empty stdin still works (clears block)" {
    printf '10.0.1.5\tgit.example.com\n' | "$PRIV" hosts-sync
    : | "$PRIV" hosts-sync
    ! grep -q 'managed-by: splitroute' "$HOSTS_FAKE"
}

@test "hosts-cleanup removes all marked lines, keeps unmarked" {
    printf '10.0.1.5\tgit.example.com\n10.0.1.6\tbastion.example.com\n' | "$PRIV" hosts-sync
    "$PRIV" hosts-cleanup
    ! grep -q 'managed-by: splitroute' "$HOSTS_FAKE"
    grep -q 'localhost' "$HOSTS_FAKE"
}

@test "write-resolver creates marked file with nameserver" {
    "$PRIV" write-resolver "example.com" "10.0.0.53"
    [ -f "$RESOLVER_FAKE/example.com" ]
    grep -q '^# managed-by: splitroute$' "$RESOLVER_FAKE/example.com"
    grep -q '^nameserver 10.0.0.53$' "$RESOLVER_FAKE/example.com"
}

@test "write-resolver rejects invalid suffix" {
    run "$PRIV" write-resolver "../etc/passwd" "10.0.0.53"
    [ "$status" -ne 0 ]
    [ ! -f "$RESOLVER_FAKE/../etc/passwd" ]
}

@test "write-resolver rejects non-IPv4 nameserver" {
    run "$PRIV" write-resolver "example.com" "not-an-ip"
    [ "$status" -ne 0 ]
}

@test "write-resolver refuses to overwrite unmarked file" {
    echo "user-edited content" > "$RESOLVER_FAKE/example.com"
    run "$PRIV" write-resolver "example.com" "10.0.0.53"
    [ "$status" -ne 0 ]
    [ "$(cat "$RESOLVER_FAKE/example.com")" = "user-edited content" ]
}

@test "delete-resolver only removes marked files" {
    echo "user-edited content" > "$RESOLVER_FAKE/example.com"
    "$PRIV" delete-resolver "example.com"
    [ -f "$RESOLVER_FAKE/example.com" ]   # unmarked, preserved
    "$PRIV" write-resolver "corp.local" "10.0.0.53"
    "$PRIV" delete-resolver "corp.local"
    [ ! -f "$RESOLVER_FAKE/corp.local" ]
}

@test "cleanup-resolver wipes all marked, leaves unmarked" {
    echo "user-edited content" > "$RESOLVER_FAKE/example.com"
    "$PRIV" write-resolver "corp1.local" "10.0.0.53"
    "$PRIV" write-resolver "corp2.local" "10.0.0.54"
    "$PRIV" cleanup-resolver
    [ -f "$RESOLVER_FAKE/example.com" ]
    [ ! -f "$RESOLVER_FAKE/corp1.local" ]
    [ ! -f "$RESOLVER_FAKE/corp2.local" ]
}

@test "list-resolver enumerates only marked files" {
    echo "user-edited content" > "$RESOLVER_FAKE/example.com"
    "$PRIV" write-resolver "corp.local" "10.0.0.53"
    output=$("$PRIV" list-resolver)
    [ "$output" = "corp.local" ]
}
