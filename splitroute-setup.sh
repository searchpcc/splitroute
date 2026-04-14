#!/bin/bash
# splitroute-setup.sh — Install splitroute on macOS
# Usage: bash splitroute-setup.sh
#
# Prerequisites:
#   Disable "Send all traffic over VPN connection" in
#   System Settings > VPN > your connection > Options

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
USERNAME="$(whoami)"
USER_UID="$(id -u)"
INSTALL_DIR="$USER_HOME/.splitroute"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
CONF="$INSTALL_DIR/splitroute.conf"
PLIST_LABEL="com.splitroute.watch"

echo "=== splitroute installer ==="
echo ""

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: splitroute only supports macOS"
    exit 1
fi

# Step 1: Create install directory and copy scripts
echo "[1/5] Installing scripts..."
mkdir -p "$INSTALL_DIR/bin"
cp "$SCRIPT_DIR/splitroute-lib.sh" "$INSTALL_DIR/splitroute-lib.sh"
cp "$SCRIPT_DIR/splitroute-routes.sh" "$INSTALL_DIR/splitroute-routes.sh"
cp "$SCRIPT_DIR/splitroute-watch.sh" "$INSTALL_DIR/splitroute-watch.sh"
cp "$SCRIPT_DIR/VERSION" "$INSTALL_DIR/VERSION"
chmod +x "$INSTALL_DIR/splitroute-lib.sh"
chmod +x "$INSTALL_DIR/splitroute-routes.sh"
chmod +x "$INSTALL_DIR/splitroute-watch.sh"
echo "  -> Installed to $INSTALL_DIR/"

# Step 2: Install CLI
echo "[2/5] Installing CLI..."
cp "$SCRIPT_DIR/splitroute.sh" "$INSTALL_DIR/bin/splitroute"
chmod +x "$INSTALL_DIR/bin/splitroute"
sudo mkdir -p /usr/local/bin
sudo cp "$INSTALL_DIR/bin/splitroute" /usr/local/bin/splitroute
sudo chmod +x /usr/local/bin/splitroute
echo "  -> Installed splitroute command"

# Step 3: Create config file
echo "[3/5] Configuring routes..."
if [ -f "$CONF" ]; then
    echo "  -> $CONF exists, keeping current config"
else
    # Interactive setup if running in a terminal
    if [ -t 0 ]; then
        echo ""
        echo "  Enter IPs or subnets to route through VPN (one per line)."
        echo "  Press Enter on an empty line when done."
        echo "  Examples: 10.0.1.100   192.168.0.0/16"
        echo ""

        ROUTES=()
        while true; do
            read -rp "  > " entry
            [ -z "$entry" ] && break
            # Basic validation
            if [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                ROUTES+=("$entry")
            else
                echo "    Skipped (invalid format): $entry"
            fi
        done

        # Ask about proxy
        echo ""
        read -rp "  Use a local proxy tool (ClashX/Surge/Stash)? [y/N]: " use_proxy
        PROXY_ENABLED="false"
        P_HTTP="7890"
        P_SOCKS="7891"
        if [[ "$use_proxy" =~ ^[Yy] ]]; then
            PROXY_ENABLED="true"
            echo ""
            echo "  Common proxy ports:"
            echo "    ClashX Meta / Stash  -> HTTP 7890, SOCKS 7891"
            echo "    Clash Verge          -> HTTP 7897, SOCKS 7897 (mixed)"
            echo "    Surge                -> HTTP 6152, SOCKS 6153"
            echo ""
            read -rp "  HTTP proxy port [7890]: " p_http
            [ -n "$p_http" ] && P_HTTP="$p_http"
            read -rp "  SOCKS proxy port [7891]: " p_socks
            [ -n "$p_socks" ] && P_SOCKS="$p_socks"
        fi

        # Generate config
        {
            echo "# splitroute configuration"
            echo "# Changes take effect on the next VPN connection. No restart needed."
            echo ""
            echo "interface = auto"
            echo ""
            echo "proxy = $PROXY_ENABLED"
            echo "http_port = $P_HTTP"
            echo "socks_port = $P_SOCKS"
            echo ""
            echo "# === Routes ==="
            for r in "${ROUTES[@]+"${ROUTES[@]}"}"; do
                echo "$r"
            done
        } > "$CONF"

        echo ""
        echo "  -> Saved ${#ROUTES[@]} route(s) to $CONF"
    else
        # Non-interactive: use template
        cp "$SCRIPT_DIR/splitroute.conf.example" "$CONF"
        echo "  -> Created $CONF (edit with: splitroute edit)"
    fi
fi

# Step 4: Passwordless sudo for route and networksetup
# Note: This grants NOPASSWD for ALL subcommands of route and networksetup.
# macOS sudoers does not support argument-level restrictions for these tools.
# The scripts only use: route -n add/delete, networksetup -set*proxy*
echo "[4/5] Configuring sudo..."
SUDOERS_FILE="/etc/sudoers.d/splitroute"
SUDOERS_LINE="$USERNAME ALL=(ALL) NOPASSWD: /sbin/route, /usr/sbin/networksetup"
if sudo test -f "$SUDOERS_FILE"; then
    echo "  -> $SUDOERS_FILE exists, skipped"
else
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
    echo "  -> Configured passwordless route commands"
fi

# Step 5: Install launchd plist
echo "[5/5] Starting background service..."
mkdir -p "$LAUNCH_AGENTS"

PLIST="$LAUNCH_AGENTS/$PLIST_LABEL.plist"
sed "s|\${HOME}|$USER_HOME|g" "$SCRIPT_DIR/com.splitroute.watch.plist" > "$PLIST"

# Unload existing service (try new API first, fallback to legacy)
launchctl bootout "gui/$USER_UID/$PLIST_LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null \
    || true

# bootout is async — wait for the label to actually be gone before
# bootstrap, otherwise launchd returns EIO (Input/output error).
# shellcheck source=splitroute-lib.sh
source "$INSTALL_DIR/splitroute-lib.sh"
launchd_wait_unload "$PLIST_LABEL" "gui/$USER_UID" || true

# Load service (try new API first, fallback to legacy)
if ! launchctl bootstrap "gui/$USER_UID" "$PLIST" 2>/dev/null; then
    launchctl load "$PLIST"
fi
echo "  -> Service started (auto-starts on login)"

VERSION=$(cat "$SCRIPT_DIR/VERSION")
echo ""
echo "=== splitroute v$VERSION installed ==="
echo ""
echo "Next steps:"
echo "  1. Connect your VPN"
echo "  2. Run: splitroute status"
echo ""
echo "Manage routes:"
echo "  splitroute add 10.0.1.100"
echo "  splitroute add 192.168.0.0/16"
echo "  splitroute list"
echo ""
echo "All commands: splitroute help"
