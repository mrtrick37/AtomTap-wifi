#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
FIRSTBOOT_ENV_FILE="/etc/atomtap/firstboot.env"
STATE_DIR="/var/lib/atomtap"
DONE_FILE="${STATE_DIR}/firstboot.done"

FIRSTBOOT_TIMEOUT_SEC=0
FIRSTBOOT_ON_TIMEOUT="reboot"
DEFAULT_ADMIN_USER="atomtap"
DEFAULT_ADMIN_PASSWORD="atomtap"
SETUP_TITLE="AtomTap First-Boot Setup"
WIFI_IFACE="wlan0"
ETH_IFACE="eth0"

if [[ -f "$FIRSTBOOT_ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/firstboot.env
  source "$FIRSTBOOT_ENV_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/forward.env
  source "$ENV_FILE"
fi

# Auto-detect WiFi interface: first interface with a wireless directory
detect_wifi_iface() {
  local candidate
  for candidate in /sys/class/net/*/wireless; do
    [[ -d "$candidate" ]] || continue
    basename "$(dirname "$candidate")"
    return
  done
  echo "wlan0"
}

# Auto-detect Ethernet interface: first non-loopback, non-wireless, ARPHRD_ETHER type
detect_eth_iface() {
  local iface type
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" == "lo" ]] && continue
    [[ -d "/sys/class/net/$iface/wireless" ]] && continue
    type="$(cat "/sys/class/net/$iface/type" 2>/dev/null || echo 0)"
    [[ "$type" == "1" ]] || continue
    echo "$iface"
    return
  done
  echo "eth0"
}

WIFI_IFACE="${WIFI_IFACE:-$(detect_wifi_iface)}"
ETH_IFACE="${ETH_IFACE:-$(detect_eth_iface)}"

mkdir -p "$STATE_DIR"

if [[ -f "$DONE_FILE" ]]; then
  exit 0
fi

# ── Validation helpers ─────────────────────────────────────────────────────────

valid_ipv4() {
  local ip="$1"
  local IFS='.'
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

subnet_mask_to_prefix() {
  local mask="$1"
  local IFS='.'
  local -a octets
  local octet bits bitstring ones=0

  read -r -a octets <<< "$mask"
  (( ${#octets[@]} == 4 )) || return 1

  bitstring=""
  for octet in "${octets[@]}"; do
    case "$octet" in
      255) bits="11111111" ;;
      254) bits="11111110" ;;
      252) bits="11111100" ;;
      248) bits="11111000" ;;
      240) bits="11110000" ;;
      224) bits="11100000" ;;
      192) bits="11000000" ;;
      128) bits="10000000" ;;
        0) bits="00000000" ;;
        *) return 1 ;;
    esac
    bitstring+="$bits"
  done

  [[ "$bitstring" == *01* ]] && return 1
  bitstring="${bitstring//0/}"
  ones="${#bitstring}"
  printf '%s' "$ones"
}

# ── UI wrappers ────────────────────────────────────────────────────────────────

UI_TOOL=""

ensure_ui_tool() {
  if command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
  else
    echo "ERROR: Neither whiptail nor dialog found." >&2
    exit 1
  fi
}

on_timeout() {
  printf '\nFirst-boot setup timed out after %s seconds.\n' "$FIRSTBOOT_TIMEOUT_SEC" >&2
  case "$FIRSTBOOT_ON_TIMEOUT" in
    reboot)   systemctl --no-block reboot || reboot || true ;;
    poweroff) systemctl --no-block poweroff || poweroff || true ;;
    *)        : ;;
  esac
  exit 1
}

run_ui() {
  local output rc

  if (( FIRSTBOOT_TIMEOUT_SEC > 0 )); then
    output="$(timeout --foreground "${FIRSTBOOT_TIMEOUT_SEC}" "$@" 3>&1 1>&2 2>&3)" && rc=0 || rc=$?
  else
    output="$("$@" 3>&1 1>&2 2>&3)" && rc=0 || rc=$?
  fi

  (( rc == 124 )) && on_timeout
  printf '%s' "$output"
  return "$rc"
}

ui_msg() {
  run_ui "$UI_TOOL" --title "$SETUP_TITLE" --msgbox "$1" 12 78 || true
}

ui_input() {
  local prompt="$1" default="$2" outvar="$3" value
  value="$(run_ui "$UI_TOOL" --title "$SETUP_TITLE" --inputbox "$prompt" 12 78 "$default")" || return 1
  printf -v "$outvar" '%s' "$value"
}

ui_password() {
  local prompt="$1" outvar="$2" value
  value="$(run_ui "$UI_TOOL" --title "$SETUP_TITLE" --passwordbox "$prompt" 12 78)" || return 1
  printf -v "$outvar" '%s' "$value"
}

ui_menu() {
  local prompt="$1" default="$2" outvar="$3"
  shift 3
  local value
  value="$(run_ui "$UI_TOOL" --title "$SETUP_TITLE" --default-item "$default" --menu "$prompt" 12 78 4 "$@")" || return 1
  printf -v "$outvar" '%s' "$value"
}

ui_yesno() {
  run_ui "$UI_TOOL" --title "$SETUP_TITLE" --yesno "$1" 16 78
}

# ── Prompts ────────────────────────────────────────────────────────────────────

prompt_username() {
  local val="$1"
  while true; do
    ui_input "Admin username" "$val" val || return 1
    [[ -z "$val" ]] && { ui_msg "Username cannot be empty."; continue; }
    [[ ! "$val" =~ ^[a-z_][a-z0-9_-]*$ ]] && {
      ui_msg "Invalid username.\n\nUse lowercase letters, digits, _ or -, starting with a letter or _."
      continue
    }
    printf '%s' "$val"
    return 0
  done
}

prompt_password() {
  local label="$1"
  local p1 p2
  while true; do
    ui_password "Password for $label" p1 || return 1
    [[ -z "$p1" ]] && { ui_msg "Password cannot be empty."; continue; }
    ui_password "Confirm password for $label" p2 || return 1
    [[ "$p1" != "$p2" ]] && { ui_msg "Passwords do not match. Try again."; continue; }
    printf '%s' "$p1"
    return 0
  done
}

# scan_ssids: populates the variable named by $1 with newline-separated SSIDs.
# Runs in the current shell (no subshell) so ui_msg/infobox work reliably.
scan_ssids() {
  local -n _ssids_out="$1"
  _ssids_out=""

  "$UI_TOOL" --title "$SETUP_TITLE" \
    --infobox "Scanning for Wi-Fi networks...\n\nPlease wait." 7 50 2>/dev/null || true

  # Wait up to 20 s for NetworkManager to be responsive before scanning
  local i
  for (( i = 0; i < 20; i++ )); do
    nmcli general status >/dev/null 2>&1 && break
    sleep 1
  done

  # Ensure the WiFi kernel module is loaded (RPi uses brcmfmac)
  modprobe brcmutil >/dev/null 2>&1 || true
  modprobe brcmfmac >/dev/null 2>&1 || true

  # Wait up to 10 s for the interface to appear after module load
  local j
  for (( j = 0; j < 10; j++ )); do
    [[ -d "/sys/class/net/$WIFI_IFACE" ]] && break
    sleep 1
  done

  # Capture diagnostics in case we need to show them
  local diag_iface diag_lsmod diag_dmesg diag_nm
  diag_iface="$(ip link show 2>&1 | head -20)"
  diag_lsmod="$(lsmod | grep -i brcm 2>&1 || echo '(none)')"
  diag_dmesg="$(dmesg 2>/dev/null | grep -i 'brcm\|wlan\|wifi\|firmware' | tail -10 || echo '(none)')"
  diag_nm="$(nmcli device 2>&1 || echo '(none)')"

  if [[ ! -d "/sys/class/net/$WIFI_IFACE" ]]; then
    ui_msg "WARNING: $WIFI_IFACE did not appear after module load.\n\nInterfaces:\n${diag_iface}\n\nbrcm modules:\n${diag_lsmod}\n\ndmesg (wifi):\n${diag_dmesg}\n\nNM devices:\n${diag_nm}"
  else
    local iface_state
    iface_state="$(cat "/sys/class/net/$WIFI_IFACE/operstate" 2>/dev/null || echo 'unknown')"
    "$UI_TOOL" --title "$SETUP_TITLE" \
      --infobox "$WIFI_IFACE found (state: ${iface_state})\n\nBringing up and scanning..." 7 50 2>/dev/null || true
  fi

  ip link set "$WIFI_IFACE" up >/dev/null 2>&1 || true
  sleep 1
  nmcli device set "$WIFI_IFACE" managed yes >/dev/null 2>&1 || true
  nmcli device wifi rescan ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
  sleep 3

  local raw
  raw="$(nmcli -t -f SSID device wifi list ifname "$WIFI_IFACE" 2>/dev/null \
    | grep -v '^--$' | grep -v '^$' | sort -u || true)"

  # Retry once if the first scan returned nothing
  if [[ -z "$raw" ]]; then
    nmcli device wifi rescan ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep 3
    raw="$(nmcli -t -f SSID device wifi list ifname "$WIFI_IFACE" 2>/dev/null \
      | grep -v '^--$' | grep -v '^$' | sort -u || true)"
  fi

  # Show diagnostics if scan is still empty so we can debug why
  if [[ -z "$raw" ]]; then
    local diag_scan diag_reg
    diag_scan="$(nmcli -t device wifi list ifname "$WIFI_IFACE" 2>&1 | head -5 || echo '(none)')"
    diag_reg="$(iw reg get 2>&1 || echo '(unavailable)')"
    ui_msg "WARNING: Wi-Fi scan returned no networks on $WIFI_IFACE.\n\nInterfaces:\n${diag_iface}\nbrcm modules:\n${diag_lsmod}\ndmesg:\n${diag_dmesg}\nNM devices:\n${diag_nm}\n\nnmcli wifi raw:\n${diag_scan}\n\nRegulatory:\n${diag_reg}"
  fi

  _ssids_out="$raw"
}

# prompt_ssid: prompts for SSID, writing result into the variable named by $1.
# Runs in the current shell so all UI calls are at top-level — no nested subshells.
prompt_ssid() {
  local -n _ssid_result="$1"
  local val="${_ssid_result:-}"
  local scanned ssid_list item selected
  local -a menu_args
  local OTHER="-- Enter manually --"

  # Discard any stale/corrupt value that matches the sentinel or starts with '--'
  [[ "$val" == "$OTHER" || "$val" == --* ]] && val=""

  scan_ssids scanned

  # Use a tmpfile to capture whiptail output — avoids all command substitutions
  # so whiptail runs in the current shell with full terminal access.
  local _tmpfile
  _tmpfile="$(mktemp)"

  if [[ -n "$scanned" ]]; then
    readarray -t ssid_list <<< "$scanned"
    menu_args=()
    for item in "${ssid_list[@]}"; do
      menu_args+=("$item" " ")
    done
    menu_args+=("$OTHER" " ")

    # Self-healing menu loop: buffered Enter keystrokes from preceding
    # password dialogs can arrive in the tty queue at unpredictable times,
    # instantly dismissing the menu before the user sees it.  We detect
    # this by timing: no human can read a list and select in under 1 second,
    # so any exit faster than that is an auto-dismiss.  Drain and retry.
    local _start _elapsed _tries=0
    while (( _tries < 10 )); do
      dd if=/dev/tty bs=4096 count=1 iflag=nonblock >/dev/null 2>&1 || true
      sleep 0.1
      : > "$_tmpfile"
      _start=$(date +%s 2>/dev/null || echo 0)
      "$UI_TOOL" --title "$SETUP_TITLE" \
        --menu "Select Wi-Fi network" 20 78 12 \
        "${menu_args[@]}" 2>"$_tmpfile" || true
      _elapsed=$(( $(date +%s 2>/dev/null || echo 9) - _start ))
      (( _elapsed >= 1 )) && break
      _tries=$(( _tries + 1 ))
    done
    selected="$(cat "$_tmpfile")"

    if [[ -n "$selected" && "$selected" != "$OTHER" ]]; then
      _ssid_result="$selected"
      rm -f "$_tmpfile"
      return 0
    fi
  fi

  # Manual entry (scan empty, menu cancelled, or user chose "Enter manually")
  while true; do
    "$UI_TOOL" --title "$SETUP_TITLE" \
      --inputbox "Wi-Fi SSID" 12 78 "$val" 2>"$_tmpfile" \
      || { rm -f "$_tmpfile"; return 1; }
    val="$(cat "$_tmpfile")"
    if [[ -n "$val" ]]; then
      _ssid_result="$val"
      rm -f "$_tmpfile"
      return 0
    fi
    ui_msg "SSID cannot be empty."
  done
}

prompt_psk() {
  local p1 p2
  while true; do
    ui_password "Wi-Fi passphrase" p1 || return 1
    [[ -z "$p1" ]] && { ui_msg "Passphrase cannot be empty."; continue; }
    ui_password "Confirm Wi-Fi passphrase" p2 || return 1
    [[ "$p1" != "$p2" ]] && { ui_msg "Passphrases do not match. Try again."; continue; }
    printf '%s' "$p1"
    return 0
  done
}

prompt_collector_ip() {
  local val="$1"
  while true; do
    ui_input "Collector IPv4 address (traffic forwarding destination)" "$val" val || return 1
    valid_ipv4 "$val" && { printf '%s' "$val"; return 0; }
    ui_msg "'$val' is not a valid IPv4 address."
  done
}

prompt_ipv4_mode() {
  local val="${1:-dhcp}"
  ui_menu "Wi-Fi IPv4 mode for $WIFI_IFACE" "$val" val \
    "dhcp"   "Obtain address automatically (DHCP)" \
    "static" "Use a static IP address" || return 1
  printf '%s' "$val"
}

prompt_static_ip() {
  local val="$1"
  while true; do
    ui_input "$WIFI_IFACE static IPv4 address" "$val" val || return 1
    valid_ipv4 "$val" && { printf '%s' "$val"; return 0; }
    ui_msg "'$val' is not a valid IPv4 address."
  done
}

prompt_subnet() {
  local val="$1"
  while true; do
    ui_input "$WIFI_IFACE subnet mask  (e.g. 255.255.255.0)" "$val" val || return 1
    subnet_mask_to_prefix "$val" >/dev/null 2>&1 && { printf '%s' "$val"; return 0; }
    ui_msg "'$val' is not a valid subnet mask."
  done
}

prompt_gateway() {
  local val="$1"
  while true; do
    ui_input "$WIFI_IFACE default gateway" "$val" val || return 1
    valid_ipv4 "$val" && { printf '%s' "$val"; return 0; }
    ui_msg "'$val' is not a valid IPv4 address."
  done
}

# ── Apply settings ─────────────────────────────────────────────────────────────

set_env_value() {
  local file="$1" key="$2" value="$3"
  # Use printf %q to produce a bash-safe quoted value, then escape & and | for sed
  local quoted
  quoted="$(printf '%q' "$value")"
  local escaped="${quoted//&/\\&}"
  escaped="${escaped//|/\\|}"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$quoted" >> "$file"
  fi
}

apply_admin_user() {
  local username="$1" password="$2"

  # Ensure the default user exists first
  if id "$DEFAULT_ADMIN_USER" >/dev/null 2>&1; then
    usermod -a -G wheel "$DEFAULT_ADMIN_USER"
  else
    useradd -m -G wheel "$DEFAULT_ADMIN_USER"
  fi

  if [[ "$username" != "$DEFAULT_ADMIN_USER" ]]; then
    if id "$username" >/dev/null 2>&1; then
      usermod -a -G wheel "$username"
    else
      useradd -m -G wheel "$username"
    fi
    printf '%s:%s\n' "$username" "$password" | chpasswd \
      || { echo "[atomtap] ERROR: chpasswd failed for $username" >&2; exit 1; }
    printf '%s:%s\n' "$DEFAULT_ADMIN_USER" "$password" | chpasswd \
      || { echo "[atomtap] ERROR: chpasswd failed for $DEFAULT_ADMIN_USER" >&2; exit 1; }
  else
    printf '%s:%s\n' "$DEFAULT_ADMIN_USER" "$password" | chpasswd \
      || { echo "[atomtap] ERROR: chpasswd failed for $DEFAULT_ADMIN_USER" >&2; exit 1; }
  fi
}

apply_wifi() {
  local connection_name
  connection_name="$(nmcli -t -f NAME,DEVICE connection show \
    | awk -F: -v dev="$WIFI_IFACE" '$2==dev{print $1;exit}')"

  if [[ -z "$connection_name" ]]; then
    connection_name="atomtap-${WIFI_IFACE}"
    nmcli connection add type wifi ifname "$WIFI_IFACE" \
      con-name "$connection_name" ssid "$WLAN_SSID" >/dev/null
  fi

  nmcli connection modify "$connection_name" \
    wifi.ssid                  "$WLAN_SSID" \
    wifi-sec.key-mgmt          wpa-psk \
    wifi-sec.psk               "$WLAN_PSK" \
    connection.interface-name  "$WIFI_IFACE" \
    connection.autoconnect     yes

  if [[ "$WLAN_IPV4_MODE" == "static" ]]; then
    nmcli connection modify "$connection_name" \
      ipv4.method    manual \
      ipv4.addresses "$WLAN_IPV4_CIDR" \
      ipv4.gateway   "$WLAN_IPV4_GATEWAY"
  else
    nmcli connection modify "$connection_name" \
      ipv4.method    auto \
      ipv4.addresses "" \
      ipv4.gateway   ""
  fi

  nmcli connection up "$connection_name" ifname "$WIFI_IFACE" >/dev/null 2>&1 \
    || nmcli connection up "$connection_name" >/dev/null 2>&1 \
    || true
}

write_env() {
  [[ -f "$ENV_FILE" ]] || install -D -m 0600 /dev/null "$ENV_FILE"
  set_env_value "$ENV_FILE" "ADMIN_USER"        "$ADMIN_USER"
  set_env_value "$ENV_FILE" "ETH_IFACE"         "$ETH_IFACE"
  set_env_value "$ENV_FILE" "WIFI_IFACE"        "$WIFI_IFACE"
  set_env_value "$ENV_FILE" "WLAN_SSID"         "$WLAN_SSID"
  set_env_value "$ENV_FILE" "WLAN_PSK"          "$WLAN_PSK"
  set_env_value "$ENV_FILE" "COLLECTOR_IP"      "$COLLECTOR_IP"
  set_env_value "$ENV_FILE" "WLAN_IPV4_MODE"    "$WLAN_IPV4_MODE"
  set_env_value "$ENV_FILE" "WLAN_IPV4_ADDRESS" "${WLAN_IPV4_ADDRESS:-}"
  set_env_value "$ENV_FILE" "WLAN_IPV4_SUBNET"  "${WLAN_IPV4_SUBNET:-}"
  set_env_value "$ENV_FILE" "WLAN_IPV4_CIDR"    "${WLAN_IPV4_CIDR:-}"
  set_env_value "$ENV_FILE" "WLAN_IPV4_GATEWAY" "${WLAN_IPV4_GATEWAY:-}"
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Suppress kernel and audit messages so they don't overwrite the whiptail UI.
dmesg -n 1 2>/dev/null || true

ensure_ui_tool

ui_msg "Welcome to AtomTap.\n\nThis setup will configure your admin account, Wi-Fi uplink, and collector destination.\n\nForwarding will not start until setup is complete."

# Collect inputs
ADMIN_USER="$(prompt_username "${DEFAULT_ADMIN_USER}")"    || exit 1
ADMIN_PASS="$(prompt_password "$ADMIN_USER")"              || exit 1
prompt_ssid WLAN_SSID                                      || exit 1
WLAN_PSK="$(prompt_psk)"                                   || exit 1
COLLECTOR_IP="$(prompt_collector_ip "${COLLECTOR_IP:-}")"  || exit 1
WLAN_IPV4_MODE="$(prompt_ipv4_mode "${WLAN_IPV4_MODE:-}")" || exit 1

WLAN_IPV4_ADDRESS="" WLAN_IPV4_SUBNET="" WLAN_IPV4_CIDR="" WLAN_IPV4_GATEWAY=""

if [[ "$WLAN_IPV4_MODE" == "static" ]]; then
  WLAN_IPV4_ADDRESS="$(prompt_static_ip "${WLAN_IPV4_ADDRESS:-}")" || exit 1
  WLAN_IPV4_SUBNET="$(prompt_subnet "${WLAN_IPV4_SUBNET:-}")"       || exit 1
  WLAN_IPV4_GATEWAY="$(prompt_gateway "${WLAN_IPV4_GATEWAY:-}")"   || exit 1
  prefix="$(subnet_mask_to_prefix "$WLAN_IPV4_SUBNET")"
  WLAN_IPV4_CIDR="${WLAN_IPV4_ADDRESS}/${prefix}"
fi

# Build summary
SUMMARY="Apply these settings and reboot?\n"
SUMMARY+="\nAdmin user:    $ADMIN_USER"
SUMMARY+="\nWi-Fi SSID:    $WLAN_SSID"
SUMMARY+="\nCollector IP:  $COLLECTOR_IP"
SUMMARY+="\n$WIFI_IFACE mode: $WLAN_IPV4_MODE"
if [[ "$WLAN_IPV4_MODE" == "static" ]]; then
  SUMMARY+="\nStatic IP:     $WLAN_IPV4_ADDRESS"
  SUMMARY+="\nSubnet:        $WLAN_IPV4_SUBNET"
  SUMMARY+="\nGateway:       $WLAN_IPV4_GATEWAY"
fi

ui_yesno "$SUMMARY" || exit 1

# Apply
echo "[atomtap] Applying configuration..."
apply_admin_user "$ADMIN_USER" "$ADMIN_PASS"
echo "[atomtap] Admin user set."
write_env
echo "[atomtap] Config written."

apply_wifi || true
echo "[atomtap] Wi-Fi profile configured."

touch "$DONE_FILE"
chmod 0600 "$DONE_FILE"

ui_msg "Setup complete. The device will reboot now and begin forwarding traffic."
