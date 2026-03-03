# AtomTap-wifi v0.1.0-rc3

Release candidate 3 superseding `v0.1.0-rc2`.

## Delta from rc2

- First-boot input flow moved to a curses UI (`whiptail`/`dialog`) instead of raw line prompts.
- First-boot now prompts for:
  - admin username
  - admin password
  - Wi-Fi SSID
  - Wi-Fi PSK
  - collector destination IP (`COLLECTOR_IP`)
  - WLAN IPv4 mode (`dhcp` or `static`)
  - if `static`: IPv4 address, subnet mask, gateway
- Static subnet mask is validated and converted to CIDR prefix before applying config.
- Wi-Fi profile is created/updated in NetworkManager and configured with SSID/PSK + DHCP/static IPv4 settings.
- Setup completion behavior remains gated and now ends with reboot after successful apply.

## Console and boot behavior updates

- First-boot service now attaches to active console (`/dev/console`) for better serial-console compatibility.
- Added boot-time guidance banner messages in first-boot service output.
- Forwarding remains blocked until `/var/lib/atomtap/firstboot.done` is written.

## Configuration model changes

`/etc/atomtap/forward.env` now includes first-boot managed WLAN keys:

- `WLAN_SSID`
- `WLAN_PSK`
- `WLAN_IPV4_MODE`
- `WLAN_IPV4_ADDRESS`
- `WLAN_IPV4_SUBNET`
- `WLAN_IPV4_CIDR`
- `WLAN_IPV4_GATEWAY`
- `COLLECTOR_IP`

## Packaging and overlay updates

- Added `newt` package to ensure `whiptail` availability in the image.
- Replaced prior tmpfiles-based systemd enablement with explicit overlay symlinks under:
  - `overlay/etc/systemd/system/multi-user.target.wants/`

## Files changed for rc3

- `overlay/usr/local/sbin/atomtap-firstboot.sh`
- `overlay/usr/lib/systemd/system/atomtap-firstboot-setup.service`
- `overlay/etc/atomtap/forward.env`
- `overlay/etc/atomtap/firstboot.env`
- `overlay/etc/systemd/system/multi-user.target.wants/atomtap-firstboot-setup.service`
- `overlay/etc/systemd/system/multi-user.target.wants/atomtap-forward.service`
- `overlay/usr/lib/tmpfiles.d/atomtap.conf` (removed)
- `iot-packages.yaml`
- `README.md`

## Tag / commit

- Tag: `v0.1.0-rc3`
- Commit: `8a71992`
