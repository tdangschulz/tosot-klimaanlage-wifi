#!/bin/bash
# Debian/wpa_supplicant variant — uses wpa_cli instead of nmcli.
# Requires: bash, wpa_cli, iw, ip, nc, ping. Run as root.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

load_env_file() {
    local line key value
    [ -f "$ENV_FILE" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case "$line" in
            ''|'#'*) continue ;;
        esac

        key=${line%%=*}
        value=${line#*=}
        key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        case "$key" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac

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
    local iface="$1"
    local ip
    ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    case "${ip:-}" in
        ''|169.254.*) return 1 ;;
    esac
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

_WPA_TEMP_NET_ID=""

trap 'echo "Stopped."; exit 0' INT TERM

usage() {
    cat <<'EOF'
Usage:
  ./tosot_wifi_reprovision_debian.sh [options]

Description:
  Debian variant using wpa_cli (wpa_supplicant) instead of nmcli.
  Must be run as root. Values are auto-loaded from .env (or ENV_FILE).

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
  --reconnect-ssid SSID           WiFi SSID to reconnect to when no AP is visible
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

is_gree_ap_ssid() {
    local ssid="$1"
    [ -n "${GREE_AP_PSW[$ssid]+x}" ]
}

get_wlan_interface() {
    local wlan_iface=""
    echo "Searching for WLAN interface..." >&2

    wlan_iface=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
    if [ -n "${wlan_iface:-}" ]; then
        echo "WLAN Interface (iw): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"
        return 0
    fi

    wlan_iface=$(ip link show 2>/dev/null | grep -o 'wlan[0-9]*\|wlx[a-f0-9]\+\|wlp[a-z0-9]\+' | head -1)
    if [ -n "${wlan_iface:-}" ]; then
        echo "WLAN Interface (ip): $wlan_iface" >&2
        printf '%s\n' "$wlan_iface"
        return 0
    fi

    echo "No WLAN interface found!" >&2
    return 1
}

setup_wlan_interface() {
    local iface="$1"
    echo "Configuring WLAN interface: $iface"
    ip link set "$iface" up 2>/dev/null && echo "$iface UP" || echo "$iface up failed"
    iw dev "$iface" set power_save off >/dev/null 2>&1 && echo "WiFi power_save OFF" || true
}

wpa() {
    wpa_cli -i "$WLAN_IFACE" "$@" 2>/dev/null
}

get_current_connection() {
    wpa status 2>/dev/null | awk -F= '/^ssid=/{print $2; exit}'
}

detect_ap_ip() {
    local iface="$1"
    local candidate route_ip

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

    printf '%s\n' "${AP_IP_CANDIDATES[0]}"
}

scan_visible_aps() {
    echo ">>> Scanning WiFi networks..."
    wpa scan >/dev/null 2>&1 || true
    sleep 5
    wpa scan_results 2>/dev/null \
      | tail -n +3 \
      | awk -F'\t' '{gsub(/[[:space:]]+$/, "", $5); if ($5 != "") print $5}' \
      | awk '!seen[tolower($0)]++'
}

is_ap_visible() {
    local ap_ssid="$1"
    scan_visible_aps | grep -iFx "$ap_ssid" >/dev/null
}

connect_to_ap() {
    local ssid="$1"
    local ap_password="$2"

    echo ">>> Connecting to '$ssid' on $WLAN_IFACE..."

    wpa disconnect >/dev/null 2>&1 || true
    sleep 1

    # Remove previous temp network if still around
    if [ -n "$_WPA_TEMP_NET_ID" ]; then
        wpa remove_network "$_WPA_TEMP_NET_ID" >/dev/null 2>&1 || true
        _WPA_TEMP_NET_ID=""
    fi

    local net_id
    net_id=$(wpa add_network 2>/dev/null | tail -1)
    if ! [[ "$net_id" =~ ^[0-9]+$ ]]; then
        echo ">>> wpa_cli add_network failed (got: $net_id)"
        return 1
    fi

    _WPA_TEMP_NET_ID="$net_id"
    wpa set_network "$net_id" ssid "\"$ssid\""         >/dev/null 2>&1
    wpa set_network "$net_id" psk  "\"$ap_password\""  >/dev/null 2>&1
    wpa set_network "$net_id" key_mgmt WPA-PSK         >/dev/null 2>&1
    wpa set_network "$net_id" scan_ssid 1              >/dev/null 2>&1
    wpa enable_network "$net_id"                       >/dev/null 2>&1
    wpa select_network "$net_id"                       >/dev/null 2>&1
    return 0
}

check_connection_status() {
    local ssid="$1"
    local iface="$2"
    local timeout=60

    echo ">>> Checking connection (timeout ${timeout}s)..."

    for i in $(seq 1 "$timeout"); do
        local state connected_ssid ip
        state=$(wpa status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')
        connected_ssid=$(wpa status 2>/dev/null | awk -F= '/^ssid=/{print $2; exit}')
        ip=$(has_usable_ipv4 "$iface" || true)
        ip=${ip:-no-ip}

        echo ">>> [$i/$timeout] state=$state ssid=$connected_ssid ip=$ip"

        if [ "$state" = "COMPLETED" ] && [ "$connected_ssid" = "$ssid" ] && [ "$ip" != "no-ip" ]; then
            echo ">>> Connected to $ssid (IP: $ip)"
            return 0
        fi

        sleep 1
    done

    echo ">>> Not connected after ${timeout}s"
    return 1
}

reconnect_to_fallback_wifi() {
    local fallback_ssid="$1"
    local iface="$2"

    if [ "${RECONNECT_ENABLED}" = "0" ]; then
        return 0
    fi

    if [ -z "${fallback_ssid:-}" ]; then
        echo ">>> Reconnect skipped: no fallback SSID configured"
        return 1
    fi

    local current_ssid
    current_ssid=$(get_current_connection)
    if [ "$current_ssid" = "$fallback_ssid" ]; then
        echo ">>> Already connected to fallback WiFi: $fallback_ssid"
        if [ -n "$_WPA_TEMP_NET_ID" ]; then
            wpa remove_network "$_WPA_TEMP_NET_ID" >/dev/null 2>&1 || true
            _WPA_TEMP_NET_ID=""
        fi
        return 0
    fi

    echo ">>> Reconnecting to fallback WiFi: $fallback_ssid"

    if [ -n "$_WPA_TEMP_NET_ID" ]; then
        wpa remove_network "$_WPA_TEMP_NET_ID" >/dev/null 2>&1 || true
        _WPA_TEMP_NET_ID=""
    fi

    # Find existing saved network by SSID
    local net_id
    net_id=$(wpa list_networks 2>/dev/null \
      | awk -F'\t' -v ssid="$fallback_ssid" 'NR>1 && $2==ssid {print $1; exit}')

    if [ -n "$net_id" ]; then
        echo ">>> Using saved network ID $net_id for: $fallback_ssid"
        wpa select_network "$net_id" >/dev/null 2>&1 && return 0
    fi

    # Not saved — add with TARGET_PSW as fallback
    echo ">>> Adding new network profile for: $fallback_ssid"
    net_id=$(wpa add_network 2>/dev/null | tail -1)
    if [[ "$net_id" =~ ^[0-9]+$ ]]; then
        wpa set_network "$net_id" ssid "\"$fallback_ssid\""  >/dev/null 2>&1
        wpa set_network "$net_id" psk  "\"$TARGET_PSW\""    >/dev/null 2>&1
        wpa enable_network "$net_id"                         >/dev/null 2>&1
        wpa select_network "$net_id"                         >/dev/null 2>&1 && return 0
    fi

    echo ">>> Reconnect to '$fallback_ssid' failed"
    return 1
}

send_configuration() {
    local wifi_ssid="$1"
    local wifi_psw="$2"
    local ap_ip="$3"

    set +H 2>/dev/null || true

    local esc_ssid esc_psw
    esc_ssid=${wifi_ssid//\\/\\\\}; esc_ssid=${esc_ssid//\"/\\\"}
    esc_psw=${wifi_psw//\\/\\\\};   esc_psw=${esc_psw//\"/\\\"}
    esc_ssid=${esc_ssid//$'\r'/};   esc_ssid=${esc_ssid//$'\n'/}
    esc_psw=${esc_psw//$'\r'/};     esc_psw=${esc_psw//$'\n'/}

    local json
    json="{\"psw\":\"$esc_psw\",\"ssid\":\"$esc_ssid\",\"t\":\"wlan\"}"

    echo ">>> Provisioning to $ap_ip:$AP_PORT"
    echo ">>> Payload: $json"
    echo ">>> Waiting ${INITIAL_SEND_WAIT}s before sending..."
    sleep "$INITIAL_SEND_WAIT"

    if ping -c 1 -W 1 "$ap_ip" >/dev/null 2>&1; then
        echo ">>> AP reachable at $ap_ip"
    else
        echo ">>> AP not pingable (still sending UDP)"
    fi

    local i rc=0
    for i in $(seq 1 "$SEND_RETRIES"); do
        echo ">>> UDP send attempt $i/$SEND_RETRIES"
        if ! printf '%s' "$json" | nc -u -w1 "$ap_ip" "$AP_PORT"; then
            echo ">>> UDP send failed on attempt $i"
            rc=1
        fi
        sleep "$SEND_INTERVAL"
    done

    [ "$rc" -eq 0 ] && echo ">>> Provisioning payload sent" && return 0
    echo ">>> Provisioning send had errors"
    return 1
}

verify_provisioning_success() {
    local ap_ssid="$1"
    local elapsed=0
    local stable_missing=0

    echo ">>> Verifying provisioning for '$ap_ssid' (timeout ${VERIFY_TIMEOUT}s)..."

    while [ "$elapsed" -lt "$VERIFY_TIMEOUT" ]; do
        if is_ap_visible "$ap_ssid"; then
            echo ">>> AP '$ap_ssid' still visible (${elapsed}s/${VERIFY_TIMEOUT}s)"
            stable_missing=0
        else
            stable_missing=$((stable_missing + 1))
            echo ">>> AP '$ap_ssid' not visible (${elapsed}s/${VERIFY_TIMEOUT}s), streak=$stable_missing"
            if [ "$stable_missing" -ge 2 ]; then
                echo ">>> Provisioning likely successful (AP mode exited)"
                return 0
            fi
        fi

        sleep "$VERIFY_SCAN_INTERVAL"
        elapsed=$((elapsed + VERIFY_SCAN_INTERVAL))
    done

    echo ">>> Verification timeout: AP '$ap_ssid' still visible"
    return 1
}

trigger_ha_webhook() {
    local ap_ssid="$1"
    local ap_name="$2"

    [ -z "${HA_WEBHOOK_URL:-}" ] && return 0

    local payload
    payload="{\"ssid\":\"${ap_ssid}\",\"ac\":\"${ap_name}\",\"ts\":\"$(date --iso-8601=seconds)\"}"

    echo ">>> Triggering HA webhook for $ap_name..."
    if curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "${HA_WEBHOOK_URL}" >/dev/null 2>&1; then
        echo ">>> Webhook sent"
    else
        echo ">>> Webhook failed (${HA_WEBHOOK_URL})"
        return 1
    fi
}

# === MAIN ===
parse_args "$@"
echo "Gree AP WiFi Configurator v2.3 (Debian/wpa_cli)"

if [ -z "${TARGET_PSW:-}" ]; then
    echo "TARGET_PSW is empty. Set it via --target-psw or env var TARGET_PSW."
    exit 1
fi

if [ -z "${TARGET_SSID:-}" ]; then
    echo "TARGET_SSID is empty. Set it via --target-ssid or env var TARGET_SSID."
    exit 1
fi

require_command wpa_cli
require_command iw
require_command ip
require_command nc

echo "Target WiFi: $TARGET_SSID"
echo "Check interval: ${CHECK_INTERVAL}s"
echo "----------------------------------------"

WLAN_IFACE=$(get_wlan_interface)
if [ $? -ne 0 ] || [ -z "${WLAN_IFACE:-}" ]; then
    echo "Abort: No WLAN interface found!"
    exit 1
fi

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

if [ "${RECONNECT_ENABLED}" = "1" ]; then
    echo "Fallback WiFi for reconnect: $RECONNECT_SSID"
else
    echo "Fallback reconnect disabled"
fi

echo "----------------------------------------"

while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Scanning for Gree AC APs..."

    visible_aps=$(scan_visible_aps)
    current_connection=$(get_current_connection)
    current_connection=${current_connection:-none}

    echo ">>> Current connection: $current_connection"
    echo ">>> Visible APs:"
    echo "$visible_aps"

    found_ap=false

    for ap_ssid in "${!GREE_AP_PSW[@]}"; do
        ap_name=$(ap_display_name "$ap_ssid")
        if echo "$visible_aps" | grep -iFx "$ap_ssid" >/dev/null; then
            echo "----------------------------------------"
            echo "$ap_name is VISIBLE → Processing..."
            found_ap=true

            if [ "$current_connection" = "$ap_ssid" ]; then
                echo ">>> Already connected to $ap_name → Provisioning"
                ap_ip=$(detect_ap_ip "$WLAN_IFACE")
                echo ">>> AP IP: $ap_ip"
                _webhook_pending=false
                send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip" || true
                verify_provisioning_success "$ap_ssid" && _webhook_pending=true || true
                reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
                [ "$_webhook_pending" = true ] && trigger_ha_webhook "$ap_ssid" "$ap_name" || true
                continue
            fi

            if connect_to_ap "$ap_ssid" "${GREE_AP_PSW[$ap_ssid]}"; then
                echo ">>> Connection attempt OK → Verifying..."

                if check_connection_status "$ap_ssid" "$WLAN_IFACE"; then
                    echo ">>> Connected to $ap_name → Provisioning"
                    ap_ip=$(detect_ap_ip "$WLAN_IFACE")
                    echo ">>> AP IP: $ap_ip"
                    _webhook_pending=false
                    send_configuration "$TARGET_SSID" "$TARGET_PSW" "$ap_ip" || true
                    verify_provisioning_success "$ap_ssid" && _webhook_pending=true || true
                    reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
                    sleep 3
                else
                    echo ">>> Connection verification FAILED"
                fi
            else
                echo ">>> Connection to $ap_name FAILED"
            fi

            reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
            [ "${_webhook_pending:-false}" = true ] && trigger_ha_webhook "$ap_ssid" "$ap_name" || true
        else
            echo ">>> $ap_name not visible"
        fi
    done

    if [ "$found_ap" = false ]; then
        echo ">>> No Gree APs visible → Waiting..."
    fi

    reconnect_to_fallback_wifi "$RECONNECT_SSID" "$WLAN_IFACE" || true
    echo "----------------------------------------"
    echo "Sleeping ${CHECK_INTERVAL}s until next scan..."
    sleep "$CHECK_INTERVAL"
done
