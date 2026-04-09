#!/bin/sh

STATS_FILE="/tmp/gateway_watchdog_stats"
LOCK_FILE="/tmp/gateway_watchdog.lock"

LOG_TAG="gateway_watchdog"

load_config() {
    WAN_IFACE=$(uci -q get gateway_watchdog.settings.interface || echo "wan")
    DELAY=$(uci -q get gateway_watchdog.settings.delay || echo 10)
    MAX_FAILURES=$(uci -q get gateway_watchdog.settings.max_failures || echo 5)
    COOLDOWN=$(uci -q get gateway_watchdog.settings.cooldown || echo 300)
    RECOVERY_MODE=$(uci -q get gateway_watchdog.settings.recovery_mode || echo "full")
    TARGETS=$(uci -q get gateway_watchdog.settings.recovery_verify_targets || echo "8.8.8.8,1.1.1.1")

    case "$DELAY" in ''|*[!0-9]*) DELAY=10 ;; esac
    case "$MAX_FAILURES" in ''|*[!0-9]*) MAX_FAILURES=5 ;; esac
    case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=300 ;; esac

    [ "$DELAY" -lt 1 ] && DELAY=1
    [ "$MAX_FAILURES" -lt 1 ] && MAX_FAILURES=1
    [ "$COOLDOWN" -lt 1 ] && COOLDOWN=1

    TARGETS=$(echo "$TARGETS" | tr ',' ' ')
}

CHECK_COUNT=0
CONSECUTIVE_FAILURES=0
LAST_RECOVERY_TIME=0
CURRENT_STATUS="initializing"
FAIL_REASON=""

START_TIME=$(date +%s)
GRACE_PERIOD=60

log() {
    logger -t "$LOG_TAG" "$1"
}

is_iface_up() {
    ip link show "$WAN_IFACE" 2>/dev/null | grep -q "state UP"
}

is_iface_ready() {
    ubus call network.interface."$WAN_IFACE" status 2>/dev/null | grep -q '"up": true'
}

get_gateway_ip() {
    ip route | awk '/default/ {print $3; exit}'
}

check_connectivity() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

#Boot intelligence
boot_wait() {
    local now uptime
    now=$(date +%s)
    uptime=$((now - START_TIME))

    #Phase 1: Grace period
    if [ "$uptime" -lt "$GRACE_PERIOD" ]; then
        CURRENT_STATUS="initializing"
        log "BOOT WAIT | grace period | uptime=${uptime}s/${GRACE_PERIOD}s"
        return 1
    fi

    #Phase 2: Interface link
    if ! is_iface_up; then
        CURRENT_STATUS="initializing"
        log "BOOT WAIT | interface down"
        return 1
    fi

    #Phase 3: Interface ready (DHCP)
    if ! is_iface_ready; then
        CURRENT_STATUS="initializing"
        log "BOOT WAIT | interface not ready (DHCP)"
        return 1
    fi

    #Phase 4: Default route
    if [ -z "$(get_gateway_ip)" ]; then
        CURRENT_STATUS="initializing"
        log "BOOT WAIT | no default route yet"
        return 1
    fi

    return 0
}

execute_recovery() {
    local mode="$RECOVERY_MODE"
    local now elapsed

    now=$(date +%s)
    elapsed=$((now - LAST_RECOVERY_TIME))

    # Cooldown with bypass
    if [ "$elapsed" -lt "$COOLDOWN" ]; then
        if [ "$CONSECUTIVE_FAILURES" -lt $((MAX_FAILURES * 2)) ]; then
            log "RECOVERY SKIPPED | cooldown"
            return 2
        else
            log "RECOVERY FORCED | bypass cooldown"
        fi
    fi

    #Failure override
    [ "$FAIL_REASON" = "no_route" ] && mode="full"

    #Escalation
    if [ "$CONSECUTIVE_FAILURES" -ge $((MAX_FAILURES * 3)) ]; then
        mode="reboot"
    elif [ "$CONSECUTIVE_FAILURES" -ge $((MAX_FAILURES * 2)) ]; then
        mode="full"
    fi

    LAST_RECOVERY_TIME=$now
    CURRENT_STATUS="recovering"

    log "RECOVERY START | mode=$mode | failures=$CONSECUTIVE_FAILURES"

    case "$mode" in
        ping-retry) sleep 2 ;;
        standard) ifdown "$WAN_IFACE"; sleep 2; ifup "$WAN_IFACE"; sleep 5 ;;
        route-flush) ip route flush dev "$WAN_IFACE"; sleep 2 ;;
        dhcp-renew) ubus call network.interface."$WAN_IFACE" renew; sleep 5 ;;
        full)
            ifdown "$WAN_IFACE"; sleep 2
            ip route flush dev "$WAN_IFACE"
            ifup "$WAN_IFACE"; sleep 6
            ;;
        reboot) sync; reboot; sleep 10 ;;
    esac

    for t in $TARGETS; do
        if check_connectivity "$t"; then
            log "RECOVERY SUCCESS | target=$t"
            CONSECUTIVE_FAILURES=0
            CURRENT_STATUS="healthy"
            return 0
        fi
    done

    log "RECOVERY FAILED"
    return 1
}

daemon_loop() {
    load_config

    log "START | iface=$WAN_IFACE delay=${DELAY}s max_failures=$MAX_FAILURES cooldown=${COOLDOWN}s"

    while true; do
        CHECK_COUNT=$((CHECK_COUNT + 1))

        #Boot intelligence gate
        if ! boot_wait; then
            sleep "$DELAY"
            continue
        fi

        GW=$(get_gateway_ip)

        if [ -z "$GW" ]; then
            FAIL_REASON="no_route"
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            CURRENT_STATUS="unhealthy"
            log "No default route | failures=$CONSECUTIVE_FAILURES/$MAX_FAILURES"
        else
            if check_connectivity "$GW"; then
                CONSECUTIVE_FAILURES=0
                CURRENT_STATUS="healthy"
            else
                FAIL_REASON="gw_unreachable"
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
                CURRENT_STATUS="unhealthy"
                log "Gateway unreachable | failures=$CONSECUTIVE_FAILURES/$MAX_FAILURES"
            fi
        fi

        if [ "$CURRENT_STATUS" = "unhealthy" ] && [ "$CONSECUTIVE_FAILURES" -ge "$MAX_FAILURES" ]; then
            execute_recovery
        fi

        sleep "$DELAY"
    done
}

daemon_loop