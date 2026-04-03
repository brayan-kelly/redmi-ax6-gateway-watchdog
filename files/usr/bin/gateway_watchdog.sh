#!/bin/sh

STATS_FILE="/tmp/gateway_watchdog_stats"
LOCK_FILE="/tmp/gateway_watchdog.lock"
HISTORY_FILE="/tmp/gateway_watchdog.history"
HISTORY_LOCK="/tmp/gateway_watchdog.history.lock"
PIDFILE="/var/run/gateway_watchdog.pid"

LOG_TAG="gateway_watchdog"

load_config() {
    # Check if watchdog is enabled
    ENABLED=$(uci -q get gateway_watchdog.settings.enabled || echo "1")
    [ "$ENABLED" = "0" ] && {
        echo "Gateway Watchdog disabled. Exiting."
        exit 0
    }

    WAN_IFACE=$(uci -q get gateway_watchdog.settings.interface || echo "wan")
    DELAY=$(uci -q get gateway_watchdog.settings.delay || echo 10)
    MAX_FAILURES=$(uci -q get gateway_watchdog.settings.max_failures || echo 3)

    # Validate MAX_FAILURES (non-numeric → default to 3)
    case "$MAX_FAILURES" in
        ''|*[!0-9]*) MAX_FAILURES=3 ;;
    esac
    # Enforce minimum 1
    [ "$MAX_FAILURES" -lt 1 ] && MAX_FAILURES=1

    COOLDOWN=$(uci -q get gateway_watchdog.settings.cooldown || echo 300)
    RECOVERY_MODE=$(uci -q get gateway_watchdog.settings.recovery_mode || echo "full")
    TARGETS=$(uci -q get gateway_watchdog.settings.diagnostic_targets || echo "8.8.8.8,1.1.1.1")
    LOG_TO_CONSOLE=$(uci -q get gateway_watchdog.settings.log_to_console || echo "0")

    TARGETS=$(echo "$TARGETS" | tr ',' ' ')
}

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
    # Only echo to console if we are on a real terminal (manual run), not under procd
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

    [ -d "/sys/class/net/$dev" ] && return 0
    return 1
}

get_gateway_ip() {
    ip route | awk '/default/ {print $3; exit}'
}

check_connectivity() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

write_stats() {
    local ts; ts=$(date +%s)
    {
        flock -x 200
        printf "total_checks=%s;total_failures=%s;total_recoveries=%s;current_status=%s;last_loop_time=%s;consecutive_failures=%s\n" \
            "$CHECK_COUNT" "$FAILURE_COUNT" "$RECOVERY_COUNT" "$CURRENT_STATUS" "$ts" "$CONSECUTIVE_FAILURES" > "$STATS_FILE"
    } 200>"$LOCK_FILE"
}

append_history() {
    local ts dt should_log=0 event="OK"

    ts=$(date +%s)
    dt=$(date '+%Y-%m-%d %H:%M:%S')

    case "$CURRENT_STATUS" in
        healthy) [ "$CONSECUTIVE_FAILURES" -gt 0 ] && event="RECOVERY" || event="OK" ;;
        unhealthy|interface_down) event="FAILURE" ;;
        recovering) event="RECOVERY" ;;
        cable_disconnected) event="FAILURE" ;;
        *) event="OK" ;;
    esac

    if [ "$CURRENT_STATUS" != "$LAST_STATUS" ] || [ "$event" != "$LAST_EVENT" ]; then
        should_log=1
    fi

    if [ $((CHECK_COUNT % 10)) -eq 0 ]; then
        should_log=1
    fi

    [ "$should_log" -eq 0 ] && return

    LAST_STATUS="$CURRENT_STATUS"
    LAST_EVENT="$event"

    {
        flock -x 200
        printf "%s|%s|%s|%s|%s|%s|%s\n" \
            "$ts" "$dt" "$CHECK_COUNT" "$FAILURE_COUNT" "$RECOVERY_COUNT" "$CURRENT_STATUS" "$event" \
            >> "$HISTORY_FILE"

        tail -n 50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    } 200>"$HISTORY_LOCK"
}

execute_recovery() {
    local mode="$1"
    local now; now=$(date +%s)

    # Cooldown protection – return 2 to signal skip, not success
    if [ $((now - LAST_RECOVERY_TIME)) -lt "$COOLDOWN" ]; then
        log "Recovery skipped (cooldown active)"
        return 2
    fi

    LAST_RECOVERY_TIME=$now
    RECOVERY_COUNT=$((RECOVERY_COUNT+1))
    CURRENT_STATUS="recovering"

    log "Recovery triggered (mode: $mode)"

    case "$mode" in
        none) return 0 ;;

        ping-retry) sleep 2 ;;

        standard)
            ifdown "$WAN_IFACE"; sleep 2; ifup "$WAN_IFACE"; sleep 5
        ;;

        route-flush)
            ip route flush dev "$WAN_IFACE"; sleep 2
        ;;

        dhcp-renew)
            ubus call network.interface."$WAN_IFACE" renew; sleep 5
        ;;

        full)
            ifdown "$WAN_IFACE"; sleep 2
            ip route flush dev "$WAN_IFACE"
            ifup "$WAN_IFACE"; sleep 6
        ;;

        reboot)
            log "Rebooting system"
            sync; reboot
        ;;
    esac

    # Verify recovery
    for t in $TARGETS; do
        check_connectivity "$t" && return 0
    done

    return 1
}

daemon_loop() {
    load_config

    while true; do
        CHECK_COUNT=$((CHECK_COUNT+1))

        if ! is_cable_plugged "$WAN_IFACE"; then
            CURRENT_STATUS="cable_disconnected"
            log "Cable unplugged - pausing"

            write_stats
            append_history

            while ! is_cable_plugged "$WAN_IFACE"; do
                sleep 5
            done

            log "Cable reconnected"
            CURRENT_STATUS="recovering"
            CONSECUTIVE_FAILURES=0
            continue
        fi

        GW=$(get_gateway_ip)

        # Handle no default route explicitly
        if [ -z "$GW" ]; then
            FAILURE_COUNT=$((FAILURE_COUNT+1))
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES+1))
            CURRENT_STATUS="unhealthy"
            log "No default route (failure $CONSECUTIVE_FAILURES/$MAX_FAILURES)"
        else
            # Check gateway
            if check_connectivity "$GW"; then
                CURRENT_STATUS="healthy"
                CONSECUTIVE_FAILURES=0
            else
                FAILURE_COUNT=$((FAILURE_COUNT+1))
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES+1))
                CURRENT_STATUS="unhealthy"
                log "Failure ($CONSECUTIVE_FAILURES/$MAX_FAILURES)"
            fi
        fi

        # Trigger recovery if threshold reached
        if [ "$CURRENT_STATUS" = "unhealthy" ] && [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
            execute_recovery "$RECOVERY_MODE"
            rc=$?
            if [ $rc -eq 0 ]; then
                CURRENT_STATUS="healthy"
                CONSECUTIVE_FAILURES=0
            elif [ $rc -eq 2 ]; then
                # Cooldown skip – remain unhealthy, failures not reset
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
