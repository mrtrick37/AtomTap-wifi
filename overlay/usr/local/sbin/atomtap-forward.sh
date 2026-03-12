#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
TUNNEL_IFACE="atomtap-erspan"
ERSPAN_ID="${ERSPAN_ID:-1}"
ERSPAN_VER="${ERSPAN_VER:-2}"

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

  # ERSPAN routing requires the WiFi interface to have an IP address.
  # Exit with failure so the service retries until WiFi is connected.
  local local_ip
  local_ip=$(ip -4 addr show "$WIFI_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
  if [[ -z "$local_ip" ]]; then
    echo "$WIFI_IFACE has no IPv4 address yet — will retry" >&2
    exit 1
  fi

  ip link set "$ETH_IFACE" promisc on up

  # Force collector traffic out wlan0, regardless of the default route.
  # Without this, ERSPAN GRE packets follow the default route which may be eth0.
  local gw
  gw=$(ip route show default dev "$WIFI_IFACE" | awk '{print $3; exit}')
  if [[ -n "$gw" ]]; then
    ip route replace "$COLLECTOR_IP" via "$gw" dev "$WIFI_IFACE"
  else
    ip route replace "$COLLECTOR_IP" dev "$WIFI_IFACE"
  fi

  # Create an ERSPAN tunnel to the Defender for IoT sensor.
  # The sensor decapsulates ERSPAN (GRE) and sees the original Ethernet frames.
  if ! ip link show "$TUNNEL_IFACE" >/dev/null 2>&1; then
    ip link add "$TUNNEL_IFACE" type erspan \
      local "$local_ip" \
      remote "$COLLECTOR_IP" \
      seq \
      key "$ERSPAN_ID" \
      erspan_ver "$ERSPAN_VER" \
      erspan "$ERSPAN_ID"
  fi
  ip link set "$TUNNEL_IFACE" up

  # Mirror all eth0 ingress and egress to the ERSPAN tunnel.
  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  tc qdisc add dev "$ETH_IFACE" clsact

  tc filter add dev "$ETH_IFACE" ingress protocol all pref 10 matchall \
    action mirred egress mirror dev "$TUNNEL_IFACE"

  tc filter add dev "$ETH_IFACE" egress protocol all pref 10 matchall \
    action mirred egress mirror dev "$TUNNEL_IFACE"

  echo "AtomTap: mirroring $ETH_IFACE → ERSPAN Type ${ERSPAN_VER} → $COLLECTOR_IP (ID $ERSPAN_ID)"

  # Keep the process alive so systemd tracks it as running.
  exec sleep infinity
}

stop_tap() {
  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  ip link del "$TUNNEL_IFACE" 2>/dev/null || true
  ip link set "$ETH_IFACE" promisc off 2>/dev/null || true
  ip route del "$COLLECTOR_IP" 2>/dev/null || true
}

status_tap() {
  ip -d link show "$TUNNEL_IFACE" 2>/dev/null || echo "$TUNNEL_IFACE not present"
  tc filter show dev "$ETH_IFACE" ingress 2>/dev/null || true
  tc filter show dev "$ETH_IFACE" egress 2>/dev/null || true
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
