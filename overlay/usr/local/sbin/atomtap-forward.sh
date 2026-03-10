#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
VXLAN_IFACE="atomtap-vxlan"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/forward.env
  source "$ENV_FILE"
fi

ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
COLLECTOR_IP="${COLLECTOR_IP:-}"
VXLAN_ID="${VXLAN_ID:-4096}"
VXLAN_PORT="${VXLAN_PORT:-4789}"

require_collector_ip() {
  if [[ -z "$COLLECTOR_IP" ]]; then
    echo "COLLECTOR_IP is required in $ENV_FILE" >&2
    exit 1
  fi
}

start_tap() {
  require_collector_ip

  # VXLAN routing requires the WiFi interface to have an IP address.
  # Exit with failure so the service retries until WiFi is connected.
  if ! ip -4 addr show "$WIFI_IFACE" 2>/dev/null | grep -q 'inet '; then
    echo "$WIFI_IFACE has no IPv4 address yet — will retry" >&2
    exit 1
  fi

  ip link set "$ETH_IFACE" promisc on up

  if ! ip link show "$VXLAN_IFACE" >/dev/null 2>&1; then
    ip link add "$VXLAN_IFACE" type vxlan \
      id "$VXLAN_ID" \
      dev "$WIFI_IFACE" \
      remote "$COLLECTOR_IP" \
      dstport "$VXLAN_PORT" \
      nolearning
  fi

  ip link set "$VXLAN_IFACE" up

  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  tc qdisc add dev "$ETH_IFACE" clsact

  tc filter add dev "$ETH_IFACE" ingress protocol all pref 10 matchall \
    action mirred egress mirror dev "$VXLAN_IFACE"

  tc filter add dev "$ETH_IFACE" egress protocol all pref 10 matchall \
    action mirred egress mirror dev "$VXLAN_IFACE"
}

stop_tap() {
  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  ip link del "$VXLAN_IFACE" 2>/dev/null || true
  ip link set "$ETH_IFACE" promisc off 2>/dev/null || true
}

status_tap() {
  ip -d link show "$VXLAN_IFACE" || true
  tc filter show dev "$ETH_IFACE" ingress || true
  tc filter show dev "$ETH_IFACE" egress || true
}

case "${1:-start}" in
  start)
    start_tap
    ;;
  stop)
    stop_tap
    ;;
  restart)
    stop_tap
    start_tap
    ;;
  status)
    status_tap
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
