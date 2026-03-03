#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="localhost/atomtap-rpi:rc2"
OCI_ARCHIVE="/tmp/atomtap-rpi-rc2.oci"
OUTPUT_DIR="${1:-$PWD/output}"
ROOTFS="ext4"
MINIMIZE_RAW="${MINIMIZE_RAW:-1}"
ROOT_HEADROOM_MIB="${ROOT_HEADROOM_MIB:-256}"
BOOT_HEADROOM_MIB="${BOOT_HEADROOM_MIB:-64}"
COMPRESS_RAW="${COMPRESS_RAW:-1}"
DROP_UNCOMPRESSED_RAW="${DROP_UNCOMPRESSED_RAW:-0}"

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
echo "Using rootfs: $ROOTFS"

run_builder() {
  local rootfs="$1"
  shift
  local extra_args=("$@")
  local podman_args=(
    --rm
    --privileged
    --security-opt label=disable
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

get_ext4_size_bytes() {
  local part="$1"
  local block_count
  local block_size

  block_count="$(sudo dumpe2fs -h "$part" 2>/dev/null | awk -F: '/Block count:/{gsub(/ /, "", $2); print $2}')"
  block_size="$(sudo dumpe2fs -h "$part" 2>/dev/null | awk -F: '/Block size:/{gsub(/ /, "", $2); print $2}')"

  if [[ -z "$block_count" || -z "$block_size" ]]; then
    echo "ERROR: Unable to read ext4 metadata for $part" >&2
    exit 1
  fi

  echo $((block_count * block_size))
}

ceil_div() {
  local num="$1"
  local den="$2"
  echo $(((num + den - 1) / den))
}

minimize_raw_image() {
  local raw_img="$1"
  local loopdev=""
  local cleanup_needed=0

  if [[ ! -f "$raw_img" ]]; then
    return 0
  fi

  for cmd in losetup e2fsck resize2fs dumpe2fs sfdisk truncate; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Skipping raw minimization: '$cmd' not found."
      return 0
    fi
  done

  echo "Minimizing raw image size (shrink ext4 + partition table + file truncate)..."
  loopdev="$(sudo losetup --find --show -P "$raw_img")"
  cleanup_needed=1

  sudo e2fsck -fy "${loopdev}p2"
  sudo e2fsck -fy "${loopdev}p3"
  sudo resize2fs -M "${loopdev}p2"
  sudo resize2fs -M "${loopdev}p3"
  sudo e2fsck -fy "${loopdev}p2"
  sudo e2fsck -fy "${loopdev}p3"

  local p1_start p1_size p1_type
  local p2_start p2_size p2_type
  local p3_start p3_size p3_type

  p1_start="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/1 *:/{print $4; exit}')"
  p1_size="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/1 *:/{print $6; exit}')"
  p1_type="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/1 *:/{print $8; exit}')"

  p2_start="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/2 *:/{print $4; exit}')"
  p2_size="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/2 *:/{print $6; exit}')"
  p2_type="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/2 *:/{print $8; exit}')"

  p3_start="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/3 *:/{print $4; exit}')"
  p3_size="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/3 *:/{print $6; exit}')"
  p3_type="$(sudo sfdisk -d "$raw_img" | awk -F'[=, ]+' '/3 *:/{print $8; exit}')"

  if [[ -z "$p1_start" || -z "$p2_start" || -z "$p3_start" ]]; then
    echo "ERROR: Failed to parse partition table from $raw_img" >&2
    exit 1
  fi

  local boot_bytes root_bytes
  local boot_total_bytes root_total_bytes
  local new_p2_size_sectors new_p3_size_sectors
  local new_p2_end new_p3_end
  local gpt_tail_sectors=34
  local new_total_sectors new_total_bytes

  boot_bytes="$(get_ext4_size_bytes "${loopdev}p2")"
  root_bytes="$(get_ext4_size_bytes "${loopdev}p3")"

  boot_total_bytes=$((boot_bytes + BOOT_HEADROOM_MIB * 1024 * 1024))
  root_total_bytes=$((root_bytes + ROOT_HEADROOM_MIB * 1024 * 1024))

  new_p2_size_sectors="$(ceil_div "$boot_total_bytes" 512)"
  new_p3_size_sectors="$(ceil_div "$root_total_bytes" 512)"

  if (( new_p2_size_sectors > p2_size )); then
    new_p2_size_sectors="$p2_size"
  fi
  if (( new_p3_size_sectors > p3_size )); then
    new_p3_size_sectors="$p3_size"
  fi

  new_p2_end=$((p2_start + new_p2_size_sectors - 1))
  if (( new_p2_end >= p3_start )); then
    new_p2_end=$((p3_start - 1))
    new_p2_size_sectors=$((new_p2_end - p2_start + 1))
  fi

  new_p3_end=$((p3_start + new_p3_size_sectors - 1))
  new_total_sectors=$((new_p3_end + gpt_tail_sectors + 1))
  new_total_bytes=$((new_total_sectors * 512))

  sudo losetup -d "$loopdev"
  cleanup_needed=0

  sudo truncate -s "$new_total_bytes" "$raw_img"

  sudo sfdisk --force "$raw_img" <<EOF
label: gpt
unit: sectors

${raw_img}1 : start=$p1_start, size=$p1_size, type=$p1_type
${raw_img}2 : start=$p2_start, size=$new_p2_size_sectors, type=$p2_type
${raw_img}3 : start=$p3_start, size=$new_p3_size_sectors, type=$p3_type
EOF

  loopdev="$(sudo losetup --find --show -P "$raw_img")"
  cleanup_needed=1
  sudo e2fsck -fy "${loopdev}p2"
  sudo e2fsck -fy "${loopdev}p3"
  sudo losetup -d "$loopdev"
  cleanup_needed=0

  echo "Minimized raw image bytes: $new_total_bytes"
  ls -lh "$raw_img"

  if (( cleanup_needed == 1 )) && [[ -n "$loopdev" ]]; then
    sudo losetup -d "$loopdev" || true
  fi
}

if ! run_with_fallbacks "$ROOTFS"; then
  cat <<'EOF'

ERROR: raw image build failed with ext4.

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

echo "Done. Raw artifact(s):"
ls -lah "$OUTPUT_DIR"

RAW_CANDIDATE="$OUTPUT_DIR/image/disk.raw"
if [[ -f "$RAW_CANDIDATE" ]]; then
  echo "Raw image: $RAW_CANDIDATE"

  if [[ "$MINIMIZE_RAW" == "1" ]]; then
    minimize_raw_image "$RAW_CANDIDATE"
  fi

  if [[ "$COMPRESS_RAW" == "1" ]]; then
    if command -v xz >/dev/null 2>&1; then
      echo "Compressing raw image with xz -9e for smallest distributable artifact..."
      xz -T0 -9 -e -f -k "$RAW_CANDIDATE"
      echo "Compressed image: $RAW_CANDIDATE.xz"
      ls -lh "$RAW_CANDIDATE" "$RAW_CANDIDATE.xz"

      if [[ "$DROP_UNCOMPRESSED_RAW" == "1" ]]; then
        rm -f "$RAW_CANDIDATE"
        echo "Removed uncompressed raw image (DROP_UNCOMPRESSED_RAW=1)."
      fi
    else
      echo "Skipping compression: 'xz' not installed."
    fi
  fi
fi
