#!/usr/bin/env bash
# Debug script: Check WiFi status and collector IP

WIFI_IFACE="wlan0"
ENV_FILE="/etc/atomtap/forward.env"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

COLLECTOR_IP="${COLLECTOR_IP:-}"

echo "==== WiFi Interface ===="
ip addr show "$WIFI_IFACE"
echo
nmcli device status | grep "$WIFI_IFACE" || echo "$WIFI_IFACE not found in nmcli"
echo
nmcli -t -f ACTIVE,SSID dev wifi list ifname "$WIFI_IFACE" 2>/dev/null

echo "==== Collector IP ===="
echo "COLLECTOR_IP: $COLLECTOR_IP"

exit 0
