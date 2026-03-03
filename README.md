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
- `overlay/etc/systemd/system/multi-user.target.wants/atomtap-forward.service`
- `overlay/etc/systemd/system/multi-user.target.wants/atomtap-firstboot-setup.service`

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
- installs Raspberry Pi native boot dependencies (`bcm283x-firmware`, `uboot-images-armv8`) into the image
- generates a raw disk image under `scripts/output/` by default
- uses `ext4` for root filesystem
- always minimizes `disk.raw` size after build by shrinking ext4 filesystems and truncating the image
- configures partition 1 as a Raspberry Pi native boot FAT with Pi firmware + `u-boot.bin` + `extlinux.conf`

Optional environment controls:

```bash
sudo bash scripts/build-rpi-raw.sh
```

```bash
ROOT_HEADROOM_MIB=256 BOOT_HEADROOM_MIB=64 sudo bash scripts/build-rpi-raw.sh
```

- `ROOT_HEADROOM_MIB` (default `256`): extra free space kept in root partition after minimization
- `BOOT_HEADROOM_MIB` (default `64`): extra free space kept in boot partition after minimization

Note: the script now performs post-build Pi-native boot setup by extracting `start4.elf`,
`fixup4.dat`, and `u-boot.bin` from the built deployment and writing boot config files
to the first FAT partition.

## Runtime configuration on the Pi

1. On first boot, the system **creates a default local admin** and opens a curses setup menu on the active console (`/dev/console`, e.g. `tty1` or serial):
	- admin username (defaults to `atomtap`)
	- admin password
	- Wi-Fi SSID
	- Wi-Fi PSK
	- collector destination IP (`COLLECTOR_IP`)
	- whether `wlan0` uses DHCP or static IPv4
	- if static: IPv4 address, subnet mask, and gateway
2. After setup completes, the device reboots automatically.
3. After reboot, `atomtap-forward.service` starts automatically.
4. Verify status:

	```bash
	sudo systemctl status atomtap-forward.service
	sudo /usr/local/sbin/atomtap-forward.sh status
	```

## Collector expectation

Your collector must terminate VXLAN with the same `VXLAN_ID` and `VXLAN_PORT`
and capture traffic from that VXLAN interface.

## First-boot requirement behavior

- `atomtap-firstboot-setup.service` runs on first boot in `multi-user.target` on the active console (`/dev/console`)
- service prints boot-time guidance to open the active console for setup
- it creates/updates the default admin user from `/etc/atomtap/firstboot.env`
- it opens a curses (`whiptail`/`dialog`) setup menu on the active console (`tty1` or serial)
- menu collects admin username/password, Wi-Fi SSID/PSK, collector IP, and DHCP/static selection for `wlan0`
- if static mode is selected, menu requires IPv4 address, subnet mask, and gateway
- it creates/updates the user account and writes config values to `/etc/atomtap/forward.env`
- it applies Wi-Fi credentials and DHCP/static IPv4 configuration to `wlan0` via NetworkManager
- it writes `/var/lib/atomtap/firstboot.done`
- `atomtap-forward.service` is gated by that file and will not run before setup is complete
- it reboots after successful setup

If setup is interrupted, reboot and complete the prompts; forwarding remains blocked until done.

### Expected boot sequence

1. Boot reaches first-boot setup service.
2. Default admin user is ensured from `/etc/atomtap/firstboot.env`.
3. Curses setup menu is displayed on the active console (`tty1` or serial).
4. Menu prompts for username, password, SSID, PSK, collector IP, and DHCP/static mode (`wlan0`).
5. If static is selected, menu requires IPv4 address, subnet mask, and gateway.
6. Setup applies `wlan0` config and writes `/var/lib/atomtap/firstboot.done`.
7. Device reboots.
8. Forwarding service starts and configures VXLAN + `tc` mirror rules.

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

Default bootstrap admin credentials (change as needed):

```bash
DEFAULT_ADMIN_USER=atomtap
DEFAULT_ADMIN_PASSWORD=atomtap
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

3. Confirm first-boot network config values are set:

	```bash
	grep -E '^(ETH_IFACE|WIFI_IFACE|COLLECTOR_IP|WLAN_SSID|WLAN_IPV4_MODE|WLAN_IPV4_ADDRESS|WLAN_IPV4_SUBNET|WLAN_IPV4_CIDR|WLAN_IPV4_GATEWAY|VXLAN_ID|VXLAN_PORT)=' /etc/atomtap/forward.env
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