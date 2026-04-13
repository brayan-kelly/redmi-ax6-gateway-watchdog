#!/bin/sh

STATS_FILE="/tmp/gateway_watchdog_stats"
LOCK_FILE="/tmp/gateway_watchdog.lock"
HISTORY_FILE="/tmp/gateway_watchdog.history"
HISTORY_LOCK="/tmp/gateway_watchdog.history.lock"

LOG_TAG="gateway_watchdog"

# ================= CONFIG =================
load_config() {
    WAN_IFACE=$(uci -q get gateway_watchdog.settings.interface || echo "wan")

    DELAY=$(uci -q get gateway_watchdog.settings.delay || echo 10)
    MAX_FAILURES=$(uci -q get gateway_watchdog.settings.max_failures || echo 3)
    COOLDOWN=$(uci -q get gateway_watchdog.settings.cooldown || echo 300)

    # Apply numeric validation and minimum clamp to DELAY and COOLDOWN,
    # matching the same guard already applied to MAX_FAILURES. A non-numeric
    # UCI value would otherwise cause sleep/comparison failures and a CPU spin.
    case "$DELAY" in
        ''|*[!0-9]*) DELAY=10 ;;
    esac
    [ "$DELAY" -lt 1 ] && DELAY=1

    case "$MAX_FAILURES" in
        ''|*[!0-9]*) MAX_FAILURES=3 ;;
    esac
    [ "$MAX_FAILURES" -lt 1 ] && MAX_FAILURES=1

    case "$COOLDOWN" in
        ''|*[!0-9]*) COOLDOWN=300 ;;
    esac
    [ "$COOLDOWN" -lt 1 ] && COOLDOWN=1

    RECOVERY_MODE=$(uci -q get gateway_watchdog.settings.recovery_mode || echo "full")

    RECOVERY_VERIFY_TARGETS=$(uci -q get gateway_watchdog.settings.recovery_verify_targets || echo "8.8.8.8,1.1.1.1")
    RECOVERY_VERIFY_TARGETS=$(echo "$RECOVERY_VERIFY_TARGETS" | tr ',' ' ')

    LOG_TO_CONSOLE=$(uci -q get gateway_watchdog.settings.log_to_console || echo "0")
}

# ================= STATE =================
CHECK_COUNT=0
FAILURE_COUNT=0
RECOVERY_COUNT=0
CONSECUTIVE_FAILURES=0
LAST_STATUS=""
LAST_EVENT=""
LAST_RECOVERY_TIME=0
CURRENT_STATUS="initializing"

log() {
    logger -t "$LOG_TAG" "$1"
    if [ "$LOG_TO_CONSOLE" = "1" ] && [ -t 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
    fi
}

is_cable_plugged() {
    local iface="${1:-wan}" dev phy carrier state

    dev=$(uci -q get network."$iface".device 2>/dev/null)
    [ -z "$dev" ] && dev=$(uci -q get network."$iface".ifname 2>/dev/null)
    [ -z "$dev" ] && dev="$iface"

    if [ -d "/sys/class/net/$dev/brif" ]; then
        phy=$(ls /sys/class/net/"$dev"/brif 2>/dev/null | head -n1)
        [ -n "$phy" ] && dev="$phy"
    fi

    if [ -f "/sys/class/net/$dev/carrier" ]; then
        carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null)
        [ "$carrier" = "1" ] && return 0
        [ "$carrier" = "0" ] && return 1
    fi

    if [ -f "/sys/class/net/$dev/operstate" ]; then
        state=$(cat "/sys/class/net/$dev/operstate" 2>/dev/null)
        case "$state" in
            up|unknown) return 0 ;;
            down|dormant|lowerlayerdown) return 1 ;;
        esac
    fi

    # Log a warning when falling back to directory-existence check so
    # operators can identify interfaces where carrier/operstate are unavailable
    # (e.g. virtual interfaces, some USB adapters) and detection is unreliable.
    if [ -d "/sys/class/net/$dev" ]; then
        log "WARN | cable detection fallback for $dev — no carrier/operstate in sysfs, assuming up"
        return 0
    fi

    return 1
}

get_gateway_ip() {
    ip route | awk '/default/ {print $3; exit}'
}

check_connectivity() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

internet_ok() {
    for t in $RECOVERY_VERIFY_TARGETS; do
        check_connectivity "$t" && return 0
    done
    return 1
}

write_stats() {
    local ts; ts=$(date +%s)
    {
        flock -x 200
        printf "total_checks=%s;total_failures=%s;total_recoveries=%s;current_status=%s;last_loop_time=%s;consecutive_failures=%s\n" \
            "$CHECK_COUNT" "$FAILURE_COUNT" "$RECOVERY_COUNT" \
            "$CURRENT_STATUS" "$ts" "$CONSECUTIVE_FAILURES" \
            > "${STATS_FILE}.tmp"
        mv "${STATS_FILE}.tmp" "$STATS_FILE"
    } 200>"$LOCK_FILE"
}

# Raised periodic OK logging from every 10 to every 100 checks.
# At 10s/check this is ~16 min, preventing the 50-line history cap from
# being consumed by noise during stable operation.
append_history() {
    local ts dt should_log=0 event="OK"

    ts=$(date +%s)
    dt=$(date '+%Y-%m-%d %H:%M:%S')

    case "$CURRENT_STATUS" in
        healthy) [ "$CONSECUTIVE_FAILURES" -gt 0 ] && event="RECOVERY" || event="OK" ;;
        unhealthy|interface_down|cable_disconnected) event="FAILURE" ;;
        recovering) event="RECOVERY" ;;
        *) event="OK" ;;
    esac

    if [ "$CURRENT_STATUS" != "$LAST_STATUS" ] || [ "$event" != "$LAST_EVENT" ]; then
        should_log=1
    fi

    if [ $((CHECK_COUNT % 100)) -eq 0 ]; then
        should_log=1
    fi

    [ "$should_log" -eq 0 ] && return

    LAST_STATUS="$CURRENT_STATUS"
    LAST_EVENT="$event"

    {
        flock -x 200
        printf "%s|%s|%s|%s|%s|%s|%s\n" \
            "$ts" "$dt" "$CHECK_COUNT" "$FAILURE_COUNT" \
            "$RECOVERY_COUNT" "$CURRENT_STATUS" "$event" \
            >> "$HISTORY_FILE"

        tail -n 50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    } 200>"$HISTORY_LOCK"
}

execute_recovery() {
    local mode="$1"
    local now; now=$(date +%s)

    if [ $((now - LAST_RECOVERY_TIME)) -lt "$COOLDOWN" ]; then
        log "Recovery skipped (cooldown active)"
        return 2
    fi

    LAST_RECOVERY_TIME=$now
    RECOVERY_COUNT=$((RECOVERY_COUNT+1))
    CURRENT_STATUS="recovering"

    log "Recovery triggered (mode: $mode)"

    case "$mode" in
        none)
            return 0
            ;;

        standard)
            ifdown "$WAN_IFACE"; sleep 2; ifup "$WAN_IFACE"; sleep 5
            ;;

        dhcp-renew)
            ubus call network.interface."$WAN_IFACE" renew; sleep 5
            ;;

        lan-reset)
            ifdown lan; sleep 2
            ip route flush dev lan
            ifup lan; sleep 6
            ;;

        full)
            ifdown "$WAN_IFACE"; sleep 2
            ip route flush dev "$WAN_IFACE"
            ifup "$WAN_IFACE"; sleep 6
            ifdown lan; sleep 2
            ifup lan; sleep 6
            ;;

        # sleep 30 added after reboot so execution stalls until the
        # system halts rather than falling through to the internet_ok check,
        # which would always fail and return 1, setting CURRENT_STATUS to
        # "recovering" based on a spurious post-reboot verification failure.
        reboot)
            log "Rebooting system"
            sync; reboot; sleep 30
            return 0
            ;;
    esac

    internet_ok && return 0
    return 1
}

daemon_loop() {
    load_config

    while true; do
        CHECK_COUNT=$((CHECK_COUNT+1))

        if ! is_cable_plugged "$WAN_IFACE"; then
            CURRENT_STATUS="cable_disconnected"
            log "Cable unplugged on $WAN_IFACE — stopping service. Hotplug will restart on reconnect."

            write_stats
            append_history

            # Stop the service cleanly via procd. The hotplug script at
            # /etc/hotplug.d/net/30-gateway-watchdog will restart it when
            # the physical link comes back up.
            /etc/init.d/gateway_watchdog stop
            exit 0
        fi

        GW=$(get_gateway_ip)

        if [ -z "$GW" ]; then
            FAILURE_COUNT=$((FAILURE_COUNT+1))
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES+1))
            CURRENT_STATUS="unhealthy"
            log "No default route (failure $CONSECUTIVE_FAILURES/$MAX_FAILURES)"
        else
            # Combined gateway ping + internet_ok so the healthy path
            # uses the same targets as recovery verification. Previously a
            # working LAN with no internet would be incorrectly marked healthy.
            if check_connectivity "$GW" && internet_ok; then
                CURRENT_STATUS="healthy"
                CONSECUTIVE_FAILURES=0
            else
                FAILURE_COUNT=$((FAILURE_COUNT+1))
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES+1))
                CURRENT_STATUS="unhealthy"
                log "Failure ($CONSECUTIVE_FAILURES/$MAX_FAILURES)"
            fi
        fi

        if [ "$CURRENT_STATUS" = "unhealthy" ] && [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
            execute_recovery "$RECOVERY_MODE"
            rc=$?
            if [ $rc -eq 0 ]; then
                CURRENT_STATUS="healthy"
                CONSECUTIVE_FAILURES=0
            elif [ $rc -eq 2 ]; then
                CURRENT_STATUS="unhealthy"
            else
                CURRENT_STATUS="recovering"
            fi
        fi

        write_stats
        append_history
        sleep "$DELAY"
    done
}

daemon_loop