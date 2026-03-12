#!/usr/bin/env bash
# AtomTap status display — runs on tty1, refreshes every few seconds.

ENV_FILE="/etc/atomtap/forward.env"
REFRESH_SEC=1

# Ensure bash ${#string} counts characters, not bytes, so box padding
# calculations are correct for multi-byte UTF-8 chars (—, ●, ○, etc.)
export LC_ALL=C.UTF-8

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

ADMIN_USER="${ADMIN_USER:-atomtap}"
ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
COLLECTOR_IP="${COLLECTOR_IP:-not configured}"
ERSPAN_ID="${ERSPAN_ID:-1}"
ERSPAN_VER="${ERSPAN_VER:-2}"

# Suppress kernel/audit messages from overwriting the display
dmesg -n 1 2>/dev/null || true

# ── Terminal setup ──────────────────────────────────────────────────────────────
tput civis 2>/dev/null || true
trap 'tput cnorm 2>/dev/null || true; tput sgr0 2>/dev/null || true' EXIT INT TERM

R=$(tput sgr0    2>/dev/null || true)
BOLD=$(tput bold 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
WHITE=$(tput setaf 7 2>/dev/null || true)

# ── Data helpers ────────────────────────────────────────────────────────────────
iface_stat() {
  awk -v i="${1}:" -v c="$2" '$1==i{print $c+0; exit}' /proc/net/dev 2>/dev/null || echo 0
}

iface_state() {
  cat /sys/class/net/"$1"/operstate 2>/dev/null || echo "?"
}

fmt_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if   (( b >= 1073741824 )); then
    printf "%d.%d GiB" $((b / 1073741824)) $(( (b % 1073741824) * 10 / 1073741824 ))
  elif (( b >= 1048576 )); then
    printf "%d.%d MiB" $((b / 1048576)) $(( (b % 1048576) * 10 / 1048576 ))
  elif (( b >= 1024 )); then
    printf "%d.%d KiB" $((b / 1024)) $(( (b % 1024) * 10 / 1024 ))
  else
    printf "%d B" "$b"
  fi
}

# ── Box layout ──────────────────────────────────────────────────────────────────
CONTENT_W=52
_SEP=$(printf '═%.0s' $(seq 1 $(( CONTENT_W + 4 ))))
TOP_LINE="╔${_SEP}╗"
MID_LINE="╠${_SEP}╣"
BOT_LINE="╚${_SEP}╝"
BOX_W=$(( CONTENT_W + 6 ))
# TOP + title + MID + fwd + collector + MID + eth-hdr + eth-rx + eth-mac + MID + wifi-hdr + ssid + wifi-mac + wifi-tx + MID + time + BOT
BOX_H=19

_R=0
_C=0

_border() {
  tput cup "$_R" "$_C" 2>/dev/null || true
  printf '%s%s%s' "$CYAN" "$1" "$R"
  (( _R++ )) || true
}

_row() {
  local plain="$1" display="${2:-$1}"
  local pad=$(( CONTENT_W - ${#plain} ))
  (( pad < 0 )) && pad=0
  tput cup "$_R" "$_C" 2>/dev/null || true
  printf '%s║%s  %s%*s  %s║%s' "$CYAN" "$R" "$display" "$pad" "" "$CYAN" "$R"
  (( _R++ )) || true
}

# ── Reconfigure ─────────────────────────────────────────────────────────────────
do_reconfigure() {
  local username="$ADMIN_USER"

  # Show cursor for whiptail dialogs
  tput cnorm 2>/dev/null || true

  # Confirm intent
  if ! whiptail --title "AtomTap Reconfigure" \
      --yesno "Restart the setup wizard?\n\nThe current configuration will be replaced and the device will reboot." \
      10 62 2>/dev/tty; then
    tput civis 2>/dev/null || true
    tput clear 2>/dev/null || clear
    return
  fi

  # Prompt for password
  local password
  password=$(whiptail --title "AtomTap Reconfigure" \
    --passwordbox "Admin password for ${username}:" \
    10 62 3>&1 1>&2 2>&3) || {
    tput civis 2>/dev/null || true
    tput clear 2>/dev/null || clear
    return
  }

  # Verify password via PAM (pamtester supports yescrypt used by Fedora 44+)
  if ! printf '%s\n' "$password" | pamtester login "$username" authenticate 2>/dev/null; then
    whiptail --title "AtomTap Reconfigure" \
      --msgbox "Incorrect password." 8 40 2>/dev/tty || true
    tput civis 2>/dev/null || true
    tput clear 2>/dev/null || clear
    return
  fi

  # Authenticated — remove done file and re-run firstboot
  rm -f /var/lib/atomtap/firstboot.done
  dmesg -n 1 2>/dev/null || true
  tput clear 2>/dev/null || clear

  TERM=linux /usr/local/sbin/atomtap-firstboot.sh || true

  # If firstboot completed, trigger reboot and wait for SIGKILL
  if [[ -f /var/lib/atomtap/firstboot.done ]]; then
    systemctl --no-block reboot 2>/dev/null || true
    trap '' TERM INT HUP
    while true; do sleep 5; done
  fi

  # Firstboot cancelled or failed — return to status screen
  tput civis 2>/dev/null || true
  tput clear 2>/dev/null || clear
}

# ── Render ───────────────────────────────────────────────────────────────────────
render() {
  local term_rows term_cols
  term_rows=$(tput lines 2>/dev/null || echo 24)
  term_cols=$(tput cols  2>/dev/null || echo 80)

  _R=$(( (term_rows - BOX_H) / 2 ))
  _C=$(( (term_cols - BOX_W) / 2 ))
  (( _R < 0 )) && _R=0
  (( _C < 0 )) && _C=0

  # Collect interface stats
  local eth_rx_b eth_rx_p wifi_tx_b wifi_tx_p eth_st wifi_st wifi_conn eth_mac wifi_mac
  eth_rx_b=$(iface_stat "$ETH_IFACE"  2)
  eth_rx_p=$(iface_stat "$ETH_IFACE"  3)
  wifi_tx_b=$(iface_stat "$WIFI_IFACE" 10)
  wifi_tx_p=$(iface_stat "$WIFI_IFACE" 11)
  eth_st=$(iface_state "$ETH_IFACE")
  wifi_st=$(iface_state "$WIFI_IFACE")
  wifi_conn=$(nmcli -t -f ACTIVE,SSID dev wifi list ifname "$WIFI_IFACE" 2>/dev/null \
    | awk -F: '$1=="yes" {print $2; exit}')
  [[ -z "$wifi_conn" ]] && wifi_conn="—"
  eth_mac=$(cat /sys/class/net/"$ETH_IFACE"/address  2>/dev/null || echo "unknown")
  wifi_mac=$(cat /sys/class/net/"$WIFI_IFACE"/address 2>/dev/null || echo "unknown")

  # Forwarding status
  local fwd_plain fwd_display
  if systemctl is-active --quiet atomtap-forward.service 2>/dev/null; then
    fwd_plain="● ACTIVE"
    fwd_display="${GREEN}${BOLD}● ACTIVE${R}"
  else
    fwd_plain="○ INACTIVE"
    fwd_display="${RED}○ INACTIVE${R}"
  fi

  # Interface state with color
  local eth_st_d wifi_st_d
  case "$eth_st"  in up) eth_st_d="${GREEN}up${R}"  ;; down) eth_st_d="${RED}down${R}"  ;; *) eth_st_d="$eth_st"  ;; esac
  case "$wifi_st" in up) wifi_st_d="${GREEN}up${R}" ;; down) wifi_st_d="${RED}down${R}" ;; *) wifi_st_d="$wifi_st" ;; esac

  local wifi_ip
  wifi_ip=$(ip -4 addr show "$WIFI_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
  [[ -z "$wifi_ip" ]] && wifi_ip="—"

  local eth_rx_str wifi_tx_str now
  eth_rx_str="$(fmt_bytes "$eth_rx_b")   ${eth_rx_p} pkts"
  wifi_tx_str="$(fmt_bytes "$wifi_tx_b")   ${wifi_tx_p} pkts"
  now="$(date '+%Y-%m-%d  %H:%M:%S')"

  # ── Draw ─────────────────────────────────────────────────────────────────────
  _border "$TOP_LINE"

  _row "  AtomTap — Network Traffic Mirror" \
       "  ${BOLD}${WHITE}AtomTap${R}${WHITE} — Network Traffic Mirror${R}"

  _border "$MID_LINE"

  _row "  Forwarding    $fwd_plain" \
       "  ${WHITE}Forwarding    ${R}${fwd_display}"

  _row "  Protocol      GRE/ERSPAN Type $ERSPAN_VER (ID $ERSPAN_ID)" \
       "  ${WHITE}Protocol      ${R}${YELLOW}GRE/ERSPAN Type ${ERSPAN_VER} (ID ${ERSPAN_ID})${R}"

  _row "  Collector     $COLLECTOR_IP" \
       "  ${WHITE}Collector     ${R}${YELLOW}${COLLECTOR_IP}${R}"

  _border "$MID_LINE"

  _row "  $ETH_IFACE  [$eth_st]  —  tap input" \
       "  ${CYAN}${BOLD}${ETH_IFACE}${R}  [${eth_st_d}]  —  tap input"

  _row "    RX   $eth_rx_str" \
       "    ${WHITE}RX${R}   ${GREEN}${eth_rx_str}${R}"

  _row "    MAC  $eth_mac" \
       "    ${WHITE}MAC${R}  ${WHITE}${eth_mac}${R}"

  _border "$MID_LINE"

  _row "  $WIFI_IFACE  [$wifi_st]  —  uplink" \
       "  ${CYAN}${BOLD}${WIFI_IFACE}${R}  [${wifi_st_d}]  —  uplink"

  _row "    MAC   $wifi_mac" \
       "    ${WHITE}MAC${R}   ${WHITE}${wifi_mac}${R}"

  _row "    SSID  $wifi_conn" \
       "    ${WHITE}SSID${R}  ${YELLOW}${wifi_conn}${R}"

  _row "    IP    $wifi_ip" \
       "    ${WHITE}IP${R}    ${YELLOW}${wifi_ip}${R}"

  _row "    TX    $wifi_tx_str" \
       "    ${WHITE}TX${R}    ${GREEN}${wifi_tx_str}${R}"

  _border "$MID_LINE"

  _row "  $now" \
       "  ${WHITE}${now}${R}"

  _border "$BOT_LINE"

  # Hint line centered below the box
  local hint="[ R ] Reconfigure"
  local hint_col=$(( _C + (BOX_W - ${#hint}) / 2 ))
  tput cup "$_R" "$hint_col" 2>/dev/null || true
  printf '%s%s%s' "$WHITE" "$hint" "$R"

  # Park cursor out of the way
  tput cup $(( _R + 2 )) 0 2>/dev/null || true
}

# ── Main loop ────────────────────────────────────────────────────────────────────
tput clear 2>/dev/null || clear

_key=""
while true; do
  render
  # Wait for a keypress up to REFRESH_SEC; timeout is normal
  if read -r -s -n 1 -t "$REFRESH_SEC" _key 2>/dev/null; then
    case "${_key,,}" in
      r) do_reconfigure ;;
    esac
  fi
done
