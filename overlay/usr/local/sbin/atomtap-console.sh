#!/usr/bin/env bash
# Runs as the getty replacement on tty1.
# On first boot: exec the setup script.
# On subsequent boots: exec the normal agetty login prompt.

TTY="${1:-tty1}"

if [[ ! -f /var/lib/atomtap/firstboot.done ]]; then
  # Suppress kernel and audit messages to the console so they don't
  # overwrite the whiptail UI. Level 1 = emergency only.
  dmesg -n 1 2>/dev/null || true
  TERM=linux /usr/local/sbin/atomtap-firstboot.sh || true

  if [[ -f /var/lib/atomtap/firstboot.done ]]; then
    # Setup completed. Trigger reboot and keep this process alive so
    # getty does not restart before systemd processes the reboot.
    # Trap signals so only a SIGKILL (sent at final shutdown) exits us.
    systemctl --no-block reboot 2>/dev/null || true
    trap '' TERM INT HUP
    while true; do sleep 5; done
  fi

  # Setup was cancelled or failed — fall through to re-exec agetty
  # so the user gets a login prompt (they can rerun setup manually).
fi

exec /usr/local/sbin/atomtap-status.sh
