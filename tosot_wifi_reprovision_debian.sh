#!/bin/bash
# Debian variant — uses iw/wpa_supplicant/dhcpcd directly. No nmcli/wpa_cli needed.
# Requires root. Tools: iw, ip, wpa_supplicant, wpa_passphrase, dhcpcd, nc, ping.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

load_env_file() {
    local line key value
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}
        value=${line#*=}
        key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        if [ "${value#\'}" != "$value" ] && [ "${value%\'}" != "$value" ]; then
            value=${value#\'}; value=${value%\'}
        elif [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
            value=${value#\"}; value=${value%\"}
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$ENV_FILE"
}

has_usable_ipv4() {
    local iface="$1" ip
    ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    case "${ip:-}" in ''|169.254.*) return 1 ;; esac
    printf '%s\n' "$ip"
    return 0
}

load_env_file

TARGET_SSID="${TARGET_SSID:-}"
TARGET_PSW="${TARGET_PSW:-}"

declare -A GREE_AP_PSW
GREE_AP_PSW["c6982a76"]="${AP_PSW_C6982A76:-12345678}"
GREE_AP_PSW["c699e6bf"]="${AP_PSW_C699E6BF:-12345678}"
GREE_AP_PSW["c699e72b"]="${AP_PSW_C699E72B:-12345678}"

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
RECONNECT_ENABLED="${RECONNECT_ENABLED:-1}"
RECONNECT_SSID="${RECONNECT_SSID:-}"
HA_WEBHOOK_URL="${HA_WEBHOOK_URL:-}"

_TEMP_WPA_CONF=""

trap '_cleanup; echo "Stopped."; exit 0' INT TERM

_cleanup() {
    _kill_temp_wpa
    [ -n "$_TEMP_WPA_CONF" ] && rm -f "$_TEMP_WPA_CONF" && _TEMP_WPA_CONF=""
}

usage() {
    cat <<'EOF'
Usage:
  ./tosot_wifi_reprovision_debian.sh [options]

Description:
  Debian variant using iw + wpa_supplicant + dhcpcd directly (no nmcli/wpa_cli).
  Must be run as root.

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
  --ap-ip-candidates "IP1 IP2"    AP IP fallback list
  --reconnect-ssid SSID           WiFi SSID to reconnect to after provisioning
  --no-reconnect                  Disable reconnect behavior
  --ha-webhook-url URL            HA webhook URL to trigger after provisioning
  --no-ha-webhook                 Disable HA webhook trigger

Environment variables:
  ENV_FILE, TARGET_SSID, TARGET_PSW
  AP_PSW_C6982A76, AP_PSW_C699E6BF, AP_PSW_C699E72B
  CHECK_INTERVAL, INITIAL_SEND_WAIT, SEND_RETRIES, SEND_INTERVAL
  VERIFY_TIMEOUT, VERIFY_SCAN_INTERVAL, AP_IP_CANDIDATES
  RECONNECT_ENABLED, RECONNECT_SSID, HA_WEBHOOK_URL
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --target-ssid)          TARGET_SSID="$2";          shift 2 ;;
            --target-psw)           TARGET_PSW="$2";           shift 2 ;;
            --check-interval)       CHECK_INTERVAL="$2";       shift 2 ;;
            --initial-send-wait)    INITIAL_SEND_WAIT="$2";    shift 2 ;;
            --send-retries)         SEND_RETRIES="$2";         shift 2 ;;
            --send-interval)        SEND_INTERVAL="$2";        shift 2 ;;
            --verify-timeout)       VERIFY_TIMEOUT="$2";       shift 2 ;;
            --verify-scan-interval) VERIFY_SCAN_INTERVAL="$2"; shift 2 ;;
            --ap-ip-candidates)     AP_IP_CANDIDATES=($2);     shift 2 ;;
            --reconnect-ssid)       RECONNECT_SSID="$2";       shift 2 ;;
            --no-reconnect)         RECONNECT_ENABLED=0;       shift 1 ;;
            --ha-webhook-url)       HA_WEBHOOK_URL="$2";       shift 2 ;;
            --no-ha-webhook)        HA_WEBHOOK_URL="";         shift 1 ;;
            *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
        esac
    done
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    echo "Required command not found: $cmd"
    exit 1
}

ap_display_name() {
    local ap_ssid="$1" label="${GREE_AP_LABEL[$1]}"
    [ -n "${label:-}" ] && printf '%s (%s)' "$ap_ssid" "$label" || printf '%s' "$ap_ssid"
}

is_gree_ap_ssid() { [ -n "${GREE_AP_PSW[$1]+x}" ]; }

get_wlan_interface() {
    local wlan_iface=""
    echo "Searching for WLAN interface..." >&2

    wlan_iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
    if [ -n "${wlan_iface:-}" ]; then
        echo "WLAN Interface (iw): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"; return 0
    fi

    wlan_iface=$(ip link show 2>/dev/null | grep -o 'wlan[0-9]*\|wlx[a-f0-9]\+\|wlp[a-z0-9]\+' | head -1)
    if [ -n "${wlan_iface:-}" ]; then
        echo "WLAN Interface (ip): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"; return 0
    fi

    echo "No WLAN interface found!" >&2; return 1
}

setup_wlan_interface() {
    local iface="$1"
    echo "Configuring WLAN interface: $iface"
    ip link set "$iface" up 2>/dev/null && echo "$iface UP" || echo "$iface up failed"
    iw dev "$iface" set power_save off >/dev/null 2>&1 && echo "WiFi power_save OFF" || true
}

get_current_connection() {
    iw dev "$WLAN_IFACE" link 2>/dev/null | awk '/SSID:/{$1=""; sub(/^ /, ""); print; exit}'
}

detect_ap_ip() {
    local iface="$1" candidate route_ip
    route_ip=$(ip route show dev "$iface" 2>/dev/null | awk '/^default / {print $3; exit}')
    if [ -n "${route_ip:-}" ]; then printf '%s\n' "$route_ip"; return 0; fi
    for candidate in "${AP_IP_CANDIDATES[@]}"; do
        ping -c 1 -W 1 "$candidate" >/dev/null 2>&1 && printf '%s\n' "$candidate" && return 0
    done
    printf '%s\n' "${AP_IP_CANDIDATES[0]}"
}

scan_visible_aps() {
    echo ">>> Scanning WiFi networks..."
    # iw scan is blocking and works as root even when wpa_supplicant is active
    iw dev "$WLAN_IFACE" scan 2>/dev/null \
      | awk '/^\tSSID: ./{line=$0; sub(/^\tSSID: /, "", line); print line}' \
      | grep -v '^\\x00' \
      | awk '!seen[tolower($0)]++'
}

is_ap_visible() {
    scan_visible_aps | grep -iFx "$1" >/dev/null
}

_kill_temp_wpa() {
    if [ -n "$_TEMP_WPA_CONF" ]; then
        pkill -f "wpa_supplicant.*$_TEMP_WPA_CONF" 2>/dev/null || true
    fi
    # Also kill any dhcpcd we started on the interface
    pkill -f "dhcpcd.*$WLAN_IFACE" 2>/dev/null || true
    sleep 1
}

connect_to_ap() {
    local ssid="$1" psw="$2"
    echo ">>> Connecting to '$ssid' on $WLAN_IFACE..."

    # Tear down current connection
    _kill_temp_wpa
    pkill -f "wpa_supplicant.*-i $WLAN_IFACE" 2>/dev/null || true
    sleep 2
    ip link set "$WLAN_IFACE" up 2>/dev/null || true
    sleep 1

    # Build temp wpa_supplicant config
    _TEMP_WPA_CONF=$(mktemp /tmp/wpa_tosot_XXXXXX.conf)
    wpa_passphrase "$ssid" "$psw" > "$_TEMP_WPA_CONF"

    # Start wpa_supplicant (try nl80211 first, fall back to wext)
    wpa_supplicant -B -i "$WLAN_IFACE" -D nl80211 -c "$_TEMP_WPA_CONF" >/dev/null 2>&1 || \
    wpa_supplicant -B -i "$WLAN_IFACE" -D wext    -c "$_TEMP_WPA_CONF" >/dev/null 2>&1

    # Request IP
    dhcpcd -1 -t 20 "$WLAN_IFACE" >/dev/null 2>&1 || true
    return 0
}

check_connection_status() {
    local ssid="$1" iface="$2" timeout=60
    echo ">>> Checking connection (timeout ${timeout}s)..."

    for i in $(seq 1 "$timeout"); do
        local connected_ssid ip
        connected_ssid=$(iw dev "$iface" link 2>/dev/null | awk '/SSID:/{$1=""; sub(/^ /, ""); print; exit}')
        ip=$(has_usable_ipv4 "$iface" || true); ip=${ip:-no-ip}
        echo ">>> [$i/$timeout] ssid='$connected_ssid' ip=$ip"
        if [ "$connected_ssid" = "$ssid" ] && [ "$ip" != "no-ip" ]; then
            echo ">>> Connected to $ssid (IP: $ip)"; return 0
        fi
        sleep 1
    done

    echo ">>> Not connected after ${timeout}s"; return 1
}

reconnect_to_fallback_wifi() {
    local fallback_ssid="$1" iface="$2"
    [ "${RECONNECT_ENABLED}" = "0" ] && return 0
    [ -z "${fallback_ssid:-}" ] && echo ">>> Reconnect skipped: no fallback SSID" && return 1

    local current_ssid
    current_ssid=$(get_current_connection)
    if [ "$current_ssid" = "$fallback_ssid" ]; then
        echo ">>> Already connected to: $fallback_ssid"
        _kill_temp_wpa
        [ -n "$_TEMP_WPA_CONF" ] && rm -f "$_TEMP_WPA_CONF" && _TEMP_WPA_CONF=""
        return 0
    fi

    echo ">>> Reconnecting to fallback WiFi: $fallback_ssid"

    # Kill temp wpa_supplicant and clean up
    _kill_temp_wpa
    [ -n "$_TEMP_WPA_CONF" ] && rm -f "$_TEMP_WPA_CONF" && _TEMP_WPA_CONF=""
    pkill -f "wpa_supplicant.*-i $iface" 2>/dev/null || true
    sleep 2

    # Try ifup first (preserves original ifupdown config with saved credentials)
    ip link set "$iface" down 2>/dev/null || true
    sleep 1
    if ifup "$iface" >/dev/null 2>&1; then
        echo ">>> Reconnected via ifup"
        return 0
    fi

    # Fallback: start fresh wpa_supplicant with TARGET credentials
    echo ">>> ifup failed, starting wpa_supplicant directly..."
    ip link set "$iface" up 2>/dev/null || true
    sleep 1
    local tmpconf
    tmpconf=$(mktemp /tmp/wpa_home_XXXXXX.conf)
    wpa_passphrase "$fallback_ssid" "$TARGET_PSW" > "$tmpconf"
    wpa_supplicant -B -i "$iface" -D nl80211 -c "$tmpconf" >/dev/null 2>&1 || \
    wpa_supplicant -B -i "$iface" -D wext    -c "$tmpconf" >/dev/null 2>&1
    dhcpcd -1 -t 20 "$iface" >/dev/null 2>&1 || true
    rm -f "$tmpconf"
    return 0
}

send_configuration() {
    local wifi_ssid="$1" wifi_psw="$2" ap_ip="$3"
    set +H 2>/dev/null || true

    local esc_ssid esc_psw
    esc_ssid=${wifi_ssid//\\/\\\\}; esc_ssid=${esc_ssid//\"/\\\"}
    esc_psw=${wifi_psw//\\/\\\\};   esc_psw=${esc_psw//\"/\\\"}
    esc_ssid=${esc_ssid//$'\r'/};   esc_ssid=${esc_ssid//$'\n'/}
    esc_psw=${esc_psw//$'\r'/};     esc_psw=${esc_psw//$'\n'/}

    local json="{\"psw\":\"$esc_psw\",\"ssid\":\"$esc_ssid\",\"t\":\"wlan\"}"
    echo ">>> Provisioning $ap_ip:$AP_PORT — payload: $json"
    echo ">>> Waiting ${INITIAL_SEND_WAIT}s..."
    sleep "$INITIAL_SEND_WAIT"

    ping -c 1 -W 1 "$ap_ip" >/dev/null 2>&1 && echo ">>> AP reachable" || echo ">>> AP not pingable (sending anyway)"

    local i rc=0
    for i in $(seq 1 "$SEND_RETRIES"); do
        echo ">>> UDP send $i/$SEND_RETRIES"
        printf '%s' "$json" | nc -u -w1 "$ap_ip" "$AP_PORT" || rc=1
        sleep "$SEND_INTERVAL"
    done

    [ "$rc" -eq 0 ] && echo ">>> Payload sent" || echo ">>> Send had errors"
    return $rc
}

verify_provisioning_success() {
    local ap_ssid="$1" elapsed=0 stable_missing=0
    echo ">>> Verifying '$ap_ssid' (timeout ${VERIFY_TIMEOUT}s)..."

    while [ "$elapsed" -lt "$VERIFY_TIMEOUT" ]; do
        if is_ap_visible "$ap_ssid"; then
            echo ">>> AP still visible (${elapsed}s)"; stable_missing=0
        else
            stable_missing=$((stable_missing + 1))
            echo ">>> AP not visible (${elapsed}s), streak=$stable_missing"
            if [ "$stable_missing" -ge 2 ]; then
                echo ">>> Provisioning successful"; return 0
            fi
        fi
        sleep "$VERIFY_SCAN_INTERVAL"
        elapsed=$((elapsed + VERIFY_SCAN_INTERVAL))
    done

    echo ">>> Verification timeout"; return 1
}

trigger_ha_webhook() {
    local ap_ssid="$1" ap_name="$2"
    [ -z "${HA_WEBHOOK_URL:-}" ] && return 0

    local payload="{\"ssid\":\"${ap_ssid}\",\"ac\":\"${ap_name}\",\"ts\":\"$(date --iso-8601=seconds)\"}"
    curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "${HA_WEBHOOK_URL}" >/dev/null 2>&1 \
        && echo ">>> Webhook sent" || echo ">>> Webhook failed"
}

# === MAIN ===
parse_args "$@"
echo "Gree AP WiFi Configurator v2.3 (Debian/iw+wpa_supplicant)"

[ -z "${TARGET_PSW:-}" ]  && echo "TARGET_PSW is empty."  && exit 1
[ -z "${TARGET_SSID:-}" ] && echo "TARGET_SSID is empty." && exit 1

require_command iw
require_command ip
require_command nc
require_command wpa_supplicant
require_command wpa_passphrase
require_command dhcpcd

echo "Target WiFi: $TARGET_SSID | Check interval: ${CHECK_INTERVAL}s"
echo "----------------------------------------"

WLAN_IFACE=$(get_wlan_interface) || { echo "Abort: No WLAN interface found!"; exit 1; }
[ -z "${WLAN_IFACE:-}" ]          && echo "Abort: No WLAN interface found!" && exit 1

setup_wlan_interface "$WLAN_IFACE"
echo "Using WLAN: $WLAN_IFACE"

if [ -z "${RECONNECT_SSID:-}" ]; then
    initial_connection=$(get_current_connection)
    if [ -n "$initial_connection" ] && ! is_gree_ap_ssid "$initial_connection"; then
        RECONNECT_SSID="$initial_connection"
    else
        RECONNECT_SSID="$TARGET_SSID"
    fi
fi

[ "${RECONNECT_ENABLED}" = "1" ] \
    && echo "Fallback WiFi: $RECONNECT_SSID" \
    || echo "Fallback reconnect disabled"

echo "----------------------------------------"

while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Scanning for Gree AC APs..."

    visible_aps=$(scan_visible_aps)
    current_connection=$(get_current_connection)
    current_connection=${current_connection:-none}

    echo ">>> Current: $current_connection"
    echo ">>> Visible APs: $(echo "$visible_aps" | tr '\n' ' ')"

    found_ap=false

    for ap_ssid in "${!GREE_AP_PSW[@]}"; do
        ap_name=$(ap_display_name "$ap_ssid")
        if echo "$visible_aps" | grep -iFx "$ap_ssid" >/dev/null; then
            echo "----------------------------------------"
            echo "$ap_name VISIBLE → Processing..."
            found_ap=true
            _webhook_pending=false

            if [ "$current_connection" = "$ap_ssid" ]; then
                echo ">>> Already connected → Provisioning"
                ap_ip=$(detect_ap_ip "$WLAN_IFACE")
                send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip" || true
                verify_provisioning_success "$ap_ssid" && _webhook_pending=true || true
                reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
                [ "$_webhook_pending" = true ] && trigger_ha_webhook "$ap_ssid" "$ap_name" || true
                continue
            fi

            if connect_to_ap "$ap_ssid" "${GREE_AP_PSW[$ap_ssid]}"; then
                if check_connection_status "$ap_ssid" "$WLAN_IFACE"; then
                    echo ">>> Connected to $ap_name → Provisioning"
                    ap_ip=$(detect_ap_ip "$WLAN_IFACE")
                    send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip" || true
                    verify_provisioning_success "$ap_ssid" && _webhook_pending=true || true
                    reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
                    sleep 3
                else
                    echo ">>> Connection verification FAILED"
                    reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
                fi
            else
                echo ">>> Connection to $ap_name FAILED"
                reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
            fi

            [ "$_webhook_pending" = true ] && trigger_ha_webhook "$ap_ssid" "$ap_name" || true
        else
            echo ">>> $ap_name not visible"
        fi
    done

    [ "$found_ap" = false ] && echo ">>> No Gree APs visible → Waiting..."

    reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
    echo "----------------------------------------"
    echo "Sleeping ${CHECK_INTERVAL}s..."
    sleep "$CHECK_INTERVAL"
done
