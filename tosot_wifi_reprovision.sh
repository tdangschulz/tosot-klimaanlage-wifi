#!/bin/bash

ENV_FILE="${ENV_FILE:-.env}"

load_env_file() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        set +a
    fi
}

load_env_file

# ==== Einmalige Ziel-WLAN-Definition (für alle GREE-APs) ====
TARGET_SSID="${TARGET_SSID:-}"
TARGET_PSW="${TARGET_PSW:-}"


# Configuration: Gree AP SSID → AP Password
declare -A GREE_AP_PSW
GREE_AP_PSW["c6982a76"]="${AP_PSW_C6982A76:-12345678}"
GREE_AP_PSW["c699e6bf"]="${AP_PSW_C699E6BF:-12345678}"
GREE_AP_PSW["c699e72b"]="${AP_PSW_C699E72B:-12345678}"

# Optional labels: Gree AP SSID -> room name
declare -A GREE_AP_LABEL
GREE_AP_LABEL["c699e72b"]="Buero"
GREE_AP_LABEL["c6982a76"]="Hobbyzimmer"
GREE_AP_LABEL["c699e6bf"]="Schlafzimmer"

CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # seconds
AP_PORT=7000
AP_IP_CANDIDATES=(${AP_IP_CANDIDATES:-192.168.1.1 192.168.0.1})

# App-like sending behavior
INITIAL_SEND_WAIT="${INITIAL_SEND_WAIT:-5}"      # wait after AP connect before first UDP send
SEND_RETRIES="${SEND_RETRIES:-12}"               # send multiple times for flaky APs
SEND_INTERVAL="${SEND_INTERVAL:-2}"              # seconds between sends
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"          # max seconds to wait for AP to disappear
VERIFY_SCAN_INTERVAL="${VERIFY_SCAN_INTERVAL:-5}" # seconds between verification scans

trap 'echo "🛑 Stopped."; exit 0' INT TERM

usage() {
    cat <<'EOF'
Usage:
  ./tosot_wifi_reprovision.sh [options]

Description:
  Scans for configured Gree/Tosot AP SSIDs, connects, sends WLAN provisioning,
  and verifies success by checking AP visibility.
  If present, values are auto-loaded from .env (or ENV_FILE).

Options:
  -h, --help                      Show this help and exit
  --target-ssid SSID              Target router SSID
  --target-psw PASSWORD           Target router password
  --check-interval SEC            Main scan loop interval (default: 60)
  --initial-send-wait SEC         Wait before first UDP send (default: 5)
  --send-retries N                UDP send attempts per provisioning (default: 12)
  --send-interval SEC             Pause between UDP sends (default: 2)
  --verify-timeout SEC            Max verification time (default: 120)
  --verify-scan-interval SEC      Verification rescan interval (default: 5)
  --ap-ip-candidates "IP1 IP2"    AP IP fallback list (default: "192.168.1.1 192.168.0.1")

Environment variables:
  ENV_FILE
  TARGET_SSID
  TARGET_PSW
  AP_PSW_C6982A76
  AP_PSW_C699E6BF
  AP_PSW_C699E72B
  CHECK_INTERVAL
  INITIAL_SEND_WAIT
  SEND_RETRIES
  SEND_INTERVAL
  VERIFY_TIMEOUT
  VERIFY_SCAN_INTERVAL
  AP_IP_CANDIDATES

Examples:
  ./tosot_wifi_reprovision.sh --help
  ENV_FILE=.env.prod ./tosot_wifi_reprovision.sh
  ./tosot_wifi_reprovision.sh --check-interval 90 --send-retries 15
  TARGET_SSID=MeinWLAN TARGET_PSW='secret' ./tosot_wifi_reprovision.sh
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --target-ssid)
                TARGET_SSID="$2"
                shift 2
                ;;
            --target-psw)
                TARGET_PSW="$2"
                shift 2
                ;;
            --check-interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            --initial-send-wait)
                INITIAL_SEND_WAIT="$2"
                shift 2
                ;;
            --send-retries)
                SEND_RETRIES="$2"
                shift 2
                ;;
            --send-interval)
                SEND_INTERVAL="$2"
                shift 2
                ;;
            --verify-timeout)
                VERIFY_TIMEOUT="$2"
                shift 2
                ;;
            --verify-scan-interval)
                VERIFY_SCAN_INTERVAL="$2"
                shift 2
                ;;
            --ap-ip-candidates)
                AP_IP_CANDIDATES=($2)
                shift 2
                ;;
            *)
                echo "❌ Unknown option: $1"
                echo
                usage
                exit 1
                ;;
        esac
    done
}

ap_display_name() {
    local ap_ssid="$1"
    local label="${GREE_AP_LABEL[$ap_ssid]}"
    if [ -n "${label:-}" ]; then
        printf '%s (%s)' "$ap_ssid" "$label"
    else
        printf '%s' "$ap_ssid"
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required command not found: $cmd"
        exit 1
    fi
}

detect_ap_ip() {
    local iface="$1"
    local candidate route_ip

    # Prefer route if one exists while connected to the AP.
    route_ip=$(ip route show dev "$iface" 2>/dev/null | awk '/^default / {print $3; exit}')
    if [ -n "${route_ip:-}" ]; then
        printf '%s\n' "$route_ip"
        return 0
    fi

    for candidate in "${AP_IP_CANDIDATES[@]}"; do
        if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    # Fallback to first candidate even if not pingable.
    printf '%s\n' "${AP_IP_CANDIDATES[0]}"
}

# === AUTO WLAN INTERFACE DETECTION ===
get_wlan_interface() {
    local wlan_iface=""

    echo "🔍 Searching for WLAN interface..." >&2

    wlan_iface=$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
    if [ -n "${wlan_iface:-}" ]; then
        echo "✅ WLAN Interface (nmcli): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"
        return 0
    fi

    wlan_iface=$(ip link show 2>/dev/null | grep -o 'wlan[0-9]*\|wlx[a-f0-9]\+\|wlp[a-z0-9]\+' | head -1)
    if [ -n "${wlan_iface:-}" ]; then
        echo "✅ WLAN Interface (ip): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"
        return 0
    fi

    wlan_iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
    if [ -n "${wlan_iface:-}" ]; then
        echo "✅ WLAN Interface (iw): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"
        return 0
    fi

    echo "❌ KEIN WLAN INTERFACE gefunden!" >&2
    ip link show | grep -E '^[0-9]:|wlan|wlx|wlp' >&2 || true
    return 1
}

setup_wlan_interface() {
    local iface="$1"

    echo "🔧 Configuring WLAN interface: $iface"

    ip link set "$iface" up 2>/dev/null && echo "✅ $iface UP" || echo "⚠️  $iface up failed"
    nmcli radio wifi on 2>/dev/null && echo "✅ WiFi radio ON" || true
    nmcli dev set "$iface" managed yes 2>/dev/null && echo "✅ $iface managed by NMCLI" || true

    # Optional: power_save off (hilft oft)
    if command -v iw >/dev/null 2>&1; then
        iw dev "$iface" set power_save off >/dev/null 2>&1 && echo "✅ WiFi power_save OFF" || true
    fi
}

check_connection_status() {
    local ssid="$1"
    local iface="$2"
    local timeout=60

    echo ">>> 🔍 Checking connection status on $iface (timeout ${timeout}s)..."

    for i in $(seq 1 "$timeout"); do
        local devline ip
        devline=$(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | awk -F: -v ifc="$iface" '$1==ifc {print; exit}')
        ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
        ip=${ip:-no-ip}

        echo ">>> 📊 [$i/$timeout] Dev: $devline | IP: $ip"

        if [[ "$devline" == "$iface:connected:$ssid" ]] && [[ "$ip" != "no-ip" ]]; then
            echo "✅ VERBUNDEN mit $ssid (IP: $ip)"
            return 0
        fi

        sleep 1
    done

    echo "❌ NICHT VERBUNDEN nach ${timeout}s"
    return 1
}

scan_visible_aps() {
    echo ">>> 🔄 Scanning WiFi networks (all interfaces)..."

    nmcli dev wifi rescan >/dev/null 2>&1 || true
    sleep 5

    local raw_aps
    raw_aps=$(nmcli -t -f SSID dev wifi 2>/dev/null || true)

    echo "$raw_aps" \
      | tr -d '\r' \
      | sed 's/[[:space:]]*$//' \
      | grep -v '^$' \
      | awk '!seen[tolower($0)]++'
}

is_ap_visible() {
    local ap_ssid="$1"
    local visible_aps
    visible_aps=$(scan_visible_aps)
    echo "$visible_aps" | grep -iFx "$ap_ssid" >/dev/null
}

connect_to_ap() {
    local ssid="$1"
    local ap_password="$2"

    echo ">>> 🔗 Attempting connection to '$ssid' on $WLAN_IFACE..."

    nmcli -w 5 dev disconnect "$WLAN_IFACE" >/dev/null 2>&1 || true

    if nmcli -t -f NAME connection show 2>/dev/null | grep -Fx "$ssid" >/dev/null; then
        echo ">>> 📋 Using existing profile: $ssid"
        nmcli -w 30 con up id "$ssid" ifname "$WLAN_IFACE" >/dev/null 2>&1 && return 0
        nmcli -w 30 con up id "$ssid" >/dev/null 2>&1 && return 0
        return 1
    fi

    echo ">>> ➕ Creating temporary connection..."
    nmcli -w 30 dev wifi connect "$ssid" password "$ap_password" ifname "$WLAN_IFACE" >/dev/null 2>&1 && return 0
    nmcli -w 30 dev wifi connect "$ssid" password "$ap_password" >/dev/null 2>&1 && return 0
    return 1
}

# === AP PROVISIONING (App-like): wait + repeat send ===
send_configuration() {
    local wifi_ssid="$1"
    local wifi_psw="$2"
    local ap_ip="$3"

    # Disable history expansion (protect against '!' in interactive contexts)
    set +H 2>/dev/null || true

    # Minimal JSON escaping for backslash and double quote
    local esc_ssid esc_psw
    esc_ssid=${wifi_ssid//\\/\\\\}; esc_ssid=${esc_ssid//\"/\\\"}
    esc_psw=${wifi_psw//\\/\\\\};   esc_psw=${esc_psw//\"/\\\"}

    # Remove CR/LF just in case
    esc_ssid=${esc_ssid//$'\r'/}; esc_ssid=${esc_ssid//$'\n'/}
    esc_psw=${esc_psw//$'\r'/};   esc_psw=${esc_psw//$'\n'/}

    local json
    json="{\"psw\":\"$esc_psw\",\"ssid\":\"$esc_ssid\",\"t\":\"wlan\"}"

    echo ">>> 📤 App-like provisioning to $ap_ip:$AP_PORT"
    echo ">>> 📄 Payload: $json"

    echo ">>> ⏳ Waiting ${INITIAL_SEND_WAIT}s before sending (AP settle time)..."
    sleep "$INITIAL_SEND_WAIT"

    # Optional: check AP reachable (ping). If it fails, still try sending.
    if ping -c 1 -W 1 "$ap_ip" >/dev/null 2>&1; then
        echo ">>> ✅ AP reachable at $ap_ip"
    else
        echo ">>> ⚠️  AP not pingable (still sending UDP, since UDP has no handshake)"
    fi

    local i rc=0
    for i in $(seq 1 "$SEND_RETRIES"); do
        echo ">>> 📡 UDP send attempt $i/$SEND_RETRIES"
        if ! printf '%s' "$json" | nc -u -w1 "$ap_ip" "$AP_PORT"; then
            echo ">>> ❌ UDP send failed on attempt $i"
            rc=1
        fi
        sleep "$SEND_INTERVAL"
    done

    if [ "$rc" -eq 0 ]; then
        echo ">>> ✅ Provisioning payload sent (retries done)"
        return 0
    fi

    echo ">>> ❌ Provisioning send had errors"
    return 1
}

verify_provisioning_success() {
    local ap_ssid="$1"
    local elapsed=0
    local stable_missing=0

    echo ">>> 🔎 Verifying provisioning success for AP '$ap_ssid' (timeout ${VERIFY_TIMEOUT}s)..."

    while [ "$elapsed" -lt "$VERIFY_TIMEOUT" ]; do
        if is_ap_visible "$ap_ssid"; then
            echo ">>> 📡 AP '$ap_ssid' still visible (${elapsed}s/${VERIFY_TIMEOUT}s)"
            stable_missing=0
        else
            stable_missing=$((stable_missing + 1))
            echo ">>> ✅ AP '$ap_ssid' not visible (${elapsed}s/${VERIFY_TIMEOUT}s), streak=$stable_missing"
            if [ "$stable_missing" -ge 2 ]; then
                echo ">>> 🎉 Provisioning likely successful (AP mode exited)"
                return 0
            fi
        fi

        sleep "$VERIFY_SCAN_INTERVAL"
        elapsed=$((elapsed + VERIFY_SCAN_INTERVAL))
    done

    echo ">>> ⚠️  Verification timeout: AP '$ap_ssid' still appears periodically"
    return 1
}

# === MAIN INITIALIZATION ===
parse_args "$@"
echo "🚀 Gree AP WiFi Configurator v2.2 (App-like provisioning)"

if [ -z "${TARGET_PSW:-}" ]; then
    echo "❌ TARGET_PSW is empty. Set it via --target-psw or env var TARGET_PSW."
    exit 1
fi

if [ -z "${TARGET_SSID:-}" ]; then
    echo "❌ TARGET_SSID is empty. Set it via --target-ssid or env var TARGET_SSID."
    exit 1
fi

echo "📶 Target WiFi: $TARGET_SSID"
echo "⏱️  Check interval: ${CHECK_INTERVAL}s"
echo "----------------------------------------"

require_command nmcli
require_command ip
require_command nc

WLAN_IFACE=$(get_wlan_interface)
if [ $? -ne 0 ] || [ -z "${WLAN_IFACE:-}" ]; then
    echo "❌ Abbruch: Kein WLAN Interface gefunden!"
    exit 1
fi

setup_wlan_interface "$WLAN_IFACE"
echo "📶 Using WLAN: $WLAN_IFACE"
echo "----------------------------------------"

while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S'): 🔄 Scanning for Gree AC APs..."

    visible_aps=$(scan_visible_aps)
    current_connection=$(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | awk -F: -v ifc="$WLAN_IFACE" '$1==ifc {print $3; exit}')
    current_connection=${current_connection:-none}

    echo ">>> 📡 Current connection: $current_connection"
    echo ">>> 📋 Visible APs:"
    echo "$visible_aps"

    found_ap=false

    for ap_ssid in "${!GREE_AP_PSW[@]}"; do
        ap_name=$(ap_display_name "$ap_ssid")
        if echo "$visible_aps" | grep -iFx "$ap_ssid" >/dev/null; then
            echo "----------------------------------------"
            echo "🎯 $ap_name is VISIBLE → Processing..."
            found_ap=true

            if [[ "$current_connection" == "$ap_ssid" ]]; then
                echo ">>> ✅ Already connected to $ap_name → App-like provisioning"
                ap_ip=$(detect_ap_ip "$WLAN_IFACE")
                echo ">>> 🌐 Using AP IP: $ap_ip"
                if send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip"; then
                    verify_provisioning_success "$ap_ssid" || true
                fi
                continue
            fi

            if connect_to_ap "$ap_ssid" "${GREE_AP_PSW[$ap_ssid]}"; then
                echo ">>> 🔄 Connection attempt OK → Verifying..."

                if check_connection_status "$ap_ssid" "$WLAN_IFACE"; then
                    echo ">>> 🎉 FULLY CONNECTED to $ap_name → App-like provisioning"
                    ap_ip=$(detect_ap_ip "$WLAN_IFACE")
                    echo ">>> 🌐 Using AP IP: $ap_ip"
                    if send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip"; then
                        verify_provisioning_success "$ap_ssid" || true
                    fi
                    sleep 3
                else
                    echo ">>> ❌ Connection verification FAILED"
                fi
            else
                echo ">>> ❌ Connection to $ap_name FAILED"
            fi
        else
            echo ">>> 👻 $ap_name not visible"
        fi
    done

    if [ "$found_ap" = false ]; then
        echo ">>> 😴 No Gree APs visible → Waiting..."
    fi

    echo "----------------------------------------"
    echo "💤 Sleeping ${CHECK_INTERVAL}s until next scan..."
    sleep "$CHECK_INTERVAL"
done
