#!/bin/sh

STATS_FILE="/tmp/gateway_watchdog_stats"
LOCK_FILE="/tmp/gateway_watchdog.lock"
HISTORY_FILE="/tmp/gateway_watchdog.history"
HISTORY_LOCK="/tmp/gateway_watchdog.history.lock"

LOG_TAG="gateway_watchdog"

load_config() {

    WAN_IFACE=$(uci -q get gateway_watchdog.settings.interface || echo "wan")
    DELAY=$(uci -q get gateway_watchdog.settings.delay || echo 10)
    MAX_FAILURES=$(uci -q get gateway_watchdog.settings.max_failures || echo 5)

    # Validate MAX_FAILURES (non-numeric → default to 5)
    case "$MAX_FAILURES" in
        ''|*[!0-9]*) MAX_FAILURES=5 ;;
    esac
    # Enforce minimum 1
    [ "$MAX_FAILURES" -lt 1 ] && MAX_FAILURES=1

    # Validate DELAY (non-numeric → default to 10)
    case "$DELAY" in
        ''|*[!0-9]*) DELAY=10 ;;
    esac
    [ "$DELAY" -lt 1 ] && DELAY=1

    # Validate COOLDOWN (non-numeric → default to 300)
    case "$COOLDOWN" in
        ''|*[!0-9]*) COOLDOWN=300 ;;
    esac

    COOLDOWN=$(uci -q get gateway_watchdog.settings.cooldown || echo 300)
    RECOVERY_MODE=$(uci -q get gateway_watchdog.settings.recovery_mode || echo "full")
    RECOVERY_VERIFY_TARGETS=$(uci -q get gateway_watchdog.settings.recovery_verify_RECOVERY_VERIFY_TARGETS || echo "8.8.8.8,1.1.1.1")
    LOG_TO_CONSOLE=$(uci -q get gateway_watchdog.settings.log_to_console || echo "0")

    RECOVERY_VERIFY_TARGETS=$(echo "$RECOVERY_VERIFY_TARGETS" | tr ',' ' ')
}

CHECK_COUNT=0
FAILURE_COUNT=0
RECOVERY_COUNT=0
CONSECUTIVE_FAILURES=0
PREV_CONSECUTIVE_FAILURES=0   # snapshot before reset — used by append_history
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

# Stats atomic write via temp+mv
write_stats() {
    local ts; ts=$(date +%s)
    {
        flock -x 200
        printf "total_checks=%s;total_failures=%s;total_recoveries=%s;current_status=%s;last_loop_time=%s;consecutive_failures=%s\n" \
            "$CHECK_COUNT" "$FAILURE_COUNT" "$RECOVERY_COUNT" \
            "$CURRENT_STATUS" "$ts" "$CONSECUTIVE_FAILURES" \
            > "${STATS_FILE}.tmp" \
        && mv "${STATS_FILE}.tmp" "$STATS_FILE"
    } 200>"$LOCK_FILE"
}

append_history() {
    local ts dt should_log=0 event="OK"
 
    ts=$(date +%s)
    dt=$(date '+%Y-%m-%d %H:%M:%S')
 
    # PREV_CONSECUTIVE_FAILURES is captured in the main loop *before* the
    # reset to 0, so a healthy status following failures is correctly tagged
    # as RECOVERY rather than OK.
    case "$CURRENT_STATUS" in
        healthy)
            [ "$PREV_CONSECUTIVE_FAILURES" -gt 0 ] && event="RECOVERY" || event="OK"
            ;;
        unhealthy|interface_down|cable_disconnected)
            event="FAILURE"
            ;;
        recovering)
            event="RECOVERY"
            ;;
        *)
            event="OK"
            ;;
    esac
 
    if [ "$CURRENT_STATUS" != "$LAST_STATUS" ] || [ "$event" != "$LAST_EVENT" ]; then
        should_log=1
    fi
 
    # Periodic heartbeat: skip check 0 to avoid a spurious entry at daemon
    # start (CHECK_COUNT % 10 is 0 before the first check runs).
    if [ "$CHECK_COUNT" -gt 0 ] && [ $((CHECK_COUNT % 10)) -eq 0 ]; then
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
 
        tail -n 50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
            && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    } 200>"$HISTORY_LOCK"
}

execute_recovery() {
    local mode="$1"
    local now rc gw target_result
    now=$(date +%s)
 
    # Cooldown protection
    if [ $((now - LAST_RECOVERY_TIME)) -lt "$COOLDOWN" ]; then
        local remaining=$((COOLDOWN - (now - LAST_RECOVERY_TIME)))
        log "RECOVERY SKIPPED | mode=$mode | reason=cooldown | remaining=${remaining}s"
        return 2
    fi
 
    LAST_RECOVERY_TIME=$now
    RECOVERY_COUNT=$((RECOVERY_COUNT + 1))
    CURRENT_STATUS="recovering"
 
    log "RECOVERY START | attempt=$RECOVERY_COUNT | mode=$mode | consecutive_failures=$CONSECUTIVE_FAILURES | interface=$WAN_IFACE"
 
    case "$mode" in
        none)
            log "RECOVERY ACTION | mode=none | action=no-op"
            ;;
 
        ping-retry)
            # Lightweight mode: no interface changes, just waits and re-checks.
            # Does not fix routing or DHCP — use for transient single-packet loss.
            log "RECOVERY ACTION | mode=ping-retry | action=wait_2s"
            sleep 2
            ;;
 
        standard)
            log "RECOVERY ACTION | mode=standard | action=ifdown interface=$WAN_IFACE"
            ifdown "$WAN_IFACE"
            log "RECOVERY ACTION | mode=standard | action=sleep_2s"
            sleep 2
            log "RECOVERY ACTION | mode=standard | action=ifup interface=$WAN_IFACE"
            ifup "$WAN_IFACE"
            log "RECOVERY ACTION | mode=standard | action=sleep_5s (waiting for link)"
            sleep 5
            ;;
 
        route-flush)
            log "RECOVERY ACTION | mode=route-flush | action=ip_route_flush dev=$WAN_IFACE"
            ip route flush dev "$WAN_IFACE"
            rc=$?
            log "RECOVERY ACTION | mode=route-flush | route_flush_rc=$rc"
            sleep 2
            ;;
 
        dhcp-renew)
            log "RECOVERY ACTION | mode=dhcp-renew | action=ubus_renew interface=$WAN_IFACE"
            ubus call network.interface."$WAN_IFACE" renew
            rc=$?
            if [ $rc -ne 0 ]; then
                log "RECOVERY ACTION | mode=dhcp-renew | ubus_renew_rc=$rc | warning=ubus_call_failed"
            else
                log "RECOVERY ACTION | mode=dhcp-renew | ubus_renew_rc=0"
            fi
            sleep 5
            ;;
 
        full)
            log "RECOVERY ACTION | mode=full | action=ifdown interface=$WAN_IFACE"
            ifdown "$WAN_IFACE"
            log "RECOVERY ACTION | mode=full | action=sleep_2s"
            sleep 2
            log "RECOVERY ACTION | mode=full | action=ip_route_flush dev=$WAN_IFACE"
            ip route flush dev "$WAN_IFACE"
            log "RECOVERY ACTION | mode=full | action=ifup interface=$WAN_IFACE"
            ifup "$WAN_IFACE"
            log "RECOVERY ACTION | mode=full | action=sleep_6s (waiting for link)"
            sleep 6
            ;;
 
        reboot)
            log "RECOVERY ACTION | mode=reboot | action=sync_and_reboot"
            sync
            reboot
            sleep 10   # prevent the loop acting during kernel shutdown window
            ;;
 
        *)
            log "RECOVERY ERROR | mode=$mode | reason=unknown_recovery_mode | action=none"
            return 1
            ;;
    esac
 
    # Verify recovery against each diagnostic target
    if [ -z "$TARGETS" ]; then
        log "RECOVERY VERIFY | warning=no_targets_configured | result=assumed_failed"
        return 1
    fi
 
    for t in $TARGETS; do
        if check_connectivity "$t"; then
            log "RECOVERY SUCCESS | mode=$mode | verify_target=$t | result=reachable"
            return 0
        else
            log "RECOVERY VERIFY | mode=$mode | verify_target=$t | result=unreachable"
        fi
    done
 
    log "RECOVERY FAILED | mode=$mode | all_targets_unreachable"
    return 1
}

cleanup() {
    log "Daemon stopping gracefully"
    exit 0
}
trap cleanup TERM INT

daemon_loop() {
    load_config
 
    log "Daemon started | interface=$WAN_IFACE | delay=${DELAY}s | max_failures=$MAX_FAILURES | cooldown=${COOLDOWN}s | recovery_mode=$RECOVERY_MODE"
 
    while true; do
        CHECK_COUNT=$((CHECK_COUNT + 1))
 
        # ── Physical link check ───────────────────────────────────────────────
        if ! is_cable_plugged "$WAN_IFACE"; then
            CURRENT_STATUS="cable_disconnected"
            log "Cable unplugged on $WAN_IFACE — pausing checks"
 
            write_stats
            append_history
 
            while ! is_cable_plugged "$WAN_IFACE"; do
                sleep 5
                CHECK_COUNT=$((CHECK_COUNT + 1))
            done
 
            log "Cable reconnected on $WAN_IFACE — resuming"
            CURRENT_STATUS="recovering"
            PREV_CONSECUTIVE_FAILURES=$CONSECUTIVE_FAILURES
            CONSECUTIVE_FAILURES=0
            continue
        fi
 
        # ── Routing / gateway check ───────────────────────────────────────────
        GW=$(get_gateway_ip)
 
        if [ -z "$GW" ]; then
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            CURRENT_STATUS="unhealthy"
            log "No default route | failure=$CONSECUTIVE_FAILURES/$MAX_FAILURES"
        else
            if check_connectivity "$GW"; then
                PREV_CONSECUTIVE_FAILURES=$CONSECUTIVE_FAILURES
                CONSECUTIVE_FAILURES=0
                CURRENT_STATUS="healthy"
            else
                FAILURE_COUNT=$((FAILURE_COUNT + 1))
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
                CURRENT_STATUS="unhealthy"
                log "Gateway unreachable | gw=$GW | failure=$CONSECUTIVE_FAILURES/$MAX_FAILURES"
            fi
        fi
 
        # ── Recovery trigger ──────────────────────────────────────────────────
        if [ "$CURRENT_STATUS" = "unhealthy" ] && [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
            execute_recovery "$RECOVERY_MODE"
            rc=$?
            case $rc in
                0)
                    PREV_CONSECUTIVE_FAILURES=$CONSECUTIVE_FAILURES
                    CONSECUTIVE_FAILURES=0
                    CURRENT_STATUS="healthy"
                    ;;
                2)
                    # Cooldown skip — stay unhealthy, do not reset counter
                    CURRENT_STATUS="unhealthy"
                    ;;
                *)
                    CURRENT_STATUS="recovering"
                    ;;
            esac
        fi
 
        write_stats
        append_history
        sleep "$DELAY"
    done
}

daemon_loop