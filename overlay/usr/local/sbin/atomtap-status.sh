#!/usr/bin/env bash
# AtomTap status display.
# Runs on tty1 after first-boot setup. Refreshes every few seconds.

ENV_FILE="/etc/atomtap/forward.env"
REFRESH_SEC=3

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
COLLECTOR_IP="${COLLECTOR_IP:-not configured}"
VXLAN_ID="${VXLAN_ID:-4096}"
VXLAN_PORT="${VXLAN_PORT:-4789}"

# Hide cursor; restore on exit
tput civis 2>/dev/null || true
trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM

# Read a single field from /proc/net/dev by column index (awk field number)
iface_stat() {
  local iface="$1" col="$2"
  awk -v i="${iface}:" -v c="$col" '$1==i{print $c+0; exit}' /proc/net/dev 2>/dev/null || echo 0
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

fwd_status() {
  systemctl is-active --quiet atomtap-forward.service 2>/dev/null \
    && echo "● ACTIVE" || echo "○ inactive"
}

# Box layout: 56 chars of content, 1 space each side = 58 inner, 60 total with borders
W=56
SEP=$(printf '═%.0s' $(seq 1 58))
TOP="╔${SEP}╗"
MID="╠${SEP}╣"
BOT="╚${SEP}╝"

row() { printf "║ %-${W}s ║\n" "$1"; }

tput clear 2>/dev/null || clear

while true; do
  tput cup 0 0 2>/dev/null || true

  # /proc/net/dev columns: $1=iface $2=rx_bytes $3=rx_pkts ... $10=tx_bytes $11=tx_pkts
  eth_rx_b=$(iface_stat "$ETH_IFACE"  2)
  eth_rx_p=$(iface_stat "$ETH_IFACE"  3)
  wifi_tx_b=$(iface_stat "$WIFI_IFACE" 10)
  wifi_tx_p=$(iface_stat "$WIFI_IFACE" 11)
  eth_st=$(iface_state "$ETH_IFACE")
  wifi_st=$(iface_state "$WIFI_IFACE")
  fwd=$(fwd_status)

  echo "$TOP"
  row "  AtomTap  —  Network Traffic Mirror"
  echo "$MID"
  row "  Status     $fwd"
  row "  Collector  $COLLECTOR_IP"
  row "  VXLAN      ID ${VXLAN_ID}  /  port ${VXLAN_PORT}"
  echo "$MID"
  row "  ${ETH_IFACE}  [${eth_st}]  —  tap input"
  row "    RX  $(fmt_bytes "$eth_rx_b")   ${eth_rx_p} packets"
  echo "$MID"
  row "  ${WIFI_IFACE}  [${wifi_st}]  —  uplink to collector"
  row "    TX  $(fmt_bytes "$wifi_tx_b")   ${wifi_tx_p} packets"
  echo "$MID"
  row "  $(date '+%Y-%m-%d %H:%M:%S')  —  refreshing every ${REFRESH_SEC}s"
  echo "$BOT"

  sleep "$REFRESH_SEC"
done
