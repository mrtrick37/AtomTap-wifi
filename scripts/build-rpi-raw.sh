#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="localhost/atomtap-rpi:rc2"
OCI_ARCHIVE="/tmp/atomtap-rpi-rc2.oci"
OUTPUT_DIR="${1:-$PWD/output}"

require_arm64_binfmt() {
  local host_arch
  host_arch="$(uname -m)"

  if [[ "$host_arch" == "aarch64" || "$host_arch" == "arm64" ]]; then
    return 0
  fi

  if [[ ! -r /proc/sys/fs/binfmt_misc/status ]] || [[ "$(< /proc/sys/fs/binfmt_misc/status)" != "enabled" ]]; then
    cat <<'EOF'
ERROR: ARM64 cross-build requested on a non-ARM host, but binfmt_misc is not enabled.

Install/register qemu user emulation, then retry:
  sudo dnf install -y qemu-user-static
  sudo systemctl restart systemd-binfmt
EOF
    exit 1
  fi

  if ! ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -Eq 'aarch64|arm64|qemu-aarch64'; then
    cat <<'EOF'
ERROR: ARM64 cross-build requested on a non-ARM host, but no ARM64 binfmt handler is registered.

Install/register qemu user emulation, then retry:
  sudo dnf install -y qemu-user-static
  sudo systemctl restart systemd-binfmt
  ls /proc/sys/fs/binfmt_misc | grep -E 'aarch64|arm'
EOF
    exit 1
  fi
}

mkdir -p "$OUTPUT_DIR"
require_arm64_binfmt

echo "[1/4] Building arm64 bootc container image: $IMAGE_NAME"
podman build --platform linux/arm64 -f Containerfile.rpi -t "$IMAGE_NAME" .

echo "[2/4] Saving image to OCI archive: $OCI_ARCHIVE"
podman save --format oci-archive -o "$OCI_ARCHIVE" "$IMAGE_NAME"

echo "[3/4] Loading image into rootful podman storage"
sudo podman load -i "$OCI_ARCHIVE"

echo "[4/4] Building raw disk image in: $OUTPUT_DIR"
run_builder() {
  local extra_args=("$@")
  local podman_args=(
    --rm
    --privileged
    --security-opt label=disable
    --device /dev/btrfs-control:/dev/btrfs-control
    -v /var/lib/containers/storage:/var/lib/containers/storage
    -v "$OUTPUT_DIR":/output
  )

  if [[ -e /dev/kvm ]]; then
    podman_args+=(--device /dev/kvm:/dev/kvm)
  fi

  sudo podman run "${podman_args[@]}" \
    quay.io/centos-bootc/bootc-image-builder:latest \
    build --type raw --target-arch arm64 --rootfs btrfs --output /output "${extra_args[@]}" "$IMAGE_NAME"
}

if ! run_builder; then
  echo "Direct btrfs build failed; retrying with --in-vm..."
  if ! run_builder --in-vm; then
    cat <<'EOF'

ERROR: btrfs raw image build failed in both direct and --in-vm modes.

Most common causes on this host:
  1) Kernel/container limitations block btrfs subvolume ioctls in osbuild
  2) VM fallback cannot start reliably without KVM-capable virtualization

Recommended: run this same script on a host with:
  - modern Fedora kernel
  - /dev/kvm available (hardware virtualization enabled)
  - rootful podman

The script always builds with: --rootfs btrfs
EOF
    exit 1
  fi
fi

echo "Done. Raw artifact(s):"
ls -lah "$OUTPUT_DIR"
