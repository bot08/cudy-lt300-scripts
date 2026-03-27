#!/bin/sh
LOCK="/tmp/auto_refill.lock"
[ -f "$LOCK" ] && exit 0
touch "$LOCK"
trap "rm -f $LOCK" EXIT

INTERFACE="usb0"
THRESHOLD=838860800
NUMBER=""
STATE_FILE="/tmp/last_refill_bytes"
DEV="/dev/ttyUSB2"
MSG="Refill"

send_sms() {
  local DEV="${1:-/dev/ttyUSB2}"
  local NUM="$2"
  local MSG="$3"

  [ ! -c "$DEV" ] && { logger "send_sms: device $DEV not found"; return 1; }
  [ -z "$NUM" ] && { logger "send_sms: number is empty"; return 1; }
  [ -z "$MSG" ] && { logger "send_sms: message is empty"; return 1; }

  if output=$(sms_tool -d "$DEV" send "$NUM" "$MSG" 2>&1); then
    logger "$output"
    return 0
  else
    logger "SMS send FAILED: $output"
    return 1
  fi
}

[ ! -f "/sys/class/net/$INTERFACE/statistics/rx_bytes" ] && exit 0
[ ! -c "$DEV" ] && exit 0

RX=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
TX=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
TOTAL=$((RX + TX))

if [ -f "$STATE_FILE" ]; then
    LAST_TOTAL=$(cat "$STATE_FILE")
else
    LAST_TOTAL=0
fi

[ "$TOTAL" -lt "$LAST_TOTAL" ] && LAST_TOTAL=0

DIFF=$((TOTAL - LAST_TOTAL))

DIFF_MB=$((DIFF / 1048576))
THRESHOLD_MB=$((THRESHOLD / 1048576))

if [ "$DIFF" -ge "$THRESHOLD" ]; then
    ( send_sms "$DEV" "$NUMBER" "$MSG" ) &
    SMS_PID=$!

    ( sleep 15; kill "$SMS_PID" 2>/dev/null ) &
    WATCHDOG_PID=$!

    wait "$SMS_PID" 2>/dev/null
    SMS_EXIT=$?
    kill "$WATCHDOG_PID" 2>/dev/null
    wait "$WATCHDOG_PID" 2>/dev/null

    if [ "$SMS_EXIT" -eq 0 ]; then
        echo "$TOTAL" > "$STATE_FILE"
        logger "800MB reached. Auto-SMS Refill sent."
    else
        logger "Auto-SMS Refill failed or timed out."
    fi
else
    logger "${DIFF_MB} MB / ${THRESHOLD_MB} MB"
fi