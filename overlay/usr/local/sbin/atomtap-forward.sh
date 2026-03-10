#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
GRE_IFACE="atomtap-gre"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/forward.env
  source "$ENV_FILE"
fi

ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
COLLECTOR_IP="${COLLECTOR_IP:-}"

require_collector_ip() {
  if [[ -z "$COLLECTOR_IP" ]]; then
    echo "COLLECTOR_IP is required in $ENV_FILE" >&2
    exit 1
  fi
}

start_tap() {
  require_collector_ip

  # GRE routing requires the WiFi interface to have an IP address.
  # Exit with failure so the service retries until WiFi is connected.
  if ! ip -4 addr show "$WIFI_IFACE" 2>/dev/null | grep -q 'inet '; then
    echo "$WIFI_IFACE has no IPv4 address yet — will retry" >&2
    exit 1
  fi

  local wifi_ip
  wifi_ip="$(ip -4 addr show "$WIFI_IFACE" | awk '/inet / {split($2,a,"/"); print a[1]; exit}')"

  ip link set "$ETH_IFACE" promisc on up

  if ! ip link show "$GRE_IFACE" >/dev/null 2>&1; then
    ip tunnel add "$GRE_IFACE" mode gre \
      remote "$COLLECTOR_IP" \
      local "$wifi_ip" \
      dev "$WIFI_IFACE" \
      ttl 64
  fi

  ip link set "$GRE_IFACE" up

  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  tc qdisc add dev "$ETH_IFACE" clsact

  tc filter add dev "$ETH_IFACE" ingress protocol all pref 10 matchall \
    action mirred egress mirror dev "$GRE_IFACE"

  tc filter add dev "$ETH_IFACE" egress protocol all pref 10 matchall \
    action mirred egress mirror dev "$GRE_IFACE"
}

stop_tap() {
  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  ip link del "$GRE_IFACE" 2>/dev/null || true
  ip link set "$ETH_IFACE" promisc off 2>/dev/null || true
}

status_tap() {
  ip -d link show "$GRE_IFACE" || true
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
