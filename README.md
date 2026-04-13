# Gateway Watchdog for Redmi AX6 (OpenWrt)

[![Publish Release](https://github.com/brayan-kelly/redmi-ax6-gateway-watchdog/actions/workflows/publish-release.yml/badge.svg)](https://github.com/brayan-kelly/redmi-ax6-gateway-watchdog/actions/workflows/publish-release.yml)
[![Latest Release](https://img.shields.io/github/v/release/brayan-kelly/redmi-ax6-gateway-watchdog)](https://github.com/brayan-kelly/redmi-ax6-gateway-watchdog/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A LuCI app that monitors your WAN connectivity and automatically recovers when the gateway becomes unreachable. Designed for OpenWrt on the Redmi AX6 but should work on any OpenWrt device.

## Features

- Periodic connectivity checks (ping to gateway and configurable diagnostic targets)
- Configurable failure threshold and cooldown period
- Multiple recovery modes: none, standard ifdown/ifup, DHCP renew, full interface restart, or system reboot
- Automatic service stop on cable disconnect and automatic restart via hotplug when the cable is reconnected
- Web UI with real-time status dashboard and configuration page
- Persists across firmware upgrades (sysupgrade)
- Logs to syslog and optionally to console

## Installation

### Build the tarball

```sh
./create-gateway-watchdog-tarball.sh
```

This creates `luci-app-gateway-watchdog.tar.gz` in the current directory.

### Install on the router

Copy both files to your router, verify the checksum, then install:

```sh
scp luci-app-gateway-watchdog.tar.gz \
    root@router:/tmp/
ssh root@router
mkdir -p /tmp/gw-install
tar -xzf /tmp/luci-app-gateway-watchdog.tar.gz -C /tmp/gw-install
sh /tmp/gw-install/install.sh
```

The installer copies all files, strips CRLF line endings from the init script, initialises the UCI configuration, enables the service, and starts it immediately. No manual steps are required after running `install.sh`.

> **Note for macOS users:** Always transfer files using `scp` from the terminal rather than Finder. Finder transfers inject `._` metadata files and may introduce CRLF line endings that break the LuCI Startup page. Set `git config --global core.autocrlf false` and ensure your editor saves shell scripts with LF line endings.

## Configuration

After installation, navigate to **LuCI → Status → Gateway Watchdog** to view the dashboard and adjust settings.

| Option | Description | Default |
|--------|-------------|---------|
| Enable | Turn the watchdog on/off | Enabled |
| WAN Interface | Network interface to monitor | wan |
| Check Interval (seconds) | Time between connectivity checks | 10 |
| Max Failures | Consecutive failures before recovery is triggered | 5 |
| Cooldown (seconds) | Minimum wait time between recovery attempts | 300 |
| Recovery Mode | Action taken when internet is unreachable | full |
| Diagnostic Targets | Comma-separated IPs to ping for verification | 8.8.8.8,1.1.1.1 |
| Log to Console | Also log messages to the console (useful for debugging) | Off |

### Recovery Modes

| Mode | Description |
|------|-------------|
| `none` | No action, only logs failures |
| `standard` | `ifdown` / `ifup` on the monitored interface |
| `dhcp-renew` | Renew the DHCP lease |
| `full` | `ifdown` + route flush + `ifup` (recommended) |
| `reboot` | Reboot the system (use with caution) |

## Cable Disconnect Behaviour

When a cable disconnection is detected the watchdog stops itself cleanly and writes a final `cable_disconnected` entry to the status and history files so the LuCI dashboard reflects the correct state.

When the cable is reconnected, the hotplug script at `/etc/hotplug.d/iface/30-gateway-watchdog` listens for the `ifup` event on the configured WAN interface — fired by netifd after DHCP completes — and restarts the watchdog automatically. No manual intervention is required.

## Sysupgrade Persistence

The uci-defaults script adds the UCI configuration file to `/etc/sysupgrade.conf` so it survives a firmware upgrade:

- `/etc/config/gateway_watchdog` — UCI configuration (user data, preserved)

All other files (binaries, LuCI assets, init script, hotplug script) are package-managed and must be reinstalled after a firmware upgrade by running `install.sh` again. This ensures you always get the correct version for the new firmware rather than restoring a potentially stale pre-upgrade copy.

## File Structure

```
files/
├── etc/
│   ├── config/
│   │   └── gateway_watchdog               # UCI config (default values)
│   ├── hotplug.d/
│   │   └── iface/
│   │       └── 30-gateway-watchdog        # Auto-restart on cable reconnect
│   ├── init.d/
│   │   └── gateway_watchdog              # procd init script
│   └── uci-defaults/
│       └── 99_gateway_watchdog           # One-time setup script
├── usr/
│   ├── bin/
│   │   └── gateway_watchdog.sh           # Core monitoring daemon
│   ├── libexec/
│   │   └── rpcd/
│   │       └── gateway-watchdog-status   # RPC endpoint for LuCI
│   └── share/
│       ├── rpcd/
│       │   └── acl.d/
│       │       └── luci-app-gateway-watchdog.json
│       └── luci/
│           └── menu.d/
│               └── luci-app-gateway-watchdog.json
└── www/
    └── luci-static/
        └── resources/
            └── view/
                └── gateway-watchdog/
                    ├── status.js
                    └── config.js
```

## Uninstallation

```sh
sh /tmp/gw-install/uninstall.sh
```

This stops the service, removes all installed files, clears the UCI configuration, and restarts `rpcd` and `uhttpd`.

## License

MIT License — see the [LICENSE](LICENSE.md) file for details.