# AtomTap-wifi

Fedora IoT bootc image assets for a Raspberry Pi passive OT tap:

- `eth0` listens in promiscuous mode (typically connected to a SPAN/mirror port)
- packets from `eth0` are mirrored into a VXLAN stream
- VXLAN is sent out `wlan0` to a remote collector IP

## Added overlay files

- `overlay/usr/local/sbin/atomtap-forward.sh`
- `overlay/usr/local/sbin/atomtap-firstboot.sh`
- `overlay/usr/lib/systemd/system/atomtap-forward.service`
- `overlay/usr/lib/systemd/system/atomtap-firstboot-setup.service`
- `overlay/etc/atomtap/forward.env`
- `overlay/etc/atomtap/firstboot.env`
- `overlay/usr/lib/tmpfiles.d/atomtap.conf`

## How it works

The service configures Linux `tc` filters on both ingress and egress of `eth0`,
then mirrors those packets to a local VXLAN interface (`atomtap-vxlan`).
That VXLAN interface encapsulates mirrored traffic and sends it over `wlan0`
to `COLLECTOR_IP`.

## Build integration

During your image build, copy the `overlay/` tree into the image root (`/`).
This project is intentionally kept generic because different Fedora bootc
pipelines inject overlays differently.

At minimum, ensure these files land in the final image:

- `/usr/local/sbin/atomtap-forward.sh` (executable)
- `/usr/lib/systemd/system/atomtap-forward.service`
- `/etc/atomtap/forward.env`

## Raw image build (Raspberry Pi)

Use the helper script:

```bash
sudo bash scripts/build-rpi-raw.sh
```

Behavior:

- builds `localhost/atomtap-rpi:rc2`
- generates a raw disk image under `scripts/output/` by default
- defaults to `ROOTFS=btrfs`
- if `btrfs` build fails on your host, it automatically retries with `ext4`

Optional environment controls:

```bash
ROOTFS=btrfs ALLOW_EXT4_FALLBACK=0 sudo bash scripts/build-rpi-raw.sh
```

- `ROOTFS` (default `btrfs`): requested root filesystem type for image build
- `ALLOW_EXT4_FALLBACK` (default `1`): when `ROOTFS=btrfs`, retry with `ext4` if btrfs build fails

## Runtime configuration on the Pi

1. Configure Wi-Fi so `wlan0` has connectivity to your collector.
2. On first boot, the system **requires interactive setup** on console (`/dev/console`):
	- username
	- password
	- collector destination IP (`COLLECTOR_IP`)
	- Wi-Fi IPv4 address/CIDR for `wlan0` (required)
	- Wi-Fi IPv4 gateway (optional)
3. After setup completes, `atomtap-forward.service` starts automatically.
4. Verify status:

	```bash
	sudo systemctl status atomtap-forward.service
	sudo /usr/local/sbin/atomtap-forward.sh status
	```

## Collector expectation

Your collector must terminate VXLAN with the same `VXLAN_ID` and `VXLAN_PORT`
and capture traffic from that VXLAN interface.

## First-boot requirement behavior

- `atomtap-firstboot-setup.service` runs before `multi-user.target`
- console banner shown at boot:
	- `AtomTap setup required: complete username/password/collector IP on console to continue.`
- `Wi-Fi IPv4 address/CIDR is also required and will be applied to wlan0 via NetworkManager.`
- it prompts for username, password, destination IP, and `wlan0` IPv4 configuration
- it creates/updates the user account and writes config values to `/etc/atomtap/forward.env`
- it applies static IPv4 configuration to `wlan0` via NetworkManager
- it writes `/var/lib/atomtap/firstboot.done`
- `atomtap-forward.service` is gated by that file and will not run before setup is complete

If setup is interrupted, reboot and complete the prompts; forwarding remains blocked until done.

### Expected boot sequence

1. Boot reaches first-boot setup service.
2. Console banner is displayed.
3. Prompts require username, password, and collector destination IP.
4. Prompts require `wlan0` IPv4 address/CIDR (and optional gateway).
5. Setup applies `wlan0` IPv4 config and writes `/var/lib/atomtap/firstboot.done`.
6. Forwarding service starts and configures VXLAN + `tc` mirror rules.

## Optional headless timeout / fallback mode

Configure `/etc/atomtap/firstboot.env`:

- `FIRSTBOOT_TIMEOUT_SEC=0` (default): wait forever for console input
- `FIRSTBOOT_TIMEOUT_SEC>0`: fail if no input is provided within timeout
- `FIRSTBOOT_ON_TIMEOUT`:
	- `reboot` (recommended for unattended devices)
	- `poweroff`
	- `fail`

Example unattended-safe setting:

```bash
FIRSTBOOT_TIMEOUT_SEC=300
FIRSTBOOT_ON_TIMEOUT=reboot
```

With this configuration, the device reboots if setup is not completed within
5 minutes, and tap forwarding remains blocked until successful setup.

## Collector-side Linux example

On the collector host (Linux), create a matching VXLAN interface and capture
encapsulated mirrored traffic.

1. Replace values with your collector uplink interface and Pi Wi-Fi source IP.
2. Run:

	 ```bash
	 sudo ip link add atomtap-vxlan type vxlan \
		 id 4096 \
		 dev eth0 \
		 local 192.168.10.50 \
		 remote 192.168.10.20 \
		 dstport 4789 \
		 nolearning

	 sudo ip link set atomtap-vxlan up
	 sudo tcpdump -ni atomtap-vxlan -vv
	 ```

Where:

- `local` = collector IP on the network receiving Wi-Fi traffic
- `remote` = Raspberry Pi `wlan0` IP
- `id` and `dstport` must match `/etc/atomtap/forward.env`

If you need to remove it:

```bash
sudo ip link del atomtap-vxlan
```

## Wireshark / tshark quick checks

On the collector, if packets arrive on UDP `4789` but you do not see inner OT
frames, force VXLAN decoding.

### Wireshark

1. Capture on your collector uplink interface (or on `atomtap-vxlan`).
2. If needed, use **Analyze > Decode As...**
	- Transport: `UDP`
	- Port: `4789`
	- Decode As: `VXLAN`
3. Useful display filters:
	- `udp.port == 4789`
	- `vxlan`
	- `eth && vxlan`

### tshark

```bash
sudo tshark -i eth0 -f "udp port 4789" -d udp.port==4789,vxlan -V
```

If decoding still fails, verify `VXLAN_ID`/`VXLAN_PORT` on the Pi and collector
match exactly, and confirm the collector firewall allows inbound UDP `4789`.

## First-boot validation checklist (Raspberry Pi)

Run these on the Pi after first boot:

1. Confirm interfaces are present:

	```bash
	ip -br link show eth0 wlan0
	```

2. Confirm Wi-Fi has an IP address and route:

	```bash
	ip -4 addr show wlan0
	ip route
	```

3. Confirm tap config has collector IP set:

	```bash
	grep -E '^(ETH_IFACE|WIFI_IFACE|COLLECTOR_IP|WLAN_IPV4_CIDR|WLAN_IPV4_GATEWAY|VXLAN_ID|VXLAN_PORT)=' /etc/atomtap/forward.env
	```

4. Confirm `wlan0` got the configured address:

	```bash
	ip -4 addr show wlan0
	nmcli -f NAME,DEVICE,IP4.ADDRESS,IP4.GATEWAY connection show --active
	```

5. Confirm service is active:

	```bash
	sudo systemctl is-enabled atomtap-forward.service
	sudo systemctl status atomtap-forward.service --no-pager
	```

6. Confirm mirror filters and VXLAN interface exist:

	```bash
	sudo /usr/local/sbin/atomtap-forward.sh status
	```

7. Optional live check from Pi while traffic exists on `eth0`:

	```bash
	sudo tcpdump -ni wlan0 udp port 4789
	```

Expected outcome: service is active, `atomtap-vxlan` exists, `tc` ingress/egress
filters are present on `eth0`, and UDP `4789` packets are visible on `wlan0`.