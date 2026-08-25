#!/usr/bin/env bash
set -Eeuo pipefail

# Create an Ubuntu 24.04 Incus VM with rootless Podman and Buildah.
#
# The VM is intentionally separate from the host's Incus/container nesting
# configuration. Podman runs against the VM's own Linux kernel.

VM_NAME="${VM_NAME:-podman-vm}"
VM_CPU="${VM_CPU:-2}"
VM_MEMORY="${VM_MEMORY:-4GiB}"
VM_DISK="${VM_DISK:-30GiB}"
PODMAN_USER="${PODMAN_USER:-builder}"
INCUS_REMOTE="${INCUS_REMOTE:-images}"
UBUNTU_IMAGE="${INCUS_REMOTE}:ubuntu/24.04/cloud"

usage() {
    sed -n '2,18p' "$0"
    cat <<'EOF'

Usage:
  ./incus-podman-vm.sh [--shell]

Environment overrides:
  VM_NAME=podman-vm       Incus VM name
  VM_CPU=2                vCPUs
  VM_MEMORY=4GiB          VM memory
  VM_DISK=30GiB           root disk size
  PODMAN_USER=builder     non-root account used for Podman/Buildah
  INCUS_REMOTE=images     Incus image remote

Examples:
  ./incus-podman-vm.sh
  VM_NAME=ci-builder VM_CPU=4 VM_MEMORY=8GiB ./incus-podman-vm.sh --shell

After creation, enter the VM with:
  incus exec "$VM_NAME" -- sudo --login --user "$PODMAN_USER"
EOF
}

want_shell=false
case "${1:-}" in
    "") ;;
    --shell) want_shell=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

for command in incus mktemp; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

# virtiofsd is a host-side helper used by Incus for VM directory shares. It
# may be installed outside PATH by distribution packages, so check the usual
# package locations as well.
VIRTIOFSD_PATH=""
for candidate in \
    "$(command -v virtiofsd 2>/dev/null || true)" \
    /usr/bin/virtiofsd \
    /usr/libexec/virtiofsd \
    /usr/lib/qemu/virtiofsd \
    /usr/local/bin/virtiofsd; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        VIRTIOFSD_PATH="$candidate"
        break
    fi
done

if [[ ! "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]]; then
    echo "Invalid VM_NAME: $VM_NAME" >&2
    exit 2
fi

if [[ ! "$PODMAN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Invalid PODMAN_USER: $PODMAN_USER" >&2
    exit 2
fi

print_share_instructions() {
    echo
    if [[ -z "$VIRTIOFSD_PATH" ]]; then
        echo "WARNING: virtiofsd was not found on the Incus host."
        echo "         Install it with: sudo apt update && sudo apt install -y virtiofsd"
        echo "         The share command below requires virtiofsd."
    else
        echo "Host virtiofsd found at: $VIRTIOFSD_PATH"
    fi
    echo
    echo "Share the current host directory with the VM:"
    echo "  incus exec \"$VM_NAME\" -- mkdir -p /home/$PODMAN_USER/host"
    echo "  incus config device add \"$VM_NAME\" workdir disk source=\"\$(pwd)\" path=/home/$PODMAN_USER/host io.bus=virtiofs"
    echo
    echo "Remove the share later with:"
    echo "  incus config device remove \"$VM_NAME\" workdir"
}

if incus info "$VM_NAME" >/dev/null 2>&1; then
    echo "Incus instance already exists: $VM_NAME"
    echo "Entering the existing VM is still available with:"
    echo "  incus exec \"$VM_NAME\" -- sudo --login --user \"$PODMAN_USER\""
    print_share_instructions
    if $want_shell; then
        exec incus exec "$VM_NAME" -- sudo --login --user "$PODMAN_USER"
    fi
    exit 0
fi

cloud_init_file="$(mktemp)"
cleanup() {
    rm -f "$cloud_init_file"
}
trap cleanup EXIT

cat >"$cloud_init_file" <<EOF
#cloud-config
package_update: true
package_upgrade: true

packages:
  - buildah
  - ca-certificates
  - dbus-user-session
  - fuse-overlayfs
  - git
  - passt
  - podman
  - slirp4netns
  - sudo
  - uidmap

users:
  - name: $PODMAN_USER
    gecos: Podman build user
    shell: /bin/bash
    groups: [sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true

runcmd:
  # Rootless Podman needs a subordinate UID and GID range.
  - [bash, -lc, "usermod --add-subuids 100000-165535 $PODMAN_USER"]
  - [bash, -lc, "usermod --add-subgids 100000-165535 $PODMAN_USER"]
  # Keep a user runtime directory available for rootless container tools.
  - [bash, -lc, "loginctl enable-linger $PODMAN_USER || true"]
  - [bash, -lc, "systemctl enable --now systemd-logind || true"]
  - [bash, -lc, "install -d -o $PODMAN_USER -g $PODMAN_USER /home/$PODMAN_USER/work /home/$PODMAN_USER/host"]

final_message: "Podman/Buildah VM provisioning completed."
EOF

echo "Creating Ubuntu 24.04 VM $VM_NAME"
incus init "$UBUNTU_IMAGE" "$VM_NAME" \
    --vm \
    --config "limits.cpu=$VM_CPU" \
    --config "limits.memory=$VM_MEMORY" \
    --device "root,size=$VM_DISK"

# Configure cloud-init before the first start. The cloud image includes the
# Incus agent needed to deliver this data to a VM.
incus config set "$VM_NAME" cloud-init.user-data - <"$cloud_init_file"
incus start "$VM_NAME"

echo "Waiting for cloud-init to finish..."
for _ in $(seq 1 180); do
    status="$(incus exec "$VM_NAME" -- cloud-init status 2>/dev/null || true)"
    case "$status" in
        *"status: done"*)
            break
            ;;
        *"status: error"*|*"status: disabled"*)
            echo "cloud-init did not complete successfully:" >&2
            incus exec "$VM_NAME" -- cloud-init status --long >&2 || true
            exit 1
            ;;
    esac
    sleep 2
done

if [[ "$status" != *"status: done"* ]]; then
    echo "Timed out waiting for cloud-init in $VM_NAME" >&2
    incus exec "$VM_NAME" -- cloud-init status --long >&2 || true
    exit 1
fi

echo "Checking rootless Podman and Buildah..."
incus exec "$VM_NAME" -- sudo --login --user "$PODMAN_USER" -- podman info >/dev/null
incus exec "$VM_NAME" -- sudo --login --user "$PODMAN_USER" -- buildah info >/dev/null

echo
echo "Ready. Enter the VM with:"
echo "  incus exec \"$VM_NAME\" -- sudo --login --user \"$PODMAN_USER\""
echo
echo "Build an image from /home/$PODMAN_USER/work with:"
echo "  podman build -t my-image ."
echo "  buildah bud -t my-image ."

print_share_instructions

if $want_shell; then
    exec incus exec "$VM_NAME" -- sudo --login --user "$PODMAN_USER"
fi
