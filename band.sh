#!/bin/sh

# LTE Band Manager — MEIG SLM770A
# Usage: band.sh [device]  (default: /dev/ttyUSB2)
# Requires: sms_tool

DEV="${1:-/dev/ttyUSB2}"

# --- AT command via sms_tool ---
at() {
    local cmd="$1"
    sms_tool -d "$DEV" at "$cmd"
}

# --- Build HEX band mask ---
# LTE band bit values (hex positions per AT^SYSCFGEX manual)
mask() {
    local sum=0
    for b in $1; do
        case $b in
            1)  sum=$((sum + 1));;
            3)  sum=$((sum + 4));;
            5)  sum=$((sum + 16));;
            7)  sum=$((sum + 64));;
            8)  sum=$((sum + 128));;
            20) sum=$((sum + 524288));;
            28) sum=$((sum + 134217728));;
            *)  echo "[!] Unknown band: $b" >&2;;
        esac
    done
    printf "%X" "$sum"
}

# --- Decode lteband hex mask to band list ---
decode_bands() {
    local hex="$1" dec b bit
    # Convert hex to decimal (BusyBox-compatible)
    dec=$(printf "%d" "0x${hex}" 2>/dev/null) || { echo "  [!] Cannot parse: $hex"; return; }

    echo "  Active LTE bands:"
    for b in 1 3 5 7 8 20 28; do
        case $b in
            1)  bit=1;;
            3)  bit=4;;
            5)  bit=16;;
            7)  bit=64;;
            8)  bit=128;;
            20) bit=524288;;
            28) bit=134217728;;
        esac
        if [ $(( dec & bit )) -ne 0 ]; then
            case $b in
                1)  echo "    B1  — 2100 MHz";;
                3)  echo "    B3  — 1800 MHz";;
                5)  echo "    B5  —  850 MHz";;
                7)  echo "    B7  — 2600 MHz";;
                8)  echo "    B8  —  900 MHz";;
                20) echo "    B20 —  800 MHz";;
                28) echo "    B28 —  700 MHz";;
            esac
        fi
    done
}

# --- Show current band config ---
show_current() {
    local raw acqorder lteband

    echo "--- Configured bands (AT^SYSCFGEX?) ---"
    raw=$(at "AT^SYSCFGEX?")
    echo "$raw"

    # Parse lteband field (5th field after ^SYSCFGEX:)
    lteband=$(echo "$raw" | grep "SYSCFGEX:" \
        | sed 's/.*SYSCFGEX: *"\([^"]*\)",\([^,]*\),\([^,]*\),\([^,]*\),\([^,]*\).*/\5/')

    if [ -n "$lteband" ]; then
        decode_bands "$lteband"
    fi

    echo ""
    echo "--- Active connection (AT^SYSINFOEX) ---"
    at "AT^SYSINFOEX"
}

# --- Network info ---
network_info() {
    local cops csq cereg mnc act act_s rssi dbm stat reg_s

    cops=$(at "AT+COPS?")
    csq=$(at  "AT+CSQ")
    cereg=$(at "AT+CEREG?")

    mnc=$(echo "$cops"  | grep -oE '"[^"]*"' | sed -n '2p' | tr -d '"')
    act=$(echo "$cops"  | grep -oE ',[0-9]+$' | tr -d ',')
    case $act in
        0) act_s="GSM (2G)";;
        2) act_s="UMTS (3G)";;
        7) act_s="LTE (4G)";;
        *) act_s="Unknown ($act)";;
    esac

    rssi=$(echo "$csq" | grep -oE '[0-9]+' | head -1)
    [ -n "$rssi" ] && dbm=$(( -113 + rssi * 2 )) || dbm="n/a"

    stat=$(echo "$cereg" | grep -oE ',[0-9]+' | tail -1 | tr -d ',')
    case $stat in
        1) reg_s="Registered (home)";;
        5) reg_s="Roaming";;
        6) reg_s="SMS only";;
        *) reg_s="Not registered ($stat)";;
    esac

    echo "  Operator : ${mnc:-unknown}"
    echo "  Network  : $act_s"
    echo "  Signal   : $dbm dBm  (raw CSQ=$rssi)"
    echo "  Status   : $reg_s"
}

# --- Apply bands + restart ---
apply() {
    local bands="$1" h resp

    h=$(mask "$bands")
    echo ">> Bands: $bands"
    echo ">> Hex mask: $h"
    echo ""

    # AT^SYSCFGEX="03" = LTE only
    # 40000000        = no change for 2G/3G bands
    # 3               = no change roaming
    # 2               = CS+PS domain
    # $h              = LTE band mask (hex)
    # 0               = LTE bands 65-128 disabled
    # 1               = save after power-off
    resp=$(at "AT^SYSCFGEX=\"03\",40000000,3,2,$h,0,,,1")
    echo "$resp"

    if echo "$resp" | grep -q "ERROR"; then
        echo "[!] Failed to apply bands"
        return 1
    fi

    echo ""
    echo ">> Restarting modem (CFUN=0 → CFUN=1)..."
    at "AT+CFUN=0" > /dev/null
    sleep 3
    at "AT+CFUN=1" > /dev/null
    sleep 5

    echo ">> Restarting network interface..."
    ifup wwan 2>/dev/null
    sleep 3

    echo ""
    echo ">> Verifying..."
    show_current
}

# --- All bands (auto mode) ---
apply_all() {
    echo ">> Restoring all bands (auto mode)..."
    resp=$(at "AT^SYSCFGEX=\"00\",all,0,2,all,all,,,1")
    echo "$resp"

    if echo "$resp" | grep -q "ERROR"; then
        echo "[!] Failed"
        return 1
    fi

    at "AT+CFUN=0" > /dev/null && sleep 3
    at "AT+CFUN=1" > /dev/null && sleep 5
    ifup wwan 2>/dev/null && sleep 3
    show_current
}

# --- Debug: raw AT command ---
debug_at() {
    printf "Enter AT command: "
    read -r cmd
    echo "--- response ---"
    at "$cmd"
    echo "----------------"
}

# --- Main menu ---
while true; do
    echo "
=== MEIG SLM770A Band Manager === (dev: $DEV)

  1) Show current bands
  2) Network info
  3) Vodafone DE   B1+B3+B7+B8+B20+B28
  4) Low bands     B20+B28  — best coverage
  5) High bands    B3+B7    — best speed
  6) Custom bands
  7) All bands     auto mode (reset)
  d) Debug raw AT command
  q) Quit
"
    printf "> "
    read -r o
    echo ""
    case $o in
        1) show_current ;;
        2) network_info ;;
        3) apply "1 3 7 8 20 28" ;;
        4) apply "20 28" ;;
        5) apply "3 7" ;;
        6) printf "Enter bands (e.g. 3 7 20 28): "; read -r b; apply "$b" ;;
        7) apply_all ;;
        d) debug_at ;;
        q) exit 0 ;;
        *) echo "[!] Invalid choice" ;;
    esac
    echo "--------------------------------"
done
