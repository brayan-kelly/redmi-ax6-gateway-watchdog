#!/bin/bash
# create-gateway-watchdog-tarball.sh
# Creates a tarball containing:
#   - files/ (the installed file hierarchy)
#   - install.sh (installation script)
#   - uninstall.sh (removal script)
#
# NOTE: This script intentionally uses #!/bin/bash as it runs on the
# developer's machine (macOS/Linux), not on the router. All generated
# scripts (install.sh, uninstall.sh) use #!/bin/sh for OpenWrt compatibility.

set -e

TARBALL_NAME="luci-app-gateway-watchdog.tar.gz"
SOURCE_DIR="files"
WORK_DIR="gateway-watchdog-pkg"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Directory '$SOURCE_DIR' not found." >&2
    exit 1
fi

trap 'rm -rf "$WORK_DIR"' EXIT

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

cp -a "$SOURCE_DIR" "$WORK_DIR/"

# Ensure all scripts are executable
echo "Setting executable permissions on scripts..."

chmod +x "$WORK_DIR"/files/usr/bin/gateway_watchdog.sh                       2>/dev/null || true
chmod +x "$WORK_DIR"/files/usr/libexec/rpcd/gateway-watchdog-status          2>/dev/null || true
chmod +x "$WORK_DIR"/files/etc/init.d/gateway_watchdog                       2>/dev/null || true
chmod +x "$WORK_DIR"/files/etc/uci-defaults/99_gateway_watchdog              2>/dev/null || true
chmod +x "$WORK_DIR"/files/etc/hotplug.d/iface/30-gateway_watchdog           2>/dev/null || true

# -------------------------------------------------------
# Create install.sh
# -------------------------------------------------------
cat > "$WORK_DIR"/install.sh << 'EOF'
#!/bin/sh
# install.sh — Install Gateway Watchdog LuCI app on OpenWrt
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must be run as root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing Gateway Watchdog files..."

for f in \
    usr/bin/gateway_watchdog.sh \
    usr/libexec/rpcd/gateway-watchdog-status \
    etc/init.d/gateway_watchdog \
    etc/hotplug.d/iface/30-gateway_watchdog \
    etc/uci-defaults/99_gateway_watchdog \
    usr/share/rpcd/acl.d/luci-app-gateway-watchdog.json \
    usr/share/luci/menu.d/luci-app-gateway-watchdog.json
do
    src="$SCRIPT_DIR/files/$f"
    dst="/$f"
    [ -f "$src" ] || continue
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
done

if [ -d "$SCRIPT_DIR/files/www/luci-static/resources/view/gateway-watchdog" ]; then
    mkdir -p /www/luci-static/resources/view/gateway-watchdog
    cp -a "$SCRIPT_DIR/files/www/luci-static/resources/view/gateway-watchdog/." \
          /www/luci-static/resources/view/gateway-watchdog/
fi

# Strip CRLF line endings and fix ownership on the init script.
# Files transferred from macOS can contain \r\n line endings which break
# the #!/bin/sh /etc/rc.common shebang recognition, preventing the service
# from appearing in LuCI's Startup page.
if [ -f /etc/init.d/gateway_watchdog ]; then
    sed -i 's/\r//' /etc/init.d/gateway_watchdog
    chown root:root /etc/init.d/gateway_watchdog
fi

# Create the UCI config file directly if it does not already exist.
# This must happen BEFORE running 99_gateway_watchdog because uci set
# fails with "Entry not found" when the config file is completely absent
# -- UCI has no package to write into. Writing the file directly first
# gives UCI a valid package context so the uci-defaults script can safely
# read and update values without errors on both first install and reinstall.
if [ ! -f /etc/config/gateway_watchdog ]; then
    echo "Creating default UCI config..."
    mkdir -p /etc/config
    cat > /etc/config/gateway_watchdog << UCIEOF
config settings 'settings'
	option enabled '1'
	option interface 'wan'
	option delay '10'
	option max_failures '5'
	option cooldown '300'
	option recovery_mode 'full'
	option recovery_verify_targets '8.8.8.8,1.1.1.1'
	option log_to_console '0'
UCIEOF
fi

# Run the uci-defaults script manually here (first-install path),
# then delete it so the boot script does not run it a second time on reboot.
if [ -x /etc/uci-defaults/99_gateway_watchdog ]; then
    echo "Running uci-defaults..."
    /etc/uci-defaults/99_gateway_watchdog && rm -f /etc/uci-defaults/99_gateway_watchdog
fi

# Restart services to pick up new rpcd ACL and LuCI menu
echo "Restarting services..."
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "Starting service..."
/etc/init.d/gateway_watchdog enable
/etc/init.d/gateway_watchdog start

echo ""
echo "Gateway Watchdog installed and running."
echo "Access it at LuCI → Status → Gateway Watchdog."
EOF
chmod +x "$WORK_DIR"/install.sh

# -------------------------------------------------------
# Create uninstall.sh
# -------------------------------------------------------
cat > "$WORK_DIR"/uninstall.sh << 'EOF'
#!/bin/sh
# uninstall.sh — Remove Gateway Watchdog from OpenWrt
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

echo "Stopping gateway_watchdog service..."
/etc/init.d/gateway_watchdog stop    2>/dev/null || true

echo "Disabling gateway_watchdog service..."
/etc/init.d/gateway_watchdog disable 2>/dev/null || true

rm -f /etc/uci-defaults/99_gateway_watchdog

echo "Removing UCI configuration..."
uci -q delete gateway_watchdog && uci commit gateway_watchdog || \
    rm -f /etc/config/gateway_watchdog

echo "Removing binaries and config files..."
rm -f /etc/init.d/gateway_watchdog \
      /etc/hotplug.d/iface/30-gateway_watchdog \
      /usr/bin/gateway_watchdog.sh \
      /tmp/gateway_watchdog.history \
      /tmp/gateway_watchdog_stats \
      /usr/libexec/rpcd/gateway-watchdog-status \
      /usr/share/rpcd/acl.d/luci-app-gateway-watchdog.json \
      /usr/share/luci/menu.d/luci-app-gateway-watchdog.json

echo "Restarting rpcd and uhttpd..."
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "Gateway Watchdog removed successfully."
EOF
chmod +x "$WORK_DIR"/uninstall.sh

# -------------------------------------------------------
# Create the tarball
# -------------------------------------------------------
echo "Creating tarball $TARBALL_NAME..."
tar -czf "$TARBALL_NAME" -C "$WORK_DIR" .

echo ""
echo "Done. To install on your router:"
echo ""
echo "  # Copy file to the router"
echo "  scp $TARBALL_NAME root@router:/tmp/"
echo ""
echo "  # SSH in and verify integrity before installing"
echo "  ssh root@router"

echo "  mkdir /tmp/gw-install"
echo "  cd /tmp/gw-install"
echo "  tar -xzf /tmp/$TARBALL_NAME -C /tmp/gw-install"
echo "  sh install.sh"
echo ""
echo "  # To uninstall later:"
echo "  sh /tmp/gw-install/uninstall.sh"