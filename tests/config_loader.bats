#!/usr/bin/env bats
# Tests for load_config — covers all config syntaxes.

load test_helper

setup() {
    _sandbox_setup
    # shellcheck source=/dev/null
    source "$SPLITROUTE_DIR/splitroute-lib.sh"
}

@test "load_config parses bare IP routes" {
    write_conf <<'EOF'
interface = auto
10.0.1.100
192.168.0.0/16
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${#ROUTE_IPS[@]}" -eq 2 ]
    [ "${ROUTE_IPS[0]}" = "10.0.1.100" ]
    [ "${ROUTE_IPS[1]}" = "192.168.0.0/16" ]
}

@test "load_config parses domain: with wildcard" {
    write_conf <<'EOF'
domain: *.example.com
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${#DOMAINS[@]}" -eq 1 ]
    [ "${DOMAINS[0]}" = "*.example.com" ]
    [ "${#DOMAIN_IPS[@]}" -eq 0 ]
}

@test "load_config sorts domain: IP into DOMAIN_IPS" {
    write_conf <<'EOF'
domain: 10.0.99.0/24
domain: *.corp.local
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${#DOMAINS[@]}" -eq 1 ]
    [ "${#DOMAIN_IPS[@]}" -eq 1 ]
    [ "${DOMAIN_IPS[0]}" = "10.0.99.0/24" ]
}

@test "load_config parses host: dynamic" {
    write_conf <<'EOF'
host: git.example.com
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${#HOSTS[@]}" -eq 1 ]
    [ "${HOSTS[0]}" = "git.example.com" ]
    [ -z "${HOST_FIXED_IPS[0]}" ]
}

@test "load_config parses host: with fixed IP" {
    write_conf <<'EOF'
host: git.example.com 10.0.1.5
host: bastion.example.com 10.0.1.6
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${#HOSTS[@]}" -eq 2 ]
    [ "${HOST_FIXED_IPS[0]}" = "10.0.1.5" ]
    [ "${HOST_FIXED_IPS[1]}" = "10.0.1.6" ]
}

@test "load_config ignores invalid IP after hostname" {
    write_conf <<'EOF'
host: foo.example.com bogus
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${HOSTS[0]}" = "foo.example.com" ]
    [ -z "${HOST_FIXED_IPS[0]}" ]   # bogus IP dropped, treated as dynamic
}

@test "load_config parses dns: with auto" {
    write_conf <<'EOF'
dns: example.com auto
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${DNS_SUFFIXES[0]}" = "example.com" ]
    [ "${DNS_NAMESERVERS[0]}" = "auto" ]
}

@test "load_config parses dns: with explicit nameserver" {
    write_conf <<'EOF'
dns: corp.local 10.0.0.53
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${DNS_SUFFIXES[0]}" = "corp.local" ]
    [ "${DNS_NAMESERVERS[0]}" = "10.0.0.53" ]
}

@test "load_config defaults dns: nameserver to auto when omitted" {
    write_conf <<'EOF'
dns: example.com
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${DNS_NAMESERVERS[0]}" = "auto" ]
}

@test "load_config sets pac_enabled=true when domain present" {
    write_conf <<'EOF'
domain: *.example.com
EOF
    load_config "$SPLITROUTE_CONF"
    [ "$PAC_ENABLED" = "true" ]
}

@test "load_config sets pac_enabled=true when host present" {
    write_conf <<'EOF'
host: git.example.com
EOF
    load_config "$SPLITROUTE_CONF"
    [ "$PAC_ENABLED" = "true" ]
}

@test "load_config sets pac_enabled=false with no PAC-relevant entries" {
    write_conf <<'EOF'
interface = auto
10.0.0.1
EOF
    load_config "$SPLITROUTE_CONF"
    [ "$PAC_ENABLED" = "false" ]
}

@test "load_config strips inline comments" {
    write_conf <<'EOF'
host: git.example.com  # internal git
domain: *.example.com  # all subdomains
EOF
    load_config "$SPLITROUTE_CONF"
    [ "${HOSTS[0]}" = "git.example.com" ]
    [ "${DOMAINS[0]}" = "*.example.com" ]
}

@test "load_config returns 1 when file missing" {
    run load_config "/nonexistent/path"
    [ "$status" -eq 1 ]
}

@test "load_config picks up settings (interface, ports)" {
    write_conf <<'EOF'
interface = ppp
proxy = true
http_port = 7897
socks_port = 7897
EOF
    load_config "$SPLITROUTE_CONF"
    [ "$VPN_INTERFACE" = "ppp" ]
    [ "$PROXY_ENABLED" = "true" ]
    [ "$HTTP_PORT" = "7897" ]
}
