#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/forward.env
  source "$ENV_FILE"
fi

ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
COLLECTOR_IP="${COLLECTOR_IP:-}"
COLLECTOR_PORT="${COLLECTOR_PORT:-4789}"

require_collector_ip() {
  if [[ -z "$COLLECTOR_IP" ]]; then
    echo "COLLECTOR_IP is required in $ENV_FILE" >&2
    exit 1
  fi
}

start_tap() {
  require_collector_ip

  # Need WiFi up with an IP so routing to the collector works.
  # Exit with failure so the service retries until WiFi is connected.
  if ! ip -4 addr show "$WIFI_IFACE" 2>/dev/null | grep -q 'inet '; then
    echo "$WIFI_IFACE has no IPv4 address yet — will retry" >&2
    exit 1
  fi

  ip link set "$ETH_IFACE" promisc on up

  # Stream a live pcap of all eth0 traffic to the collector over TCP.
  # -w -   write pcap format to stdout
  # -U     flush each packet immediately (no buffering)
  # bash /dev/tcp opens the TCP connection; exec replaces this shell with tcpdump.
  exec tcpdump -i "$ETH_IFACE" -w - -U 2>/dev/null \
    > /dev/tcp/"$COLLECTOR_IP"/"$COLLECTOR_PORT"
}

stop_tap() {
  ip link set "$ETH_IFACE" promisc off 2>/dev/null || true
}

status_tap() {
  ip link show "$ETH_IFACE" || true
}

case "${1:-start}" in
  start)   start_tap  ;;
  stop)    stop_tap   ;;
  restart) stop_tap; start_tap ;;
  status)  status_tap ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
