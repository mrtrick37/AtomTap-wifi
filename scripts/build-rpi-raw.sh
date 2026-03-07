#!/usr/bin/env bash

if [[ -z "${BASH_VERSION:-}" ]]; then
  exec bash "$0" "$@"
fi

if shopt -oq posix; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="localhost/atomtap-rpi:rc3"
OCI_ARCHIVE="/tmp/atomtap-rpi-rc3.oci"
OUTPUT_DIR="${1:-$PWD/output}"
ROOTFS="ext4"
ROOT_HEADROOM_MIB="${ROOT_HEADROOM_MIB:-256}"
BOOT_HEADROOM_MIB="${BOOT_HEADROOM_MIB:-64}"

cleanup_previous_run_artifacts() {
  local raw_img="$OUTPUT_DIR/image/disk.raw"
  local detached_any=0

  if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" ]]; then
    echo "ERROR: Refusing to clean unsafe OUTPUT_DIR value: '$OUTPUT_DIR'" >&2
    exit 1
  fi

  echo "[prep] Cleaning artifacts from previous run..."

  if command -v losetup >/dev/null 2>&1 && [[ -f "$raw_img" ]]; then
    mapfile -t _old_loops < <(sudo losetup -j "$raw_img" | awk -F: '{print $1}')
    for loopdev in "${_old_loops[@]:-}"; do
      if [[ -n "$loopdev" ]]; then
        sudo losetup -d "$loopdev" || true
        detached_any=1
      fi
    done
  fi

  if (( detached_any == 1 )); then
    echo "[prep] Detached stale loop devices from prior raw image."
  fi

  sudo rm -f "$OCI_ARCHIVE"
  sudo rm -f "$OUTPUT_DIR/manifest-raw.json"
  sudo rm -f "$OUTPUT_DIR/manifest.json"
  sudo rm -f "$OUTPUT_DIR/disk.raw"
  sudo rm -rf "$OUTPUT_DIR/image"

  mkdir -p "$OUTPUT_DIR"
  echo "[prep] Previous-run cleanup complete."
}

print_build_identity() {
  local script_hash="unknown"
  local git_commit="unknown"

  if command -v sha256sum >/dev/null 2>&1; then
    script_hash="$(sha256sum "$0" | awk '{print $1}')"
  fi

  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    git_commit="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  fi

  echo "Build script: $0"
  echo "Repo root: $REPO_ROOT"
  echo "Git commit: $git_commit"
  echo "Script sha256: $script_hash"
  echo "Output mode: disk.raw only"
}

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
cleanup_previous_run_artifacts
print_build_identity

echo "[1/4] Building arm64 bootc container image: $IMAGE_NAME"
podman build --platform linux/arm64 -f "$REPO_ROOT/Containerfile.rpi" -t "$IMAGE_NAME" "$REPO_ROOT"

echo "[2/4] Saving image to OCI archive: $OCI_ARCHIVE"
podman save --format oci-archive -o "$OCI_ARCHIVE" "$IMAGE_NAME"

echo "[3/4] Loading image into rootful podman storage"
sudo podman load -i "$OCI_ARCHIVE"

echo "[4/4] Building raw disk image in: $OUTPUT_DIR"
echo "Using rootfs: $ROOTFS"

run_builder_with_status_stream() {
  local cmd=("$@")
  local in_ostree_layout=0
  local ostree_started_at=0
  local progress_line_active=0

  render_ostree_spinner_line() {
    local elapsed="$1"
    local frame
    case $((elapsed % 4)) in
      0) frame='|' ;;
      1) frame='/' ;;
      2) frame='-' ;;
      3) frame="\\" ;;
    esac

    printf '\r[status %s] Still initializing ostree layout %s %ss elapsed' \
      "$(date '+%H:%M:%S')" "$frame" "$elapsed"
    progress_line_active=1
  }

  process_builder_line() {
    local line="$1"
    local now

    if (( progress_line_active == 1 )); then
      printf '\n'
      progress_line_active=0
    fi

    echo "$line"

    if [[ "$line" == *"Initializing ostree layout"* ]]; then
      now="$(date +%s)"
      in_ostree_layout=1
      ostree_started_at="$now"
      echo "[status $(date '+%H:%M:%S')] Entered ostree initialization; this can take a few minutes."
      return
    fi

    if (( in_ostree_layout == 1 )) && [[ "$line" == *"Deploying container image...done"* || "$line" == *"Installation complete!"* ]]; then
      now="$(date +%s)"
      echo "[status $(date '+%H:%M:%S')] Ostree initialization completed after $((now - ostree_started_at))s."
      in_ostree_layout=0
    fi
  }

  coproc BUILDER_STREAM { "${cmd[@]}" 2>&1; }
  local builder_pid="${BUILDER_STREAM_PID:-${COPROC_PID:-}}"
  if [[ -z "$builder_pid" ]]; then
    echo "ERROR: Failed to obtain builder process PID from coprocess." >&2
    return 1
  fi
  local builder_fd
  exec {builder_fd}<&"${BUILDER_STREAM[0]}"

  while true; do
    local line=""

    if IFS= read -r -t 5 line <&"$builder_fd"; then
      process_builder_line "$line"
      continue
    fi

    if ! kill -0 "$builder_pid" 2>/dev/null; then
      while IFS= read -r line <&"$builder_fd"; do
        process_builder_line "$line"
      done
      break
    fi

    if (( in_ostree_layout == 1 )); then
      local now elapsed
      now="$(date +%s)"
      elapsed=$((now - ostree_started_at))
      render_ostree_spinner_line "$elapsed"
    fi
  done

  wait "$builder_pid"
  local rc=$?
  exec {builder_fd}<&-
  return "$rc"
}

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

  run_builder_with_status_stream \
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

configure_rpi_native_boot() {
  local raw_img="$1"

  if [[ ! -f "$raw_img" ]]; then
    return 0
  fi

  for cmd in losetup mount umount find awk sed blkid mkdir cp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: Required command '$cmd' not found for Pi-native boot setup." >&2
      exit 1
    fi
  done

  (
    loopdev=""
    efi_mnt=""
    boot_mnt=""
    root_mnt=""

    _rpiboot_cleanup() {
      [[ -n "$efi_mnt" ]]  && sudo umount   "$efi_mnt"  2>/dev/null || true
      [[ -n "$boot_mnt" ]] && sudo umount   "$boot_mnt" 2>/dev/null || true
      [[ -n "$root_mnt" ]] && sudo umount   "$root_mnt" 2>/dev/null || true
      [[ -n "$efi_mnt" ]]  && sudo rmdir    "$efi_mnt"  2>/dev/null || true
      [[ -n "$boot_mnt" ]] && sudo rmdir    "$boot_mnt" 2>/dev/null || true
      [[ -n "$root_mnt" ]] && sudo rmdir    "$root_mnt" 2>/dev/null || true
      [[ -n "$loopdev" ]]  && sudo losetup -d "$loopdev" 2>/dev/null || true
    }
    trap '_rpiboot_cleanup' EXIT INT TERM

    echo "Configuring Raspberry Pi native boot artifacts (firmware + U-Boot + extlinux)..."

    loopdev="$(sudo losetup --find --show -P "$raw_img")"
    efi_mnt="$(mktemp -d)"
    boot_mnt="$(mktemp -d)"
    root_mnt="$(mktemp -d)"

    sudo mount "${loopdev}p1" "$efi_mnt"
  sudo mount "${loopdev}p2" "$boot_mnt"
  sudo mount "${loopdev}p3" "$root_mnt"

  local deploy_root=""
  deploy_root="$(sudo find "$root_mnt/ostree/deploy" -maxdepth 4 -type d -name '*.0' | sort | tail -n1)"
  if [[ -z "$deploy_root" ]]; then
    echo "ERROR: Could not locate ostree deployment in root partition for Pi boot setup." >&2
    exit 1
  fi

  local start4_elf=""
  local fixup4_dat=""
  local uboot_bin=""

  start4_elf="$(sudo find "$deploy_root" -type f -name 'start4.elf' 2>/dev/null | head -n1 || true)"
  fixup4_dat="$(sudo find "$deploy_root" -type f -name 'fixup4.dat' 2>/dev/null | head -n1 || true)"
  if [[ -r /usr/share/uboot/rpi_4/u-boot.bin ]]; then
    uboot_bin="/usr/share/uboot/rpi_4/u-boot.bin"
  elif [[ -r /usr/lib/uboot/rpi_4/u-boot.bin ]]; then
    uboot_bin="/usr/lib/uboot/rpi_4/u-boot.bin"
  fi
  if [[ -z "$uboot_bin" ]]; then
    uboot_bin="$(sudo find "$deploy_root" -type f -path '*/uboot/rpi_4/u-boot.bin' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$uboot_bin" ]]; then
    uboot_bin="$(sudo find "$deploy_root" -type f -path '*/uboot/rpi_arm64/u-boot.bin' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$uboot_bin" ]]; then
    uboot_bin="$(sudo find "$deploy_root" -type f -path '*/uboot/rpi*/u-boot.bin' 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$start4_elf" ]]; then
    start4_elf="$(find /usr/share /usr/lib/firmware -type f -name 'start4.elf' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$fixup4_dat" ]]; then
    fixup4_dat="$(find /usr/share /usr/lib/firmware -type f -name 'fixup4.dat' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$uboot_bin" ]]; then
    uboot_bin="$(find /usr/share /usr/lib -type f -path '*/uboot/rpi_4/u-boot.bin' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$uboot_bin" ]]; then
    uboot_bin="$(find /usr/share /usr/lib -type f -path '*/uboot/rpi_arm64/u-boot.bin' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$uboot_bin" ]]; then
    uboot_bin="$(find /usr/share /usr/lib -type f -path '*/uboot/rpi*/u-boot.bin' 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$start4_elf" || -z "$fixup4_dat" ]]; then
    echo "ERROR: Could not locate Raspberry Pi firmware files (start4.elf/fixup4.dat) in deployment or host." >&2
    echo "Install firmware package(s), e.g.: sudo dnf install -y bcm283x-firmware" >&2
    exit 1
  fi

  if [[ -z "$uboot_bin" ]]; then
    echo "ERROR: Could not locate u-boot.bin in deployment or host." >&2
    echo "Install U-Boot package(s), e.g.: sudo dnf install -y uboot-images-armv8" >&2
    exit 1
  fi

  echo "Using U-Boot binary: $uboot_bin"

  sudo cp -f "$start4_elf" "$efi_mnt/start4.elf"
  sudo cp -f "$fixup4_dat" "$efi_mnt/fixup4.dat"
  sudo cp -f "$uboot_bin" "$efi_mnt/u-boot.bin"

  local uboot_dir=""
  uboot_dir="$(dirname "$uboot_bin")"
  if compgen -G "$uboot_dir"'/bcm27*.dtb' >/dev/null 2>&1; then
    echo "Staging DTBs from: $uboot_dir"
    sudo cp -f "$uboot_dir"/bcm27*.dtb "$efi_mnt/" || true
  fi

  local deployment_dtbs=""
  deployment_dtbs="$(dirname "$deploy_root")"
  if sudo find "$deploy_root/usr/lib/modules" -type f -path '*/dtb/broadcom/bcm27*.dtb' | head -n1 >/dev/null 2>&1; then
    sudo find "$deploy_root/usr/lib/modules" -type f -path '*/dtb/broadcom/bcm27*.dtb' -exec cp -f {} "$efi_mnt/" \; || true
  fi

  local bls_entry=""
  bls_entry="$(sudo find "$boot_mnt/loader/entries" -maxdepth 1 -type f -name '*.conf' | sort | tail -n1)"
  if [[ -z "$bls_entry" ]]; then
    echo "ERROR: Could not locate BLS entry in boot partition." >&2
    exit 1
  fi

  local linux_path=""
  local initrd_path=""
  local options_line=""
  local options_sanitized=""

  linux_path="$(sudo awk '/^linux[[:space:]]+/ {print $2; exit}' "$bls_entry")"
  initrd_path="$(sudo awk '/^initrd[[:space:]]+/ {print $2; exit}' "$bls_entry")"
  options_line="$(sudo sed -n 's/^options[[:space:]]\+//p' "$bls_entry" | head -n1)"

  if [[ -z "$linux_path" || -z "$initrd_path" || -z "$options_line" ]]; then
    echo "ERROR: Failed to parse linux/initrd/options from BLS entry: $bls_entry" >&2
    exit 1
  fi

  options_sanitized="$(echo "$options_line" | sed -E \
    -e 's/(^|[[:space:]])rhgb([[:space:]]|$)/ /g' \
    -e 's/(^|[[:space:]])quiet([[:space:]]|$)/ /g' \
    -e 's/(^|[[:space:]])console=[^[:space:]]+//g' \
    -e 's/[[:space:]]+/ /g' \
    -e 's/^ //; s/ $//')"

  options_line="$options_sanitized console=ttyS0,115200n8 console=tty1 consoleblank=0 loglevel=7 nomodeset plymouth.enable=0 rd.plymouth=0 systemd.show_status=1 rd.systemd.show_status=1"

  sudo cp -f "$boot_mnt$linux_path" "$efi_mnt/vmlinuz"
  sudo cp -f "$boot_mnt$initrd_path" "$efi_mnt/initramfs.img"

  sudo mkdir -p "$efi_mnt/extlinux"
  sudo tee "$efi_mnt/extlinux/extlinux.conf" >/dev/null <<EOF
DEFAULT fedora
TIMEOUT 10

LABEL fedora
  KERNEL /vmlinuz
  INITRD /initramfs.img
  FDTDIR /
  APPEND $options_line
EOF

  sudo tee "$efi_mnt/config.txt" >/dev/null <<EOF
arm_64bit=1
enable_uart=1
hdmi_force_hotplug=1
hdmi_force_hotplug:0=1
hdmi_force_hotplug:1=1
hdmi_safe=1
hdmi_group=2
hdmi_mode=82
hdmi_group:0=2
hdmi_mode:0=82
hdmi_group:1=2
hdmi_mode:1=82
disable_overscan=1
os_check=0
kernel=u-boot.bin
EOF

    sudo sync
    sudo umount "$efi_mnt"
    sudo umount "$boot_mnt"
    sudo umount "$root_mnt"
    sudo rmdir "$efi_mnt" "$boot_mnt" "$root_mnt"
    sudo losetup -d "$loopdev"
    efi_mnt="" boot_mnt="" root_mnt="" loopdev=""
  )

  echo "Pi-native boot assets written to partition 1 (FAT)."
}

minimize_raw_image() {
  local raw_img="$1"

  if [[ ! -f "$raw_img" ]]; then
    return 0
  fi

  for cmd in losetup e2fsck resize2fs dumpe2fs sfdisk truncate; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Skipping raw minimization: '$cmd' not found."
      return 0
    fi
  done

  (
    loopdev=""

    _minimize_cleanup() {
      [[ -n "$loopdev" ]] && sudo losetup -d "$loopdev" 2>/dev/null || true
    }
    trap '_minimize_cleanup' EXIT INT TERM

    echo "Minimizing raw image size (shrink ext4 + partition table + file truncate)..."
    loopdev="$(sudo losetup --find --show -P "$raw_img")"

    sudo e2fsck -fy "${loopdev}p2"
    sudo e2fsck -fy "${loopdev}p3"
    sudo resize2fs -M "${loopdev}p2"
    sudo resize2fs -M "${loopdev}p3"
    sudo e2fsck -fy "${loopdev}p2"
    sudo e2fsck -fy "${loopdev}p3"

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

    gpt_tail_sectors=34

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
    loopdev=""

    sudo truncate -s "$new_total_bytes" "$raw_img"

    sudo sfdisk --force "$raw_img" <<EOF
label: gpt
unit: sectors

${raw_img}1 : start=$p1_start, size=$p1_size, type=$p1_type, attrs="LegacyBIOSBootable"
${raw_img}2 : start=$p2_start, size=$new_p2_size_sectors, type=$p2_type
${raw_img}3 : start=$p3_start, size=$new_p3_size_sectors, type=$p3_type
EOF

    if command -v sgdisk >/dev/null 2>&1; then
      sudo sgdisk --attributes=1:set:2 "$raw_img" >/dev/null
    fi

    loopdev="$(sudo losetup --find --show -P "$raw_img")"
    sudo e2fsck -fy "${loopdev}p2"
    sudo e2fsck -fy "${loopdev}p3"
    sudo losetup -d "$loopdev"
    loopdev=""

    echo "Minimized raw image bytes: $new_total_bytes"
    ls -lh "$raw_img"
  )
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

  echo "[post] Starting raw image minimization..."
  post_min_start="$(date +%s)"
  minimize_raw_image "$RAW_CANDIDATE"

  echo "[post] Starting Raspberry Pi native boot artifact staging..."
  rpi_stage_start="$(date +%s)"
  configure_rpi_native_boot "$RAW_CANDIDATE"
  rpi_stage_end="$(date +%s)"
  echo "[post] Pi-native boot artifact staging complete in $((rpi_stage_end - rpi_stage_start))s."

  post_min_end="$(date +%s)"
  echo "[post] Post-processing complete in $((post_min_end - post_min_start))s."
fi
