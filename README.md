# Gateway Watchdog for Redmi AX6 (OpenWrt)

[![Publish Release](https://github.com/brayan-kelly/redmi-ax6-gateway-watchdog/actions/workflows/publish-release.yml/badge.svg)](https://github.com/brayan-kelly/redmi-ax6-gateway-watchdog/actions/workflows/publish-release.yml)
[![Latest Release](https://img.shields.io/github/v/release/brayan-kelly/redmi-ax6-gateway-watchdog)](https://github.com/brayan-kelly/redmi-ax6-gateway-watchdog/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A LuCI app that monitors your WAN connectivity and automatically recovers when the gateway becomes unreachable. Designed for OpenWrt on the Redmi AX6 but it should work on any OpenWrt device.

## Features

- Periodic connectivity checks (ping to gateway and/or configurable targets)
- Configurable failure threshold and cooldown period
- Multiple recovery modes: none, ping‑retry, standard ifdown/ifup, route flush, DHCP renew, full interface restart, or system reboot
- Web UI with real‑time status and configuration page
- Persists across firmware upgrades (sysupgrade)
- Logs to syslog and optionally to console

## Installation

### Build the tarball

```sh
./create-gateway-watchdog-tarball.sh
```

This creates `luci-app-gateway-watchdog.tar.gz` in the current directory.

### Install on the router

Copy the tarball to your router and extract it:

```sh
scp luci-app-gateway-watchdog.tar.gz root@router:/tmp/
ssh root@router
cd / && tar -xzf /tmp/luci-app-gateway-watchdog.tar.gz && ./install.sh
```
The installer copies all files, runs the uci‑defaults script (which initialises the configuration if needed), and starts the service.

## Configuration

After installation, navigate to LuCI → Status → Gateway Watchdog to view the dashboard and adjust settings.

Available options:

| Option | Description | Default |
|--------|-------------|---------|
| Enable | Turn the watchdog on/off | Enabled |
| WAN Interface | Network interface to monitor | wan |
| Check Interval (seconds) | Time between checks | 50 |
| Max Failures | Consecutive failures before recovery | 3 |
| Cooldown (seconds) | Wait time between recovery attempts | 300 |
| Recovery Mode | Action when internet is down | full |
| Diagnostic Targets | Comma‑separated IPs to ping for verification | 8.8.8.8,1.1.1.1 |
| Log to Console | Also log messages to the console (useful for debugging) | Off |

### Recovery Modes

- none – No action, only logs failures
- ping-retry – Wait a few seconds and retry
- standard – ifdown / ifup on the monitored interface
- route-flush – Flush routes for the interface
- dhcp-renew – Renew DHCP lease
- full – ifdown + route flush + ifup (recommended)
- reboot – Reboot the system (use with caution)

## Sysupgrade Persistence

The uci‑defaults script (`/etc/uci-defaults/99_gateway_watchdog`) adds all relevant files to `/etc/sysupgrade.conf`:

- /etc/config/gateway_watchdog – UCI configuration
- /etc/init.d/gateway_watchdog – Init script
- /usr/bin/gateway_watchdog.sh – Main monitoring script
- /usr/libexec/rpcd/gateway-watchdog-status – RPC endpoint for the LuCI UI
- /usr/share/rpcd/acl.d/luci-app-gateway-watchdog.json – ACL definition
- /usr/share/luci/menu.d/luci-app-gateway-watchdog.json – LuCI menu entry
- /www/luci-static/resources/view/gateway-watchdog/ – LuCI view files

This ensures your configuration and custom files survive a firmware upgrade.

## File Structure
```
files/
├── etc/
│   ├── config/
│   │   └── gateway_watchdog          # UCI config
│   ├── init.d/
│   │   └── gateway_watchdog          # Init script
│   └── uci-defaults/
│       └── 99_gateway_watchdog       # One‑time setup script
├── usr/
│   ├── bin/
│   │   └── gateway_watchdog.sh       # Core monitoring daemon
│   ├── libexec/
│   │   └── rpcd/
│   │       └── gateway-watchdog-status  # RPC for LuCI
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

The tarball includes an uninstall script. To remove the package, simply run:

```sh
./uninstall.sh
```
This will stop the service, remove all installed files, and restart `rpcd` and `uhttpd`.

## License

MIT License – see the LICENSE file for details.