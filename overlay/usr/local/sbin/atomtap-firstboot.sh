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

if [[ -f "$FIRSTBOOT_ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/firstboot.env
  source "$FIRSTBOOT_ENV_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/forward.env
  source "$ENV_FILE"
fi

WIFI_IFACE="${WIFI_IFACE:-wlan0}"

mkdir -p "$STATE_DIR"

if [[ -f "$DONE_FILE" ]]; then
  exit 0
fi

UI_TOOL=""

on_timeout() {
  printf 'First-boot setup timed out after %s seconds.\n' "$FIRSTBOOT_TIMEOUT_SEC" >&2

  case "$FIRSTBOOT_ON_TIMEOUT" in
    reboot)
      echo "Triggering reboot." >&2
      systemctl --no-block reboot || reboot || true
      ;;
    poweroff)
      echo "Triggering poweroff." >&2
      systemctl --no-block poweroff || poweroff || true
      ;;
    fail)
      echo "Leaving setup failed as configured (FIRSTBOOT_ON_TIMEOUT=fail)." >&2
      ;;
    *)
      echo "Unknown FIRSTBOOT_ON_TIMEOUT='$FIRSTBOOT_ON_TIMEOUT'; failing setup." >&2
      ;;
  esac

  exit 1
}

ensure_ui_tool() {
  if command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
    return
  fi

  if command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
    return
  fi

  echo "Neither whiptail nor dialog is installed; cannot run first-boot setup menu." >&2
  exit 1
}

run_ui() {
  local output rc

  if (( FIRSTBOOT_TIMEOUT_SEC > 0 )); then
    if output="$(timeout --foreground "${FIRSTBOOT_TIMEOUT_SEC}" "$@" 3>&1 1>&2 2>&3)"; then
      rc=0
    else
      rc=$?
    fi
  else
    if output="$("$@" 3>&1 1>&2 2>&3)"; then
      rc=0
    else
      rc=$?
    fi
  fi

  if (( rc == 124 )); then
    on_timeout
  fi

  printf '%s' "$output"
  return "$rc"
}

ui_msg() {
  run_ui "$UI_TOOL" --title "$SETUP_TITLE" --msgbox "$1" 12 78 || true
}

ui_input() {
  local prompt="$1"
  local default_value="$2"
  local outvar="$3"
  local value

  if ! value="$(run_ui "$UI_TOOL" --title "$SETUP_TITLE" --inputbox "$prompt" 12 78 "$default_value")"; then
    return 1
  fi

  printf -v "$outvar" '%s' "$value"
  return 0
}

ui_password() {
  local prompt="$1"
  local outvar="$2"
  local value

  if ! value="$(run_ui "$UI_TOOL" --title "$SETUP_TITLE" --passwordbox "$prompt" 12 78)"; then
    return 1
  fi

  printf -v "$outvar" '%s' "$value"
  return 0
}

prompt_username() {
  local input="$1"

  while true; do
    if ! ui_input "Admin username" "$input" input; then
      return 1
    fi

    if [[ -z "$input" ]]; then
      ui_msg "Username cannot be empty."
      continue
    fi

    if [[ ! "$input" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
      ui_msg "Invalid username format. Use lowercase letters, digits, _, -, starting with a letter or _."
      continue
    fi

    printf '%s' "$input"
    return 0
  done
}

ui_menu() {
  local prompt="$1"
  local default_item="$2"
  local outvar="$3"
  shift 3
  local value

  if ! value="$(run_ui "$UI_TOOL" --title "$SETUP_TITLE" --menu "$prompt" 14 78 6 --default-item "$default_item" "$@")"; then
    return 1
  fi

  printf -v "$outvar" '%s' "$value"
  return 0
}

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

valid_ipv4_cidr() {
  local cidr="$1"
  local addr prefix

  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
  addr="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv4 "$addr" || return 1
  ((prefix >= 0 && prefix <= 32)) || return 1
}

subnet_mask_to_prefix() {
  local mask="$1"
  local IFS='.'
  local -a octets
  local octet bits
  local bitstring=""
  local ones=0

  read -r -a octets <<< "$mask"
  if (( ${#octets[@]} != 4 )); then
    return 1
  fi

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

  if [[ "$bitstring" == *01* ]]; then
    return 1
  fi

  bitstring="${bitstring//0/}"
  ones="${#bitstring}"
  printf '%s' "$ones"
}

prompt_wlan_ssid() {
  local ssid="$1"

  while true; do
    if ! ui_input "Wi-Fi SSID" "$ssid" ssid; then
      return 1
    fi

    if [[ -n "$ssid" ]]; then
      printf '%s' "$ssid"
      return 0
    fi

    ui_msg "SSID cannot be empty."
  done
}

prompt_collector_ip() {
  local ip="$1"

  while true; do
    if ! ui_input "Collector destination IPv4 address" "$ip" ip; then
      return 1
    fi

    if valid_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi

    ui_msg "Invalid IPv4 address."
  done
}

prompt_wlan_psk() {
  local pass1 pass2

  while true; do
    if ! ui_password "Wi-Fi PSK" pass1; then
      return 1
    fi

    if [[ -z "$pass1" ]]; then
      ui_msg "PSK cannot be empty."
      continue
    fi

    if ! ui_password "Confirm Wi-Fi PSK" pass2; then
      return 1
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      ui_msg "PSKs do not match. Try again."
      continue
    fi

    printf '%s' "$pass1"
    return 0
  done
}

prompt_wlan_ipv4_mode() {
  local mode="$1"

  if [[ -z "$mode" ]]; then
    mode="dhcp"
  fi

  while true; do
    if ! ui_menu "Configure ${WIFI_IFACE} IPv4 mode" "$mode" mode \
      "dhcp" "Use DHCP" \
      "static" "Use static IPv4"; then
      return 1
    fi

    if [[ "$mode" == "dhcp" || "$mode" == "static" ]]; then
      printf '%s' "$mode"
      return 0
    fi

    ui_msg "Invalid selection."
  done
}

prompt_wlan_ipv4_address() {
  local ip="$1"

  while true; do
    if ! ui_input "${WIFI_IFACE} static IPv4 address" "$ip" ip; then
      return 1
    fi

    if valid_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi

    ui_msg "Invalid IPv4 address."
  done
}

prompt_wlan_subnet() {
  local subnet="$1"
  local prefix

  while true; do
    if ! ui_input "${WIFI_IFACE} subnet mask (e.g. 255.255.255.0)" "$subnet" subnet; then
      return 1
    fi

    if prefix="$(subnet_mask_to_prefix "$subnet")"; then
      printf '%s' "$subnet"
      return 0
    fi

    ui_msg "Invalid subnet mask."
  done
}

prompt_wlan_gateway_required() {
  local gateway="$1"

  while true; do
    if ! ui_input "${WIFI_IFACE} IPv4 gateway" "$gateway" gateway; then
      return 1
    fi

    if valid_ipv4 "$gateway"; then
      printf '%s' "$gateway"
      return 0
    fi

    ui_msg "Invalid IPv4 gateway."
  done
}

prompt_password_if_changed() {
  local target_user="$1"
  local pass1 pass2

  while true; do
    if ! ui_password "New password for ${target_user} (leave blank to keep current)" pass1; then
      return 1
    fi

    if [[ -z "$pass1" ]]; then
      printf ''
      return 0
    fi

    if ! ui_password "Confirm new password for ${target_user}" pass2; then
      return 1
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      ui_msg "Passwords do not match. Try again."
      continue
    fi

    printf '%s' "$pass1"
    return 0
  done
}

prompt_password_required() {
  local target_user="$1"
  local pass1 pass2

  while true; do
    if ! ui_password "Password for ${target_user}" pass1; then
      return 1
    fi

    if [[ -z "$pass1" ]]; then
      ui_msg "Password cannot be empty."
      continue
    fi

    if ! ui_password "Confirm password for ${target_user}" pass2; then
      return 1
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      ui_msg "Passwords do not match. Try again."
      continue
    fi

    printf '%s' "$pass1"
    return 0
  done
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped

  escaped="${value//\\/\\\\}"
  escaped="${escaped//&/\\&}"

  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

apply_wlan_config() {
  local connection_name
  local mode

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "nmcli not found; cannot configure ${WIFI_IFACE}." >&2
    exit 1
  fi

  connection_name="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$WIFI_IFACE" '$2 == dev {print $1; exit}')"
  if [[ -z "$connection_name" ]]; then
    connection_name="atomtap-${WIFI_IFACE}"
    nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$connection_name" ssid "$WLAN_SSID" >/dev/null
  fi

  nmcli connection modify "$connection_name" wifi.ssid "$WLAN_SSID"
  nmcli connection modify "$connection_name" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WLAN_PSK"
  nmcli connection modify "$connection_name" connection.interface-name "$WIFI_IFACE"
  nmcli connection modify "$connection_name" connection.autoconnect yes

  mode="${WLAN_IPV4_MODE:-dhcp}"
  if [[ "$mode" == "static" ]]; then
    nmcli connection modify "$connection_name" ipv4.method manual ipv4.addresses "$WLAN_IPV4_CIDR" ipv4.gateway "$WLAN_IPV4_GATEWAY"
  else
    nmcli connection modify "$connection_name" ipv4.method auto
    nmcli connection modify "$connection_name" -ipv4.addresses
    nmcli connection modify "$connection_name" -ipv4.gateway
  fi

  nmcli connection up "$connection_name" ifname "$WIFI_IFACE" >/dev/null 2>&1 || nmcli connection up "$connection_name" >/dev/null
}

ensure_default_admin_user() {
  if id "$DEFAULT_ADMIN_USER" >/dev/null 2>&1; then
    usermod -a -G wheel "$DEFAULT_ADMIN_USER"
  else
    useradd -m -G wheel "$DEFAULT_ADMIN_USER"
  fi

  if [[ -n "$DEFAULT_ADMIN_PASSWORD" ]]; then
    printf '%s:%s\n' "$DEFAULT_ADMIN_USER" "$DEFAULT_ADMIN_PASSWORD" | chpasswd
  fi
}

confirm_summary() {
  local summary="$1"
  run_ui "$UI_TOOL" --title "$SETUP_TITLE" --yesno "$summary" 16 78
}

ensure_ui_tool
ensure_default_admin_user

ui_msg "Complete first-boot setup to configure admin credentials and Wi-Fi. Device reboots when setup finishes."

ADMIN_USERNAME="${DEFAULT_ADMIN_USER}"
ADMIN_PASSWORD=""
WLAN_SSID="${WLAN_SSID:-}"
WLAN_PSK="${WLAN_PSK:-}"
COLLECTOR_IP="${COLLECTOR_IP:-}"
WLAN_IPV4_MODE="${WLAN_IPV4_MODE:-dhcp}"
WLAN_IPV4_ADDRESS="${WLAN_IPV4_ADDRESS:-}"
WLAN_IPV4_SUBNET="${WLAN_IPV4_SUBNET:-}"
WLAN_IPV4_CIDR="${WLAN_IPV4_CIDR:-}"
WLAN_IPV4_GATEWAY="${WLAN_IPV4_GATEWAY:-}"

if ! ADMIN_USERNAME="$(prompt_username "$ADMIN_USERNAME")"; then
  exit 1
fi

if ! ADMIN_PASSWORD="$(prompt_password_required "$ADMIN_USERNAME")"; then
  exit 1
fi

if ! WLAN_SSID="$(prompt_wlan_ssid "$WLAN_SSID")"; then
  exit 1
fi

if ! WLAN_PSK="$(prompt_wlan_psk)"; then
  exit 1
fi

if ! COLLECTOR_IP="$(prompt_collector_ip "$COLLECTOR_IP")"; then
  exit 1
fi

if ! WLAN_IPV4_MODE="$(prompt_wlan_ipv4_mode "$WLAN_IPV4_MODE")"; then
  exit 1
fi

if [[ "$WLAN_IPV4_MODE" == "static" ]]; then
  if ! WLAN_IPV4_ADDRESS="$(prompt_wlan_ipv4_address "$WLAN_IPV4_ADDRESS")"; then
    exit 1
  fi

  if ! WLAN_IPV4_SUBNET="$(prompt_wlan_subnet "$WLAN_IPV4_SUBNET")"; then
    exit 1
  fi

  if ! WLAN_IPV4_GATEWAY="$(prompt_wlan_gateway_required "$WLAN_IPV4_GATEWAY")"; then
    exit 1
  fi

  WLAN_IPV4_PREFIX="$(subnet_mask_to_prefix "$WLAN_IPV4_SUBNET")"
  WLAN_IPV4_CIDR="${WLAN_IPV4_ADDRESS}/${WLAN_IPV4_PREFIX}"
else
  WLAN_IPV4_ADDRESS=""
  WLAN_IPV4_SUBNET=""
  WLAN_IPV4_CIDR=""
  WLAN_IPV4_GATEWAY=""
fi

SUMMARY_MSG="Apply settings and reboot?\n\nAdmin user: ${ADMIN_USERNAME}\nWi-Fi SSID: ${WLAN_SSID}\nCollector IP: ${COLLECTOR_IP}\n${WIFI_IFACE} IPv4 mode: ${WLAN_IPV4_MODE}"
if [[ "$WLAN_IPV4_MODE" == "static" ]]; then
  SUMMARY_MSG+="\n${WIFI_IFACE} static IP: ${WLAN_IPV4_ADDRESS}\n${WIFI_IFACE} subnet: ${WLAN_IPV4_SUBNET}\n${WIFI_IFACE} gateway: ${WLAN_IPV4_GATEWAY}"
fi

if ! confirm_summary "$SUMMARY_MSG"; then
  exit 1
fi

if [[ "$ADMIN_USERNAME" != "$DEFAULT_ADMIN_USER" ]]; then
  if id "$ADMIN_USERNAME" >/dev/null 2>&1; then
    usermod -a -G wheel "$ADMIN_USERNAME"
  else
    useradd -m -G wheel "$ADMIN_USERNAME"
  fi

  printf '%s:%s\n' "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | chpasswd
  printf '%s:%s\n' "$DEFAULT_ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
else
  printf '%s:%s\n' "$DEFAULT_ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
fi

if [[ ! -f "$ENV_FILE" ]]; then
  install -D -m 0644 /dev/null "$ENV_FILE"
fi

set_env_value "$ENV_FILE" "WLAN_SSID" "$WLAN_SSID"
set_env_value "$ENV_FILE" "WLAN_PSK" "$WLAN_PSK"
set_env_value "$ENV_FILE" "COLLECTOR_IP" "$COLLECTOR_IP"
set_env_value "$ENV_FILE" "WLAN_IPV4_MODE" "$WLAN_IPV4_MODE"
set_env_value "$ENV_FILE" "WLAN_IPV4_ADDRESS" "$WLAN_IPV4_ADDRESS"
set_env_value "$ENV_FILE" "WLAN_IPV4_SUBNET" "$WLAN_IPV4_SUBNET"
set_env_value "$ENV_FILE" "WLAN_IPV4_CIDR" "$WLAN_IPV4_CIDR"
set_env_value "$ENV_FILE" "WLAN_IPV4_GATEWAY" "$WLAN_IPV4_GATEWAY"

apply_wlan_config

touch "$DONE_FILE"
chmod 0600 "$DONE_FILE"

ui_msg "AtomTap setup completed. System will reboot now."
systemctl --no-block reboot || reboot || true
