# AtomTap-wifi v0.1.0-rc1

Release candidate introducing Raspberry Pi OT tap forwarding over Wi-Fi with mandatory first-boot setup gating.

## Highlights

- Adds passive Ethernet traffic mirroring from `eth0` using Linux `tc`.
- Encapsulates mirrored traffic into VXLAN and forwards over `wlan0`.
- Supports collector-side VXLAN termination workflow.
- Adds first-boot required setup for:
  - local username
  - local password
  - collector destination IP
- Blocks forwarding until first-boot setup is successfully completed.

## New runtime components

- `overlay/usr/local/sbin/atomtap-forward.sh`
- `overlay/usr/local/sbin/atomtap-firstboot.sh`
- `overlay/usr/lib/systemd/system/atomtap-forward.service`
- `overlay/usr/lib/systemd/system/atomtap-firstboot-setup.service`
- `overlay/etc/atomtap/forward.env`
- `overlay/etc/atomtap/firstboot.env`
- `overlay/usr/lib/tmpfiles.d/atomtap.conf`

## Operational behavior

- First boot requires interactive setup on console (`/dev/console`).
- Boot banner is displayed before prompts.
- `atomtap-forward.service` is gated by `/var/lib/atomtap/firstboot.done`.
- Optional unattended timeout/fallback is supported via `FIRSTBOOT_TIMEOUT_SEC` and `FIRSTBOOT_ON_TIMEOUT`.

## Validation guidance

- Confirm service state and mirror config:
  - `systemctl status atomtap-forward.service`
  - `/usr/local/sbin/atomtap-forward.sh status`
- Confirm VXLAN transport on Pi:
  - `tcpdump -ni wlan0 udp port 4789`
- Confirm VXLAN decode on collector (Wireshark/tshark guidance in README).

## Known scope for this RC

- Documentation includes build integration guidance and operator runbook checks.
- Overlay injection is left build-pipeline agnostic by design.

## Tag / commit

- Tag: `v0.1.0-rc1`
- Base commit: `5115c7e`
