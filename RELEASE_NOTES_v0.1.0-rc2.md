# AtomTap-wifi v0.1.0-rc2

Release candidate 2 superseding `v0.1.0-rc1`.

## Delta from rc1

- First-boot setup now additionally requires Wi-Fi IPv4 configuration input:
  - `wlan0` IPv4 address/CIDR (required)
  - `wlan0` IPv4 gateway (optional)
- First-boot setup now applies static Wi-Fi IPv4 settings via NetworkManager (`nmcli`) before completion.
- Setup writes Wi-Fi IPv4 values into `/etc/atomtap/forward.env`:
  - `WLAN_IPV4_CIDR`
  - `WLAN_IPV4_GATEWAY`
- Console banner text updated to mention required Wi-Fi IPv4 configuration.
- README and first-boot validation checklist updated for the new requirement.

## Behavioral impact

- `atomtap-forward.service` remains blocked until first-boot setup is complete.
- First-boot completion now includes successful Wi-Fi IPv4 configuration on `wlan0`.

## Files changed for rc2

- `overlay/usr/local/sbin/atomtap-firstboot.sh`
- `overlay/usr/lib/systemd/system/atomtap-firstboot-setup.service`
- `overlay/etc/atomtap/forward.env`
- `README.md`

## Tag / commit

- Tag: `v0.1.0-rc2`
- Commit: _(set after tagging)_
