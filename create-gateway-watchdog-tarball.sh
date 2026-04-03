#!/bin/bash
# create-gateway-watchdog-tarball.sh
# Creates a tarball containing:
#   - files/ (the installed file hierarchy)
#   - install.sh (installation script)
#   - uninstall.sh (removal script)

set -e

TARBALL_NAME="luci-app-gateway-watchdog.tar.gz"
SOURCE_DIR="files"
WORK_DIR="gateway-watchdog-pkg"

# Check that the source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Directory '$SOURCE_DIR' not found." >&2
    exit 1
fi

# Create a clean working directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Copy the existing files/ tree into the working directory
cp -a "$SOURCE_DIR" "$WORK_DIR/"

# Ensure all scripts are executable
echo "Setting executable permissions on scripts..."
chmod +x "$WORK_DIR"/files/usr/bin/gateway_watchdog.sh 2>/dev/null || true
chmod +x "$WORK_DIR"/files/usr/libexec/rpcd/gateway-watchdog-status 2>/dev/null || true
chmod +x "$WORK_DIR"/files/etc/init.d/gateway_watchdog 2>/dev/null || true
chmod +x "$WORK_DIR"/files/etc/uci-defaults/99_gateway_watchdog 2>/dev/null || true

# Create install.sh
cat > "$WORK_DIR"/install.sh << 'EOF'
#!/bin/sh
# Install script for Gateway Watchdog LuCI app

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must be run as root." >&2
    exit 1
fi

echo "Installing Gateway Watchdog files..."
cp -a files/* /

# Run uci-defaults script if it exists
if [ -x /etc/uci-defaults/99_gateway_watchdog ]; then
    echo "Running uci-defaults..."
    /etc/uci-defaults/99_gateway_watchdog
fi

# Restart services
echo "Restarting services..."
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/gateway_watchdog start

echo "Gateway Watchdog installed. You can now access it at LuCI → Status → Gateway Watchdog."
EOF

chmod +x "$WORK_DIR"/install.sh

# Create uninstall.sh
cat > "$WORK_DIR"/uninstall.sh << 'EOF'
#!/bin/sh
# uninstall.sh – Remove Gateway Watchdog from OpenWrt

set -e

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

echo "Stopping gateway_watchdog service..."
/etc/init.d/gateway_watchdog stop 2>/dev/null || true

echo "Disabling gateway_watchdog service..."
/etc/init.d/gateway_watchdog disable 2>/dev/null || true

echo "Removing configuration and binaries..."
rm -f /etc/config/gateway_watchdog \
      /etc/init.d/gateway_watchdog \
      /usr/bin/gateway_watchdog.sh \
      /usr/libexec/rpcd/gateway-watchdog-status \
      /usr/share/rpcd/acl.d/luci-app-gateway-watchdog.json \
      /usr/share/luci/menu.d/luci-app-gateway-watchdog.json \
      /www/luci-static/resources/view/gateway-watchdog/*

# Remove the view directory if empty
rmdir /www/luci-static/resources/view/gateway-watchdog 2>/dev/null || true

echo "Restarting rpcd and uhttpd..."
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "Gateway Watchdog removed successfully."
EOF

chmod +x "$WORK_DIR"/uninstall.sh

# Create the tarball from the working directory
echo "Creating tarball $TARBALL_NAME..."
tar -czf "$TARBALL_NAME" -C "$WORK_DIR" .

# Clean up
rm -rf "$WORK_DIR"

echo "Done. To install on your router:"
echo "  scp $TARBALL_NAME root@router:/tmp/"
echo "  ssh root@router"
echo "  cd / && tar -xzf /tmp/$TARBALL_NAME && ./install.sh"
echo "To uninstall later, run: ./uninstall.sh"