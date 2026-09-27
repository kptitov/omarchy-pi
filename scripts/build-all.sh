#!/usr/bin/env bash
# Host-side orchestrator: packages -> rootfs -> bootable image.
#
# Runs on an Apple Silicon Mac with Docker or Podman (native aarch64
# containers, so no emulation penalty). Produces work/out/omarchy-pi.img.
#
# Omarchy itself comes from upstream's aarch64 edge repo. Set OMARCHY to a
# source checkout only to build the package list from local sources; any
# *.pkg.tar.* dropped in work/out is served as [omarchy-pi] and wins over
# upstream.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
VARIANT="${VARIANT:-vm}"
OMARCHY="${OMARCHY:-}"
WORK="$ROOT/work"
mkdir -p "$WORK/out"

DOCKER="${DOCKER:-$(command -v docker || command -v podman || true)}"
[ -n "$DOCKER" ] || { echo "Need docker or podman on PATH" >&2; exit 1; }
docker() { "$DOCKER" "$@"; }

OMARCHY_MOUNT=()
if [ -n "$OMARCHY" ]; then
  [ -d "$OMARCHY" ] || { echo "OMARCHY=$OMARCHY does not exist" >&2; exit 1; }
  OMARCHY_MOUNT=(-v "$OMARCHY:/omarchy:ro")
fi

echo "### Stage 0: container images"
docker build --quiet --platform linux/arm64 -t alarm-work  -f docker/Dockerfile.alarm  docker/ >/dev/null
docker build --quiet --platform linux/arm64 -t alarm-build -f docker/Dockerfile.build docker/ >/dev/null

echo "### Stage 1: build rootfs ($VARIANT)"
docker rm -f omarchy-rootfs >/dev/null 2>&1 || true
# Persistent package cache: a rebuild otherwise re-downloads several GB.
# Podman, unlike Docker, errors when the volume already exists.
docker volume inspect omarchy-pi-pacman-cache >/dev/null 2>&1 \
  || docker volume create omarchy-pi-pacman-cache >/dev/null

# Snapshot the scripts rather than bind-mounting them live. bash reads a script
# incrementally as it executes, so editing one mid-run corrupts that run.
SNAP="$WORK/.scripts"
rm -rf "$SNAP" && cp -r "$ROOT/scripts" "$SNAP"

# Keypair for the automated smoke test (scripts/smoke-test.sh).
if [ ! -f "$WORK/id_omarchy" ]; then
  ssh-keygen -q -t ed25519 -N '' -C omarchy-pi-smoke -f "$WORK/id_omarchy"
fi

docker run --name omarchy-rootfs --platform linux/arm64 \
  -v "$WORK:/keys:ro" \
  -v omarchy-pi-pacman-cache:/var/cache/pacman/pkg \
  -v "$SNAP:/scripts:ro" \
  -v "$ROOT/config:/config:ro" \
  ${OMARCHY_MOUNT[@]+"${OMARCHY_MOUNT[@]}"} \
  -v "$WORK/out:/pkgs:ro" \
  -e VARIANT="$VARIANT" -e ALLOW_SSH="${ALLOW_SSH:-}" \
  alarm-work bash /scripts/build-rootfs.sh

echo "### Stage 2: export rootfs"
docker export omarchy-rootfs -o "$WORK/rootfs.tar"
# The exported tarball is all stage 3 needs; the stopped container is ~9 GB.
docker rm -f omarchy-rootfs >/dev/null

echo "### Stage 3: assemble image"
docker run --rm --platform linux/arm64 \
  -v "$SNAP:/scripts:ro" \
  -v "$ROOT/config:/config:ro" \
  -v "$WORK:/work" \
  -e VARIANT="$VARIANT" \
  alarm-work bash -c '
    set -e
    pacman -S --noconfirm --needed e2fsprogs dosfstools mtools gptfdisk util-linux >/dev/null 2>&1
    rm -rf /rootfs && mkdir -p /rootfs
    tar -xf /work/rootfs.tar -C /rootfs
    # Docker-injected files that must not ship in the image
    rm -f /rootfs/.dockerenv /rootfs/etc/hostname /rootfs/etc/hosts /rootfs/etc/resolv.conf
    # Bind-mount points export as empty directories; they are build scaffolding.
    rmdir /rootfs/config /rootfs/omarchy /rootfs/scripts /rootfs/pkgs /rootfs/keys 2>/dev/null || true
    printf "omarchy-pi\n" > /rootfs/etc/hostname
    printf "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 omarchy-pi\n" > /rootfs/etc/hosts
    ln -sf /run/systemd/resolve/stub-resolv.conf /rootfs/etc/resolv.conf
    OUT=/work/out/omarchy-pi.img ROOTFS=/rootfs bash /scripts/build-image.sh
  '

# The exported rootfs is scratch once the image exists, and ~10 GB of it.
[ "${KEEP_ROOTFS:-0}" = 1 ] || rm -f "$WORK/rootfs.tar"

# A Podman machine's disk grows by every build's scratch (~25 GB) and never
# returns it to macOS on its own; four builds filled a 460 GB Mac on
# 2026-09-27. fstrim hands the freed blocks back.
if [ "$(basename "$DOCKER")" = podman ] && podman machine inspect >/dev/null 2>&1; then
  podman machine ssh sudo fstrim -a >/dev/null 2>&1 || echo "WARN: fstrim in the podman machine failed; its disk will not shrink" >&2
fi

echo
echo "### Done: $WORK/out/omarchy-pi.img"
echo "    Boot it:  ./scripts/run-vm.sh"
