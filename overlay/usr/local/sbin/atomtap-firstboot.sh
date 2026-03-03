#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
FIRSTBOOT_ENV_FILE="/etc/atomtap/firstboot.env"
STATE_DIR="/var/lib/atomtap"
DONE_FILE="${STATE_DIR}/firstboot.done"
TTY_DEV="/dev/tty1"

FIRSTBOOT_TIMEOUT_SEC=0
FIRSTBOOT_ON_TIMEOUT="reboot"

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

if [[ ! -e "$TTY_DEV" ]]; then
  TTY_DEV="/dev/console"
fi

exec <"$TTY_DEV" >"$TTY_DEV" 2>"$TTY_DEV"

echo
printf '=== AtomTap First-Boot Setup ===\n'
printf 'A local admin user, collector destination IP, and Wi-Fi IPv4 config are required.\n\n'

on_timeout() {
  echo
  printf 'First-boot setup timed out after %s seconds.\n' "$FIRSTBOOT_TIMEOUT_SEC"

  case "$FIRSTBOOT_ON_TIMEOUT" in
    reboot)
      echo "Triggering reboot."
      systemctl --no-block reboot || reboot || true
      ;;
    poweroff)
      echo "Triggering poweroff."
      systemctl --no-block poweroff || poweroff || true
      ;;
    fail)
      echo "Leaving setup failed as configured (FIRSTBOOT_ON_TIMEOUT=fail)."
      ;;
    *)
      echo "Unknown FIRSTBOOT_ON_TIMEOUT='$FIRSTBOOT_ON_TIMEOUT'; failing setup."
      ;;
  esac

  exit 1
}

read_input() {
  local prompt="$1"
  local outvar="$2"
  local secret="${3:-0}"
  local value

  if (( FIRSTBOOT_TIMEOUT_SEC > 0 )); then
    if (( secret == 1 )); then
      if ! read -r -s -t "$FIRSTBOOT_TIMEOUT_SEC" -p "$prompt" value; then
        echo
        on_timeout
      fi
    else
      if ! read -r -t "$FIRSTBOOT_TIMEOUT_SEC" -p "$prompt" value; then
        on_timeout
      fi
    fi
  else
    if (( secret == 1 )); then
      read -r -s -p "$prompt" value
    else
      read -r -p "$prompt" value
    fi
  fi

  printf -v "$outvar" '%s' "$value"
}

prompt_username() {
  local input
  while true; do
    read_input "Enter new username: " input

    if [[ -z "$input" ]]; then
      echo "Username cannot be empty."
      continue
    fi

    if [[ ! "$input" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
      echo "Invalid username format. Use lowercase letters, digits, _, -, starting with a letter or _."
      continue
    fi

    printf '%s' "$input"
    return
  done
}

prompt_password() {
  local pass1 pass2
  while true; do
    read_input "Enter password: " pass1 1
    echo
    read_input "Confirm password: " pass2 1
    echo

    if [[ -z "$pass1" ]]; then
      echo "Password cannot be empty."
      continue
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi

    printf '%s' "$pass1"
    return
  done
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

prompt_collector_ip() {
  local ip
  while true; do
    read_input "Enter collector destination IPv4 address: " ip
    if valid_ipv4 "$ip"; then
      printf '%s' "$ip"
      return
    fi
    echo "Invalid IPv4 address."
  done
}

prompt_wlan_ipv4_cidr() {
  local cidr
  while true; do
    read_input "Enter ${WIFI_IFACE} IPv4 address/CIDR (e.g. 192.168.10.20/24): " cidr
    if valid_ipv4_cidr "$cidr"; then
      printf '%s' "$cidr"
      return
    fi
    echo "Invalid IPv4/CIDR format."
  done
}

prompt_wlan_gateway() {
  local gateway
  while true; do
    read_input "Enter ${WIFI_IFACE} IPv4 gateway (blank if none): " gateway
    if [[ -z "$gateway" ]] || valid_ipv4 "$gateway"; then
      printf '%s' "$gateway"
      return
    fi
    echo "Invalid IPv4 gateway."
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

apply_wlan_static_config() {
  local connection_name

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "nmcli not found; cannot configure ${WIFI_IFACE} IPv4 settings." >&2
    exit 1
  fi

  connection_name="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$WIFI_IFACE" '$2 == dev {print $1; exit}')"
  if [[ -z "$connection_name" ]]; then
    connection_name="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$WIFI_IFACE" '$2 == dev {print $1; exit}')"
  fi

  if [[ -z "$connection_name" ]]; then
    echo "No NetworkManager connection found for ${WIFI_IFACE}. Configure Wi-Fi first." >&2
    exit 1
  fi

  nmcli connection modify "$connection_name" ipv4.method manual ipv4.addresses "$WLAN_IPV4_CIDR"
  if [[ -n "$WLAN_IPV4_GATEWAY" ]]; then
    nmcli connection modify "$connection_name" ipv4.gateway "$WLAN_IPV4_GATEWAY"
  else
    nmcli connection modify "$connection_name" -ipv4.gateway
  fi

  nmcli connection up "$connection_name" ifname "$WIFI_IFACE" >/dev/null 2>&1 || nmcli connection up "$connection_name" >/dev/null
  echo "Configured ${WIFI_IFACE} IPv4 (${WLAN_IPV4_CIDR}) on NetworkManager connection '$connection_name'."
}

USERNAME="$(prompt_username)"
PASSWORD="$(prompt_password)"
COLLECTOR_IP="$(prompt_collector_ip)"
WLAN_IPV4_CIDR="$(prompt_wlan_ipv4_cidr)"
WLAN_IPV4_GATEWAY="$(prompt_wlan_gateway)"

if id "$USERNAME" >/dev/null 2>&1; then
  echo "User '$USERNAME' exists; updating password."
else
  useradd -m -G wheel "$USERNAME"
  echo "User '$USERNAME' created and added to wheel."
fi

printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
unset PASSWORD

if [[ ! -f "$ENV_FILE" ]]; then
  install -D -m 0644 /dev/null "$ENV_FILE"
fi

set_env_value "$ENV_FILE" "COLLECTOR_IP" "$COLLECTOR_IP"
set_env_value "$ENV_FILE" "WLAN_IPV4_CIDR" "$WLAN_IPV4_CIDR"
set_env_value "$ENV_FILE" "WLAN_IPV4_GATEWAY" "$WLAN_IPV4_GATEWAY"

apply_wlan_static_config

touch "$DONE_FILE"
chmod 0600 "$DONE_FILE"

echo
printf 'First-boot setup complete. Collector IP set to %s.\n' "$COLLECTOR_IP"
printf '%s IPv4 configured as %s.\n' "$WIFI_IFACE" "$WLAN_IPV4_CIDR"
printf 'Starting tap forward service...\n'

systemctl start atomtap-forward.service || true
