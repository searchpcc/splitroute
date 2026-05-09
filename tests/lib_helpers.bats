#!/usr/bin/env bats
# Tests for pure-logic helpers in splitroute-lib.sh.

load test_helper

setup() {
    _sandbox_setup
    # shellcheck source=/dev/null
    source "$SPLITROUTE_DIR/splitroute-lib.sh"
}

@test "is_valid_route accepts plain IPv4" {
    is_valid_route "10.0.1.5"
}

@test "is_valid_route accepts CIDR" {
    is_valid_route "192.168.0.0/16"
}

@test "is_valid_route rejects partial IP" {
    run is_valid_route "10.0.1"
    [ "$status" -ne 0 ]
}

@test "is_valid_route rejects hostname" {
    run is_valid_route "git.example.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_hostname accepts simple two-label name" {
    is_valid_hostname "git.example.com"
}

@test "is_valid_hostname accepts deep subdomain" {
    is_valid_hostname "git.dev.svc.cluster.local"
}

@test "is_valid_hostname rejects empty" {
    run is_valid_hostname ""
    [ "$status" -ne 0 ]
}

@test "is_valid_hostname rejects single label" {
    run is_valid_hostname "localhost"
    [ "$status" -ne 0 ]
}

@test "is_valid_hostname rejects wildcard" {
    run is_valid_hostname "*.example.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_hostname rejects double dot" {
    run is_valid_hostname "git..example.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_hostname rejects URL-style input" {
    run is_valid_hostname "http://git.example.com"
    [ "$status" -ne 0 ]
}

@test "derive_parent_suffix returns last two labels for deep name" {
    [ "$(derive_parent_suffix git.dev.example.com)" = "example.com" ]
}

@test "derive_parent_suffix returns last two labels for two-label name" {
    [ "$(derive_parent_suffix git.example.com)" = "example.com" ]
}

@test "derive_parent_suffix passes through bare two-label" {
    [ "$(derive_parent_suffix example.com)" = "example.com" ]
}

@test "derive_parent_suffix fails on single label" {
    run derive_parent_suffix "localhost"
    [ "$status" -ne 0 ]
}

@test "cidr_to_netmask handles /16" {
    [ "$(cidr_to_netmask 192.168.0.0/16)" = "192.168.0.0 255.255.0.0" ]
}

@test "cidr_to_netmask handles /24" {
    [ "$(cidr_to_netmask 10.0.0.0/24)" = "10.0.0.0 255.255.255.0" ]
}

@test "cidr_to_netmask handles /32" {
    [ "$(cidr_to_netmask 10.0.0.5/32)" = "10.0.0.5 255.255.255.255" ]
}

@test "cidr_to_netmask handles host without slash as /32" {
    [ "$(cidr_to_netmask 10.0.0.5)" = "10.0.0.5 255.255.255.255" ]
}

@test "cidr_to_netmask handles /0" {
    [ "$(cidr_to_netmask 0.0.0.0/0)" = "0.0.0.0 0.0.0.0" ]
}

@test "cidr_to_netmask rejects /33" {
    run cidr_to_netmask "10.0.0.0/33"
    [ "$status" -ne 0 ]
}

@test "get_vpn_gateway extracts distinct peer (L2TP-style)" {
    ifconfig() {
        echo "ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280"
        echo "    inet 192.168.201.91 --> 192.168.1.1 netmask 0xffffff00"
    }
    [ "$(get_vpn_gateway ppp0)" = "192.168.1.1" ]
}

@test "get_vpn_gateway returns empty when peer == self (utun WG-style)" {
    ifconfig() {
        echo "utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420"
        echo "    inet 10.0.0.5 --> 10.0.0.5 netmask 0xffffffff"
    }
    [ -z "$(get_vpn_gateway utun5)" ]
}

@test "get_vpn_gateway returns empty when no P2P address" {
    ifconfig() {
        echo "utun7: flags=8051<UP,POINTOPOINT> mtu 1500"
        echo "    inet 10.0.0.5 netmask 0xff000000"
    }
    [ -z "$(get_vpn_gateway utun7)" ]
}

@test "get_vpn_gateway returns empty for missing interface name" {
    run get_vpn_gateway ""
    [ "$status" -ne 0 ]
}
