#!/usr/bin/env bats
# Tests for the smart `splitroute add` / `splitroute remove` dispatcher.

load test_helper

setup() {
    _sandbox_setup
    cat > "$SPLITROUTE_CONF" <<'EOF'
interface = auto
proxy = false
http_port = 7890
socks_port = 7891
EOF
}

@test "add IP writes a bare line" {
    splitroute_cli add 10.0.1.5
    grep -q '^10.0.1.5$' "$SPLITROUTE_CONF"
}

@test "add CIDR writes a bare line" {
    splitroute_cli add 192.168.0.0/16
    grep -q '^192.168.0.0/16$' "$SPLITROUTE_CONF"
}

@test "add hostname writes host: + auto dns:" {
    splitroute_cli add git.example.com
    grep -q '^host: git.example.com$' "$SPLITROUTE_CONF"
    grep -q '^dns: example.com auto$' "$SPLITROUTE_CONF"
}

@test "add hostname --no-auto-dns skips dns:" {
    splitroute_cli add git.example.com --no-auto-dns
    grep -q '^host: git.example.com$' "$SPLITROUTE_CONF"
    ! grep -q '^dns:' "$SPLITROUTE_CONF"
}

@test "--no-auto-dns flag works in any position" {
    splitroute_cli add --no-auto-dns git.example.com
    grep -q '^host: git.example.com$' "$SPLITROUTE_CONF"
    ! grep -q '^dns:' "$SPLITROUTE_CONF"
}

@test "add hostname + IP writes pinned host: line, no auto-dns" {
    splitroute_cli add git.example.com 10.0.1.5
    grep -q '^host: git.example.com 10.0.1.5$' "$SPLITROUTE_CONF"
    ! grep -q '^dns:' "$SPLITROUTE_CONF"
}

@test "add wildcard pattern writes domain:" {
    splitroute_cli add '*.example.com'
    grep -q '^domain: \*\.example\.com$' "$SPLITROUTE_CONF"
}

@test "add rejects invalid IP for hostname target" {
    run splitroute_cli add foo.example.com 10.0.1
    [ "$status" -ne 0 ]
}

@test "add rejects CIDR as fixed IP for hostname target" {
    run splitroute_cli add foo.example.com 10.0.0.0/24
    [ "$status" -ne 0 ]
}

@test "add rejects extra arg with non-hostname target" {
    run splitroute_cli add 10.0.0.1 10.0.0.2
    [ "$status" -ne 0 ]
}

@test "add is idempotent for hostname (warn but no duplicate)" {
    splitroute_cli add git.example.com
    splitroute_cli add git.example.com
    [ "$(grep -c '^host: git.example.com$' "$SPLITROUTE_CONF")" -eq 1 ]
}

@test "add rejects unknown flag" {
    run splitroute_cli add --bogus git.example.com
    [ "$status" -ne 0 ]
}

@test "add rejects nonsense target" {
    run splitroute_cli add 'http://nope'
    [ "$status" -ne 0 ]
}

@test "second hostname under same parent doesn't duplicate dns:" {
    splitroute_cli add git.example.com
    splitroute_cli add bastion.example.com
    [ "$(grep -c '^dns: example.com auto$' "$SPLITROUTE_CONF")" -eq 1 ]
}

@test "remove hostname clears its host: line" {
    splitroute_cli add git.example.com
    splitroute_cli remove git.example.com
    ! grep -q '^host: git.example.com$' "$SPLITROUTE_CONF"
}

@test "remove last hostname under suffix drops orphan auto-dns:" {
    splitroute_cli add git.example.com
    splitroute_cli remove git.example.com
    ! grep -q '^dns: example.com' "$SPLITROUTE_CONF"
}

@test "remove one of two hostnames keeps shared auto-dns:" {
    splitroute_cli add git.example.com
    splitroute_cli add bastion.example.com
    splitroute_cli remove git.example.com
    grep -q '^dns: example.com auto$' "$SPLITROUTE_CONF"
    grep -q '^host: bastion.example.com$' "$SPLITROUTE_CONF"
}

@test "remove pinned host (with fixed IP) works" {
    splitroute_cli add git.example.com 10.0.1.5
    splitroute_cli remove git.example.com
    ! grep -q 'git.example.com' "$SPLITROUTE_CONF"
}
