#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="localhost/atomtap-rpi:rc2"
OCI_ARCHIVE="/tmp/atomtap-rpi-rc2.oci"
OUTPUT_DIR="${1:-$PWD/output}"

mkdir -p "$OUTPUT_DIR"

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
