# Shared bats setup — sourced by every *.bats file via `load test_helper`.
#
# Test files invoke _sandbox_setup from their own setup() if they need an
# isolated $HOME with the splitroute scripts staged. Files that just need
# pure-function tests can skip it.

_sandbox_setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export SPLITROUTE_DIR="$TEST_HOME/.splitroute"
    export SPLITROUTE_CONF="$SPLITROUTE_DIR/splitroute.conf"
    mkdir -p "$SPLITROUTE_DIR/state"

    # Symlink scripts (cheaper than cp; tests are read-only).
    for f in splitroute-lib.sh splitroute-pac.sh splitroute-sysproxy.sh \
             splitroute-resolver.sh splitroute-hosts.sh splitroute-priv VERSION; do
        ln -s "$REPO_ROOT/$f" "$SPLITROUTE_DIR/$f"
    done
}

teardown() {
    [ -n "${TEST_HOME:-}" ] && [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

# Run the splitroute CLI against the sandboxed install.
splitroute_cli() {
    bash "$REPO_ROOT/splitroute.sh" "$@"
}

# Write a config from a heredoc-style string.
write_conf() {
    cat > "$SPLITROUTE_CONF"
}
