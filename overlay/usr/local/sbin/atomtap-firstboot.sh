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

# ── UI layer ───────────────────────────────────────────────────────────────────
#
# All dialog output is captured via a tmpfile so whiptail always runs in the
# current shell process with full terminal access.  No command substitution
# is used to collect dialog results, which eliminates the subshell/tty-buffer
# timing problems that caused menus to be silently auto-dismissed.

UI_TOOL=""
_UI_TMPFILE=""

ensure_ui_tool() {
  if command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
  else
    echo "ERROR: Neither whiptail nor dialog found." >&2
    exit 1
  fi
  _UI_TMPFILE="$(mktemp)"
  trap 'rm -f "$_UI_TMPFILE"' EXIT
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

# drain_tty: consume all pending bytes from the tty input buffer.
# Reads single chars with a short timeout until nothing is left.
# This prevents buffered keypresses from previous dialogs auto-dismissing
# the next one.
drain_tty() {
  local _c
  while IFS= read -r -s -n 1 -t 0.05 _c </dev/tty 2>/dev/null; do :; done
}

# run_dialog: drain tty, then run a dialog command.
# Output (the user's selection) is written to _UI_TMPFILE via stderr redirect.
# Returns the dialog's exit code (1 = cancel/ESC, 0 = confirmed).
run_dialog() {
  local _rc
  : > "$_UI_TMPFILE"
  drain_tty
  if (( FIRSTBOOT_TIMEOUT_SEC > 0 )); then
    timeout --foreground "${FIRSTBOOT_TIMEOUT_SEC}" \
      "$UI_TOOL" "$@" 2>"$_UI_TMPFILE" && _rc=0 || _rc=$?
    (( _rc == 124 )) && on_timeout
  else
    "$UI_TOOL" "$@" 2>"$_UI_TMPFILE" && _rc=0 || _rc=$?
  fi
  return "$_rc"
}

# ui_msg: display a message box (no output capture needed).
ui_msg() {
  drain_tty
  "$UI_TOOL" --title "$SETUP_TITLE" --msgbox "$1" 12 78 2>/dev/null || true
}

# ui_input PROMPT DEFAULT OUTVAR
ui_input() {
  local _prompt="$1" _default="$2" _outvar="$3"
  run_dialog --title "$SETUP_TITLE" --inputbox "$_prompt" 12 78 "$_default" || return 1
  printf -v "$_outvar" '%s' "$(< "$_UI_TMPFILE")"
}

# ui_password PROMPT OUTVAR
ui_password() {
  local _prompt="$1" _outvar="$2"
  run_dialog --title "$SETUP_TITLE" --passwordbox "$_prompt" 12 78 || return 1
  printf -v "$_outvar" '%s' "$(< "$_UI_TMPFILE")"
}

# ui_menu PROMPT DEFAULT OUTVAR HEIGHT LIST_HEIGHT [ITEM DESC]...
ui_menu() {
  local _prompt="$1" _default="$2" _outvar="$3" _h="$4" _lh="$5"
  shift 5
  run_dialog --title "$SETUP_TITLE" --default-item "$_default" \
    --menu "$_prompt" "$_h" 78 "$_lh" "$@" || return 1
  printf -v "$_outvar" '%s' "$(< "$_UI_TMPFILE")"
}

# ui_yesno TEXT  — returns 0 for Yes, 1 for No/ESC
ui_yesno() {
  drain_tty
  "$UI_TOOL" --title "$SETUP_TITLE" --yesno "$1" 16 78 2>/dev/null
}

# ── Prompts ────────────────────────────────────────────────────────────────────

# prompt_username OUTVAR
prompt_username() {
  local -n _u_out="$1"
  local val="${_u_out:-$DEFAULT_ADMIN_USER}"
  while true; do
    ui_input "Admin username" "$val" val || return 1
    [[ -z "$val" ]] && { ui_msg "Username cannot be empty."; continue; }
    [[ ! "$val" =~ ^[a-z_][a-z0-9_-]*$ ]] && {
      ui_msg "Invalid username.\n\nUse lowercase letters, digits, _ or -, starting with a letter or _."
      continue
    }
    _u_out="$val"
    return 0
  done
}

# prompt_password LABEL OUTVAR
prompt_password() {
  local label="$1"
  local -n _pw_out="$2"
  local p1 p2
  while true; do
    ui_password "Password for $label" p1 || return 1
    [[ -z "$p1" ]] && { ui_msg "Password cannot be empty."; continue; }
    ui_password "Confirm password for $label" p2 || return 1
    [[ "$p1" != "$p2" ]] && { ui_msg "Passwords do not match. Try again."; continue; }
    _pw_out="$p1"
    return 0
  done
}

# scan_ssids OUTVAR
# Populates the named variable with newline-separated SSIDs.
# Runs in the current shell so infobox/msgbox display correctly.
#
# Uses iw dev scan directly — this talks to the driver without requiring
# NetworkManager to be managing the interface, which avoids all NM
# initialization race conditions during firstboot.  NM is only used as a
# last-resort fallback.
#
# Bring-up sequence:
#   1. Unblock rfkill
#   2. Load brcmfmac and wait for the interface
#   3. Set regulatory domain (wireless-regdb must be installed)
#   4. Bring interface UP (no NM involvement)
#   5. Scan with iw dev scan (direct driver call)
#   6. Fall back to nmcli scan if iw returns nothing
scan_ssids() {
  local -n _ssids_out="$1"
  _ssids_out=""

  local LOG="/var/log/atomtap-wifi.log"

  "$UI_TOOL" --title "$SETUP_TITLE" \
    --infobox "Preparing Wi-Fi interface...\n\nPlease wait." 7 50 2>/dev/null || true

  # Everything is logged to $LOG so it can be read via SSH (eth0 is up)
  # or serial console if the scan fails.
  {
    echo "=== AtomTap Wi-Fi diagnostics: $(date) ==="
    echo "WIFI_IFACE=$WIFI_IFACE"
  } > "$LOG"

  # Step 1 — unblock radio.
  rfkill unblock wifi 2>/dev/null || true

  # Step 2 — load Broadcom SDIO modules.
  modprobe brcmutil 2>/dev/null || true
  modprobe brcmfmac 2>/dev/null || true

  # Wait up to 15 s for the kernel netdev to appear.
  local i
  for (( i = 0; i < 15; i++ )); do
    [[ -d "/sys/class/net/$WIFI_IFACE" ]] && break
    sleep 1
  done

  # Snapshot diagnostics before touching the interface further.
  local d_lsmod d_rfkill d_iface d_dmesg d_nm d_reg
  d_lsmod="$(lsmod | grep -i brcm 2>&1 || echo '(none)')"
  d_rfkill="$(rfkill list 2>&1 || echo '(none)')"
  d_iface="$(ip link show 2>&1)"
  d_dmesg="$(dmesg 2>/dev/null | grep -i 'brcm\|wlan\|wifi\|firmware\|sdio' | tail -20 || echo '(none)')"
  d_nm="$(nmcli device 2>&1 || echo '(none)')"
  d_reg="$(iw reg get 2>&1 || echo '(unavailable)')"

  {
    echo ""
    printf '--- brcm modules ---\n%s\n' "$d_lsmod"
    printf '--- rfkill ---\n%s\n' "$d_rfkill"
    printf '--- ip link ---\n%s\n' "$d_iface"
    printf '--- dmesg (wifi/sdio/firmware) ---\n%s\n' "$d_dmesg"
    printf '--- nmcli device ---\n%s\n' "$d_nm"
    printf '--- regulatory domain ---\n%s\n' "$d_reg"
  } >> "$LOG"

  if [[ ! -d "/sys/class/net/$WIFI_IFACE" ]]; then
    echo "RESULT: interface not found" >> "$LOG"
    ui_msg "ERROR: $WIFI_IFACE did not appear.\n\nbrcmfmac modules:\n${d_lsmod}\n\nrfkill:\n${d_rfkill}\n\nFull log: $LOG\n(SSH to this device on eth0 to read it)"
    return 0
  fi

  # Step 3 — tell NM to stop managing wlan0 BEFORE we touch it.
  # NM automatically starts wpa_supplicant on any interface it detects.
  # If wpa_supplicant is already running, iw dev scan returns EBUSY.
  nmcli device set "$WIFI_IFACE" managed no 2>/dev/null || true
  pkill -f "wpa_supplicant.*$WIFI_IFACE" 2>/dev/null || true
  sleep 1

  # Step 4 — set regulatory domain and bring the interface UP.
  iw reg set US 2>/dev/null || true
  ip link set "$WIFI_IFACE" up 2>/dev/null || true
  sleep 1

  local iface_state
  iface_state="$(cat "/sys/class/net/$WIFI_IFACE/operstate" 2>/dev/null || echo 'unknown')"
  {
    echo ""
    printf '--- post-up state ---\noperstate: %s\n%s\n' \
      "$iface_state" "$(ip link show "$WIFI_IFACE" 2>&1)"
  } >> "$LOG"

  "$UI_TOOL" --title "$SETUP_TITLE" \
    --infobox "$WIFI_IFACE is up (${iface_state})\n\nScanning for Wi-Fi networks...\n\nThis may take up to 10 seconds." 8 50 2>/dev/null || true

  # Step 5 — scan directly with iw (no NM, no wpa_supplicant needed).
  # Capture stderr separately so we can log EBUSY or other errors.
  local raw scan_err
  raw="$(iw dev "$WIFI_IFACE" scan 2>/tmp/atomtap-iw-err \
    | grep $'^\tSSID: ' \
    | sed $'s/^\tSSID: //' \
    | grep -v '^$' \
    | sort -u || true)"
  scan_err="$(cat /tmp/atomtap-iw-err 2>/dev/null)"

  {
    printf '--- iw dev scan stderr ---\n%s\n' "${scan_err:-(none)}"
    printf '--- iw dev scan SSIDs ---\n%s\n' "${raw:-(empty)}"
  } >> "$LOG"

  # Retry with trigger+dump if first scan returned nothing.
  if [[ -z "$raw" ]]; then
    "$UI_TOOL" --title "$SETUP_TITLE" \
      --infobox "First scan empty — retrying...\n\nPlease wait." 6 50 2>/dev/null || true
    iw dev "$WIFI_IFACE" scan trigger 2>/dev/null || true
    sleep 5
    raw="$(iw dev "$WIFI_IFACE" scan dump 2>/dev/null \
      | grep $'^\tSSID: ' \
      | sed $'s/^\tSSID: //' \
      | grep -v '^$' \
      | sort -u || true)"
    printf '--- iw scan dump (retry) ---\n%s\n' "${raw:-(empty)}" >> "$LOG"
  fi

  # If iw scan is still empty, fall back to nmcli.
  if [[ -z "$raw" ]]; then
    "$UI_TOOL" --title "$SETUP_TITLE" \
      --infobox "Direct scan empty — trying NetworkManager..." 6 50 2>/dev/null || true

    for (( i = 0; i < 20; i++ )); do
      nmcli general status >/dev/null 2>&1 && break
      sleep 1
    done
    nmcli device set "$WIFI_IFACE" managed yes 2>/dev/null || true
    sleep 2
    nmcli device wifi rescan ifname "$WIFI_IFACE" 2>/dev/null || true
    sleep 4

    raw="$(nmcli -t -f SSID device wifi list ifname "$WIFI_IFACE" 2>/dev/null \
      | grep -v '^--$' | grep -v '^$' | sort -u || true)"
    printf '--- nmcli fallback SSIDs ---\n%s\n' "${raw:-(empty)}" >> "$LOG"
  fi

  if [[ -z "$raw" ]]; then
    echo "RESULT: no networks found" >> "$LOG"
    # Show a compact but readable failure box.
    # The full log at $LOG has everything needed to diagnose the issue.
    # SSH to eth0 (which is up) to read it: cat /var/log/atomtap-wifi.log
    local short_dmesg
    short_dmesg="$(dmesg 2>/dev/null | grep -i 'brcm\|sdio\|wlan' | tail -5 || echo '(none)')"
    ui_msg "No Wi-Fi networks found on $WIFI_IFACE.\n\nbrcmfmac:  ${d_lsmod:-(not loaded)}\nrfkill:    ${d_rfkill}\nState:     ${iface_state}\niw error:  ${scan_err:-(none)}\n\ndmesg (last 5 wifi lines):\n${short_dmesg}\n\nFull log saved to:\n  $LOG\nSSH to eth0 and run: cat $LOG"
  else
    echo "RESULT: found networks" >> "$LOG"
    echo "$raw" >> "$LOG"
  fi

  _ssids_out="$raw"
}

# prompt_ssid OUTVAR
prompt_ssid() {
  local -n _ssid_out="$1"
  local val="${_ssid_out:-}"
  local scanned selected item
  local -a ssid_list menu_args
  local OTHER="-- Enter manually --"

  scan_ssids scanned

  if [[ -n "$scanned" ]]; then
    readarray -t ssid_list <<< "$scanned"
    menu_args=()
    for item in "${ssid_list[@]}"; do
      menu_args+=("$item" " ")
    done
    menu_args+=("$OTHER" " ")

    selected="${val:-}"
    if ui_menu "Select Wi-Fi network" "$selected" selected 20 12 "${menu_args[@]}"; then
      if [[ -n "$selected" && "$selected" != "$OTHER" ]]; then
        _ssid_out="$selected"
        return 0
      fi
      # User chose "Enter manually" — clear val so inputbox starts blank
      [[ "$selected" == "$OTHER" ]] && val=""
    fi
    # ESC/cancel — fall through to manual entry
  fi

  # Manual entry (scan empty, ESC from menu, or "Enter manually" chosen)
  while true; do
    ui_input "Wi-Fi SSID" "$val" val || return 1
    [[ -n "$val" ]] && { _ssid_out="$val"; return 0; }
    ui_msg "SSID cannot be empty."
  done
}

# prompt_psk OUTVAR
prompt_psk() {
  local -n _psk_out="$1"
  local p1 p2
  while true; do
    ui_password "Wi-Fi passphrase" p1 || return 1
    [[ -z "$p1" ]] && { ui_msg "Passphrase cannot be empty."; continue; }
    ui_password "Confirm Wi-Fi passphrase" p2 || return 1
    [[ "$p1" != "$p2" ]] && { ui_msg "Passphrases do not match. Try again."; continue; }
    _psk_out="$p1"
    return 0
  done
}

# prompt_collector_ip OUTVAR
prompt_collector_ip() {
  local -n _cip_out="$1"
  local val="${_cip_out:-}"
  while true; do
    ui_input "Collector IPv4 address (traffic forwarding destination)" "$val" val || return 1
    valid_ipv4 "$val" && { _cip_out="$val"; return 0; }
    ui_msg "'$val' is not a valid IPv4 address."
  done
}

# prompt_ipv4_mode OUTVAR
prompt_ipv4_mode() {
  local -n _mode_out="$1"
  local val="${_mode_out:-dhcp}"
  ui_menu "Wi-Fi IPv4 mode for $WIFI_IFACE" "$val" val 12 2 \
    "dhcp"   "Obtain address automatically (DHCP)" \
    "static" "Use a static IP address" || return 1
  _mode_out="$val"
}

# prompt_static_ip OUTVAR
prompt_static_ip() {
  local -n _sip_out="$1"
  local val="${_sip_out:-}"
  while true; do
    ui_input "$WIFI_IFACE static IPv4 address" "$val" val || return 1
    valid_ipv4 "$val" && { _sip_out="$val"; return 0; }
    ui_msg "'$val' is not a valid IPv4 address."
  done
}

# prompt_subnet OUTVAR
prompt_subnet() {
  local -n _sub_out="$1"
  local val="${_sub_out:-}"
  while true; do
    ui_input "$WIFI_IFACE subnet mask  (e.g. 255.255.255.0)" "$val" val || return 1
    subnet_mask_to_prefix "$val" >/dev/null 2>&1 && { _sub_out="$val"; return 0; }
    ui_msg "'$val' is not a valid subnet mask."
  done
}

# prompt_gateway OUTVAR
prompt_gateway() {
  local -n _gw_out="$1"
  local val="${_gw_out:-}"
  while true; do
    ui_input "$WIFI_IFACE default gateway" "$val" val || return 1
    valid_ipv4 "$val" && { _gw_out="$val"; return 0; }
    ui_msg "'$val' is not a valid IPv4 address."
  done
}

# ── Apply settings ─────────────────────────────────────────────────────────────

set_env_value() {
  local file="$1" key="$2" value="$3"
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
  # Hand the interface to NM now.  During the scan phase we kept NM out of
  # the picture; now we need NM to own the interface so it can persist and
  # autoconnect the profile on every subsequent boot.
  nmcli device set "$WIFI_IFACE" managed yes 2>/dev/null || true

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

# Collect inputs — all run in the current shell, no command substitution,
# so whiptail has unambiguous terminal ownership at every step.
ADMIN_USER="$DEFAULT_ADMIN_USER"
prompt_username ADMIN_USER || exit 1

ADMIN_PASS=""
prompt_password "$ADMIN_USER" ADMIN_PASS || exit 1

WLAN_SSID="${WLAN_SSID:-}"
prompt_ssid WLAN_SSID || exit 1

WLAN_PSK=""
prompt_psk WLAN_PSK || exit 1

COLLECTOR_IP="${COLLECTOR_IP:-}"
prompt_collector_ip COLLECTOR_IP || exit 1

WLAN_IPV4_MODE="${WLAN_IPV4_MODE:-dhcp}"
prompt_ipv4_mode WLAN_IPV4_MODE || exit 1

WLAN_IPV4_ADDRESS="${WLAN_IPV4_ADDRESS:-}"
WLAN_IPV4_SUBNET="${WLAN_IPV4_SUBNET:-}"
WLAN_IPV4_CIDR="${WLAN_IPV4_CIDR:-}"
WLAN_IPV4_GATEWAY="${WLAN_IPV4_GATEWAY:-}"

if [[ "$WLAN_IPV4_MODE" == "static" ]]; then
  prompt_static_ip WLAN_IPV4_ADDRESS || exit 1
  prompt_subnet WLAN_IPV4_SUBNET || exit 1
  prompt_gateway WLAN_IPV4_GATEWAY || exit 1
  _prefix="$(subnet_mask_to_prefix "$WLAN_IPV4_SUBNET")"
  WLAN_IPV4_CIDR="${WLAN_IPV4_ADDRESS}/${_prefix}"
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
