#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
FIRSTBOOT_ENV_FILE="/etc/atomtap/firstboot.env"
STATE_DIR="/var/lib/atomtap"
DONE_FILE="${STATE_DIR}/firstboot.done"
TTY_DEV="/dev/console"

FIRSTBOOT_TIMEOUT_SEC=0
FIRSTBOOT_ON_TIMEOUT="reboot"

if [[ -f "$FIRSTBOOT_ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/firstboot.env
  source "$FIRSTBOOT_ENV_FILE"
fi

mkdir -p "$STATE_DIR"

if [[ -f "$DONE_FILE" ]]; then
  exit 0
fi

exec <"$TTY_DEV" >"$TTY_DEV" 2>"$TTY_DEV"

echo
printf '=== AtomTap First-Boot Setup ===\n'
printf 'A local admin user and collector destination IP are required.\n\n'

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

USERNAME="$(prompt_username)"
PASSWORD="$(prompt_password)"
COLLECTOR_IP="$(prompt_collector_ip)"

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

if grep -q '^COLLECTOR_IP=' "$ENV_FILE"; then
  sed -i "s/^COLLECTOR_IP=.*/COLLECTOR_IP=${COLLECTOR_IP}/" "$ENV_FILE"
else
  printf '\nCOLLECTOR_IP=%s\n' "$COLLECTOR_IP" >> "$ENV_FILE"
fi

touch "$DONE_FILE"
chmod 0600 "$DONE_FILE"

echo
printf 'First-boot setup complete. Collector IP set to %s.\n' "$COLLECTOR_IP"
printf 'Starting tap forward service...\n'

systemctl start atomtap-forward.service || true
