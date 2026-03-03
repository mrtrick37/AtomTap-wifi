#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="localhost/atomtap-rpi:rc2"
OCI_ARCHIVE="/tmp/atomtap-rpi-rc2.oci"
OUTPUT_DIR="${1:-$PWD/output}"
ROOTFS="${ROOTFS:-btrfs}"
ALLOW_EXT4_FALLBACK="${ALLOW_EXT4_FALLBACK:-1}"

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
podman build --platform linux/arm64 -f "$REPO_ROOT/Containerfile.rpi" -t "$IMAGE_NAME" "$REPO_ROOT"

echo "[2/4] Saving image to OCI archive: $OCI_ARCHIVE"
podman save --format oci-archive -o "$OCI_ARCHIVE" "$IMAGE_NAME"

echo "[3/4] Loading image into rootful podman storage"
sudo podman load -i "$OCI_ARCHIVE"

echo "[4/4] Building raw disk image in: $OUTPUT_DIR"
echo "Requested rootfs: $ROOTFS"

run_builder() {
  local rootfs="$1"
  shift
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
    build --type raw --target-arch arm64 --rootfs "$rootfs" --output /output "${extra_args[@]}" "$IMAGE_NAME"
}

run_with_fallbacks() {
  local rootfs="$1"

  if run_builder "$rootfs"; then
    return 0
  fi

  if [[ -e /dev/kvm ]]; then
    echo "Direct $rootfs build failed; retrying with --in-vm..."
    if run_builder "$rootfs" --in-vm; then
      return 0
    fi
  else
    echo "Direct $rootfs build failed; skipping --in-vm fallback because /dev/kvm is not available."
  fi

  return 1
}

if ! run_with_fallbacks "$ROOTFS"; then
  if [[ "$ROOTFS" == "btrfs" && "$ALLOW_EXT4_FALLBACK" == "1" ]]; then
    echo "btrfs build failed on this host; retrying with ext4 fallback (set ALLOW_EXT4_FALLBACK=0 to disable)."
    if ! run_with_fallbacks ext4; then
      cat <<'EOF'

ERROR: raw image build failed for both btrfs and ext4.

Most common causes on this host:
  1) Kernel/container limitations block osbuild filesystem stages
  2) VM fallback cannot start reliably without KVM-capable virtualization

Recommended: run this script on a host with:
  - modern Fedora kernel
  - /dev/kvm available (hardware virtualization enabled)
  - rootful podman
EOF
      exit 1
    fi
  else
    cat <<EOF

ERROR: raw image build failed for rootfs: $ROOTFS

Tip: set ALLOW_EXT4_FALLBACK=1 (default) to auto-fallback from btrfs to ext4 on hosts that cannot build btrfs images.
EOF
    exit 1
  fi
fi

echo "Done. Raw artifact(s):"
ls -lah "$OUTPUT_DIR"

RAW_CANDIDATE="$OUTPUT_DIR/image/disk.raw"
if [[ -f "$RAW_CANDIDATE" ]]; then
  echo "Raw image: $RAW_CANDIDATE"
fi
