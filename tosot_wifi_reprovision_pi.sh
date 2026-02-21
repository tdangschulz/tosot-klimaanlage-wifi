#!/usr/bin/env bash

TARGET_SSID="${TARGET_SSID:-meinRouter}"
TARGET_PSW="${TARGET_PSW:-}"

# Gree/Tosot AP SSID -> AP password
declare -A GREE_AP_PSW
GREE_AP_PSW["c6982a76"]="12345678"
GREE_AP_PSW["c699e6bf"]="12345678"
GREE_AP_PSW["c699e72b"]="12345678"

# Optional labels
declare -A GREE_AP_LABEL
GREE_AP_LABEL["c699e72b"]="Buero"
GREE_AP_LABEL["c6982a76"]="Hobbyzimmer"
GREE_AP_LABEL["c699e6bf"]="Schlafzimmer"

CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
AP_PORT=7000
AP_IP_CANDIDATES=(${AP_IP_CANDIDATES:-192.168.1.1 192.168.0.1})
INITIAL_SEND_WAIT="${INITIAL_SEND_WAIT:-5}"
SEND_RETRIES="${SEND_RETRIES:-12}"
SEND_INTERVAL="${SEND_INTERVAL:-2}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"
VERIFY_SCAN_INTERVAL="${VERIFY_SCAN_INTERVAL:-5}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-60}"
WLAN_IFACE="${WLAN_IFACE:-}"

trap 'echo "Stopped."; exit 0' INT TERM

usage() {
    cat <<'EOF'
Usage:
  ./tosot_wifi_reprovision_pi.sh [options]

Description:
  Raspberry Pi variant (without nmcli). Uses wpa_cli + iw to connect to
  configured Gree/Tosot APs and sends WLAN provisioning via UDP.

Options:
  -h, --help                      Show this help and exit
  --iface IFACE                   WLAN interface (auto-detect if omitted)
  --target-ssid SSID              Target router SSID
  --target-psw PASSWORD           Target router password
  --check-interval SEC            Main scan loop interval (default: 60)
  --connect-timeout SEC           Max wait for AP connection (default: 60)
  --initial-send-wait SEC         Wait before first UDP send (default: 5)
  --send-retries N                UDP send attempts (default: 12)
  --send-interval SEC             Pause between UDP sends (default: 2)
  --verify-timeout SEC            Max verification time (default: 120)
  --verify-scan-interval SEC      Verification scan interval (default: 5)
  --ap-ip-candidates "IP1 IP2"    AP IP fallback list

Environment variables:
  TARGET_SSID TARGET_PSW CHECK_INTERVAL CONNECT_TIMEOUT INITIAL_SEND_WAIT
  SEND_RETRIES SEND_INTERVAL VERIFY_TIMEOUT VERIFY_SCAN_INTERVAL
  AP_IP_CANDIDATES WLAN_IFACE

Important:
  Run as root on Raspberry Pi:
    sudo ./tosot_wifi_reprovision_pi.sh
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --iface) WLAN_IFACE="$2"; shift 2 ;;
            --target-ssid) TARGET_SSID="$2"; shift 2 ;;
            --target-psw) TARGET_PSW="$2"; shift 2 ;;
            --check-interval) CHECK_INTERVAL="$2"; shift 2 ;;
            --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
            --initial-send-wait) INITIAL_SEND_WAIT="$2"; shift 2 ;;
            --send-retries) SEND_RETRIES="$2"; shift 2 ;;
            --send-interval) SEND_INTERVAL="$2"; shift 2 ;;
            --verify-timeout) VERIFY_TIMEOUT="$2"; shift 2 ;;
            --verify-scan-interval) VERIFY_SCAN_INTERVAL="$2"; shift 2 ;;
            --ap-ip-candidates) AP_IP_CANDIDATES=($2); shift 2 ;;
            *)
                echo "Unknown option: $1"
                echo
                usage
                exit 1
                ;;
        esac
    done
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd"
        exit 1
    fi
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

get_wlan_interface() {
    if [ -n "${WLAN_IFACE:-}" ]; then
        printf '%s\n' "$WLAN_IFACE"
        return 0
    fi

    WLAN_IFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
    if [ -n "${WLAN_IFACE:-}" ]; then
        printf '%s\n' "$WLAN_IFACE"
        return 0
    fi

    WLAN_IFACE=$(ip -o link show | awk -F': ' '/wlan|wlp|wlx/ {print $2; exit}')
    if [ -n "${WLAN_IFACE:-}" ]; then
        printf '%s\n' "$WLAN_IFACE"
        return 0
    fi

    return 1
}

setup_wlan_interface() {
    local iface="$1"
    ip link set "$iface" up >/dev/null 2>&1 || true
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >/dev/null 2>&1 || true
    fi
}

wpa() {
    wpa_cli -i "$WLAN_IFACE" "$@"
}

ensure_wpa_ready() {
    if ! wpa ping 2>/dev/null | grep -q '^PONG'; then
        echo "wpa_cli cannot reach wpa_supplicant on interface '$WLAN_IFACE'."
        echo "Check service: sudo systemctl status wpa_supplicant"
        return 1
    fi
    return 0
}

scan_visible_aps() {
    local raw
    raw=$(iw dev "$WLAN_IFACE" scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p')
    if [ -z "${raw:-}" ]; then
        wpa scan >/dev/null 2>&1 || true
        sleep 2
        raw=$(wpa scan_results 2>/dev/null | awk 'NR>2 {sub(/^[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t/, ""); if (length($0)) print}')
    fi

    echo "$raw" | tr -d '\r' | sed 's/[[:space:]]*$//' | grep -v '^$' | awk '!seen[tolower($0)]++'
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
    local net_id psk_value

    net_id=$(wpa list_networks 2>/dev/null | awk -F'\t' -v s="$ssid" 'NR>1 && $2==s {print $1; exit}')
    if [ -z "${net_id:-}" ]; then
        net_id=$(wpa add_network 2>/dev/null | tail -n 1)
    fi
    if ! [[ "$net_id" =~ ^[0-9]+$ ]]; then
        echo "Failed to create/find network profile for SSID '$ssid'."
        return 1
    fi

    if command -v wpa_passphrase >/dev/null 2>&1; then
        psk_value=$(wpa_passphrase "$ssid" "$ap_password" | awk -F= '/^[[:space:]]*psk=[0-9a-f]+$/ {print $2; exit}')
    fi
    if [ -z "${psk_value:-}" ]; then
        local esc_psw
        esc_psw=${ap_password//\\/\\\\}
        esc_psw=${esc_psw//\"/\\\"}
        psk_value="\"$esc_psw\""
    fi

    wpa set_network "$net_id" ssid "\"$ssid\"" >/dev/null || return 1
    wpa set_network "$net_id" psk "$psk_value" >/dev/null || return 1
    wpa set_network "$net_id" key_mgmt WPA-PSK >/dev/null || return 1
    wpa select_network "$net_id" >/dev/null || return 1
    wpa enable_network "$net_id" >/dev/null || return 1
    wpa reassociate >/dev/null || true

    return 0
}

check_connection_status() {
    local ssid="$1"
    local timeout="$2"
    local i state current_ssid ip

    for i in $(seq 1 "$timeout"); do
        state=$(wpa status 2>/dev/null | awk -F= '/^wpa_state=/{print $2; exit}')
        current_ssid=$(wpa status 2>/dev/null | awk -F= '/^ssid=/{print $2; exit}')
        ip=$(ip -4 addr show "$WLAN_IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
        ip=${ip:-no-ip}

        echo "[$i/$timeout] state=$state ssid=$current_ssid ip=$ip"

        if [ "$state" = "COMPLETED" ] && [ "$current_ssid" = "$ssid" ]; then
            if [ "$ip" = "no-ip" ] && command -v dhclient >/dev/null 2>&1; then
                dhclient -1 "$WLAN_IFACE" >/dev/null 2>&1 || true
                ip=$(ip -4 addr show "$WLAN_IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
                ip=${ip:-no-ip}
            fi

            if [ "$ip" != "no-ip" ]; then
                echo "Connected to $ssid with IP $ip"
                return 0
            fi
        fi
        sleep 1
    done

    return 1
}

detect_ap_ip() {
    local candidate route_ip
    route_ip=$(ip route show dev "$WLAN_IFACE" 2>/dev/null | awk '/^default / {print $3; exit}')
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
    printf '%s\n' "${AP_IP_CANDIDATES[0]}"
}

send_configuration() {
    local wifi_ssid="$1"
    local wifi_psw="$2"
    local ap_ip="$3"
    local esc_ssid esc_psw json i rc=0

    esc_ssid=${wifi_ssid//\\/\\\\}; esc_ssid=${esc_ssid//\"/\\\"}
    esc_psw=${wifi_psw//\\/\\\\}; esc_psw=${esc_psw//\"/\\\"}
    esc_ssid=${esc_ssid//$'\r'/}; esc_ssid=${esc_ssid//$'\n'/}
    esc_psw=${esc_psw//$'\r'/}; esc_psw=${esc_psw//$'\n'/}
    json="{\"psw\":\"$esc_psw\",\"ssid\":\"$esc_ssid\",\"t\":\"wlan\"}"

    echo "Provisioning target AP: $ap_ip:$AP_PORT"
    sleep "$INITIAL_SEND_WAIT"

    for i in $(seq 1 "$SEND_RETRIES"); do
        echo "UDP send attempt $i/$SEND_RETRIES"
        if ! printf '%s' "$json" | nc -u -w1 "$ap_ip" "$AP_PORT"; then
            rc=1
        fi
        sleep "$SEND_INTERVAL"
    done

    [ "$rc" -eq 0 ]
}

verify_provisioning_success() {
    local ap_ssid="$1"
    local elapsed=0
    local stable_missing=0

    while [ "$elapsed" -lt "$VERIFY_TIMEOUT" ]; do
        if is_ap_visible "$ap_ssid"; then
            stable_missing=0
            echo "AP '$ap_ssid' still visible (${elapsed}s/${VERIFY_TIMEOUT}s)"
        else
            stable_missing=$((stable_missing + 1))
            echo "AP '$ap_ssid' not visible (${elapsed}s/${VERIFY_TIMEOUT}s), streak=$stable_missing"
            if [ "$stable_missing" -ge 2 ]; then
                echo "Provisioning likely successful."
                return 0
            fi
        fi
        sleep "$VERIFY_SCAN_INTERVAL"
        elapsed=$((elapsed + VERIFY_SCAN_INTERVAL))
    done

    echo "Verification timeout for '$ap_ssid'."
    return 1
}

parse_args "$@"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./tosot_wifi_reprovision_pi.sh"
    exit 1
fi

if [ -z "${TARGET_PSW:-}" ]; then
    echo "TARGET_PSW is empty. Set it via --target-psw or env var TARGET_PSW."
    exit 1
fi

require_command iw
require_command wpa_cli
require_command ip
require_command nc
require_command ping

WLAN_IFACE=$(get_wlan_interface)
if [ -z "${WLAN_IFACE:-}" ]; then
    echo "No WLAN interface found."
    exit 1
fi

setup_wlan_interface "$WLAN_IFACE"
if ! ensure_wpa_ready; then
    exit 1
fi

echo "Starting Tosot/Gree reprovision monitor (Raspberry Pi mode)"
echo "WLAN interface: $WLAN_IFACE"
echo "Target WiFi: $TARGET_SSID"
echo "Scan interval: ${CHECK_INTERVAL}s"
echo "--------------------------------------------------"

while true; do
    visible_aps=$(scan_visible_aps)
    current_connection=$(wpa status 2>/dev/null | awk -F= '/^ssid=/{print $2; exit}')
    current_connection=${current_connection:-none}

    echo "$(date '+%Y-%m-%d %H:%M:%S') current=$current_connection"
    echo "Visible APs:"
    echo "$visible_aps"

    found_ap=false
    for ap_ssid in "${!GREE_AP_PSW[@]}"; do
        ap_name=$(ap_display_name "$ap_ssid")
        if echo "$visible_aps" | grep -iFx "$ap_ssid" >/dev/null; then
            found_ap=true
            echo "$ap_name is visible. Processing..."

            if [ "$current_connection" = "$ap_ssid" ]; then
                ap_ip=$(detect_ap_ip)
                if send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip"; then
                    verify_provisioning_success "$ap_ssid" || true
                fi
                continue
            fi

            if connect_to_ap "$ap_ssid" "${GREE_AP_PSW[$ap_ssid]}"; then
                if check_connection_status "$ap_ssid" "$CONNECT_TIMEOUT"; then
                    ap_ip=$(detect_ap_ip)
                    if send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip"; then
                        verify_provisioning_success "$ap_ssid" || true
                    fi
                else
                    echo "Connect timeout for $ap_name"
                fi
            else
                echo "Failed to connect to $ap_name"
            fi
        else
            echo "$ap_name not visible."
        fi
    done

    if [ "$found_ap" = false ]; then
        echo "No configured AP visible."
    fi
    echo "Sleeping ${CHECK_INTERVAL}s..."
    sleep "$CHECK_INTERVAL"
done
