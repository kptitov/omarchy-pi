# Porting plan

## `edge-aarch64`: installing from upstream's own aarch64 repo (2026-09-27)

Upstream now publishes aarch64. `pkgs.omarchy.org/edge/aarch64` carried 152
packages on 2026-09-27, 151 of them built in September 2026. They include
`omarchy` 4.0.4, `omarchy-settings`, `omarchy-keyring`, Hyprland, and all 20
packages in [packages/aarch64-rebuild.txt](../packages/aarch64-rebuild.txt).
They are built against Arch Linux ARM (the build record shows ALARM's
keyring and its exact glibc build) and signed with Omarchy's key: the database
embeds no signatures, but each package has a detached `.sig`. The work comes
from upstream's Apple Silicon effort (`omarchy-mac`, the `linux-aurora`
kernel). The stable channel had 26 aarch64 packages and no `omarchy`, so edge
is the only channel that installs Omarchy on ARM today.

This branch installs from that repo and builds nothing:

| Change | Where |
|---|---|
| `[omarchy]` points at `pkgs.omarchy.org/edge/$arch`; `[omarchy-pi]` stays ahead of it for local overrides and is empty by default | [pacman-pi.conf](../config/pacman/pacman-pi.conf) |
| Omarchy's key is fetched by its pinned fingerprint and locally signed, the same bootstrap as upstream's `omarchy-update-keyring` | `build-rootfs.sh` |
| The package list is read from the installed `omarchy` package, so list and package are always one release | `build-rootfs.sh` |
| No Omarchy fork and no `omarchy-pkgs` checkout; `OMARCHY=` is optional | `build-all.sh` |
| Runs under Podman as well as Docker | `build-all.sh`, `Dockerfile.alarm` |
| `omarchy-refresh-pacman` copies upstream's x86_64 config and then runs the `pre-refresh-pacman` hook; ours rewrites it from the Pi template, keeping the requested channel | [10-omarchy-pi](../config/hooks/pre-refresh-pacman.d/10-omarchy-pi) |

Three upstream installer lines still assume x86_64. They are shimmed in the
installed copy only, just before provisioning, and each shim prints
`no longer needed` once upstream changes the line:

| Step | Defect in 4.0.4 | Shim |
|---|---|---|
| `install/user/mise-work.sh` | looks only for `node-v*-linux-x64.tar.gz` | match `linux-arm64` |
| `install/hardware/apple/fix-spi-keyboard.sh` | DMI read fails under `bash -e` on a board without DMI | `\|\| true` |
| `install/config/snapper.sh` | runs `snapper` unguarded; the aarch64 package does not depend on it | skip when absent |

**Omarchy 4.0.4 aborts the whole installer at the first failing step.** The
note below that `run_logged` traps failures and continues no longer holds. The
first build of this branch stopped at `snapper.sh`, step 9 of 49, so
services, firewall, hardware, login and post-install never ran and SDDM was
left disabled. The smoke test caught it as `sddm enabled: FAIL`.

### Results on this branch

| Check | Result |
|---|---|
| Build, VM variant, Podman on an M4 Pro | 10 min with a warm package cache; rootfs 10.5 GB |
| Base packages | 146 of 147 install; `obs-studio` has no aarch64 build |
| Omarchy installer | 49 of 49 steps completed, 0 failed (VM and Pi variants) |
| `smoke-test.sh` (HVF) | PASSED: SSH in 17 s, 0 failed units, SDDM running, no x86 mirrors |
| `test-a76-nvme.sh` (TCG, Cortex-A76, root on NVMe) | SSH in 42 s, root `nvme0n1p2`, 25 binaries run, 0 illegal-instruction faults. `omacalc`/`omawrite` abort with no display, as before |
| Desktop (HVF + `virtio-gpu`, 1920x1080) | SDDM autologin; Hyprland 0.56.2 and quickshell running in a seat0 session; [screenshot](images/omarchy-4.0.4-edge-aarch64.png) |
| `pre-refresh-pacman` hook | from upstream's `edge` and `stable` configs: `[multilib]` removed, ALARM mirrors restored, channel kept; `pacman -Sy` then syncs all 6 databases |
| `omarchy-pi-doctor` | on the booted VM: 12 passed, 1 failed, the failure being its repo check flagging `pkgs.omarchy.org/edge/$arch` as x86. The rewritten check classifies 3 sample configs correctly; it has not been re-run on a booted image |
| `test-raspi4b.sh` (Pi variant, TCG, SD) | `linux-rpi` kernel booted and the initramfs mounted root by PARTUUID from the SD card (root superblock: mount count 0 to 1, last mounted on `/sysroot`). No writes after that and no journal within 900 s, so nothing past the root mount is proven here; the serial console stays dark as documented below |
| Pi 5 image | builds: `kernel8.img`, 0 failed installer steps, 14 GB. Not booted on hardware |

### First boot on real hardware (2026-09-27)

Raspberry Pi 5 Model B Rev 1.1, 8 GB, official-style `pwmfan` cooler, booted
from a 57.7 GB microSD written from this branch's `VARIANT=pi ALLOW_SSH=1`
image. Samsung LC49G95T on HDMI-A-1.

| Check | Result |
|---|---|
| Boot | firmware -> `linux-rpi` 6.18.53 -> SDDM autologin -> Hyprland, 0 failed units; root grew to 52.3 GB on first boot |
| GPU | compositing on V3D: Hyprland's `v3d` DRM clients show 1.71 s render-engine time and 118 MB resident; no software-render variables in its environment. GLES 3.0 context (3.2 is refused with `EGL_BAD_MATCH`, Hyprland falls back) |
| Display | `vc4-kms-v3d-pi5`; HDMI-A-1 at 3840x1080@60 by default, 5120x1440@59.98 offered |
| Thermals, 90 s on 4 cores | peak 61.1 C, CPU held 2,400 MHz throughout; fan 1,754 -> 3,943 rpm, back to 48.5 C 30 s after |
| Network | Ethernet and Wi-Fi (5 GHz, 433 Mbit/s); `omarchy-pi.local` resolves over mDNS |
| `omarchy-pi-doctor` | 13 passed, 0 failed |
| Clock | **came up 2 d 19 h slow with NTP off**: the image enabled no time sync and the RTC has no battery. Fixed on the device with `timedatectl set-ntp true`; `build-rootfs.sh` now enables `systemd-timesyncd` and `fstrim.timer` |
| Wi-Fi country | unset (`00`), which leaves 5 GHz DFS channels listen-only. Set to `AT` by hand in `/etc/conf.d/wireless-regdom`; not yet in the build |

A Podman machine does not return a build's scratch space to macOS. Four builds
grew its disk to 89 GB and filled the host; `build-all.sh` now deletes
`work/rootfs.tar` and runs `fstrim` in the machine after every build.

## Phases

| # | Phase | Status |
|---|---|---|
| 1 | Establish the aarch64 build environment (Docker, native arm64 on Apple Silicon) | done |
| 2 | Determine package availability and rebuild what upstream ships x86_64-only | done — 23 built, see below |
| 3 | Build a bootable VM image and run Omarchy's own installer on ARM | done — 4.0.2, zero failed steps |
| 3b | Verify the Pi boot chain as far as emulation allows (see below) | done |
| 4 | Verify on real Pi 5 hardware (V3D GPU, firmware boot, thermals) | done on `edge-aarch64`, 2026-09-27 — see [first boot](#first-boot-on-real-hardware-2026-09-27) |
| 5 | Automated image releases via CI | scaffolded ([workflow](../.github/workflows/build-image.yml)) |
| 6 | Host an aarch64 pacman repo so installed systems get package updates | not started |

### Package findings (Omarchy 4.0.2)

Of the 148 packages in `install/omarchy-base.packages`, 122 install directly
from Arch Linux ARM. The rest:

- **19 rebuilt** from [omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs)
  PKGBUILDs. Most already declared `aarch64`; the rest needed only an `arch=`
  addition, not code changes.
- **4 core packages** built separately: `omarchy`, `omarchy-settings`,
  `omarchy-keyring`, `ttf-jetbrains-mono-nerd-basic`. The `omarchy` package is
  `arch=any` but hard-depends on the Limine bootloader stack, so we build a
  [patched PKGBUILD](../pkgbuilds/omarchy/PKGBUILD).
- **`nvim`** needs nothing — Arch Linux ARM's `neovim` already provides it.
- **6 dropped** on the `pi5` branch: `asdcontrol`, `qemu-user-static-binfmt`
  (x86-only, no Pi relevance) and `dotnet-runtime`, `pinta`, `obs-studio`,
  `obsidian` (no aarch64 build). None are needed for the desktop.
- **`herdr`** builds on ARM but gets OOM-killed while linking under Docker
  Desktop's default 4 GB. Not an architecture problem — it needs more memory.

### How close to a Pi 5 can we get without one?

No emulator models the BCM2712: QEMU tops out at `raspi4b` (BCM2711, a
hardwired Cortex-A72, no PCIe, no GPU), and this QEMU build has no virgl. So
the Pi-specific risks are split across two harnesses that each cover a slice:

| Harness | Models | Verified |
|---|---|---|
| `scripts/test-raspi4b.sh` | Pi-family SoC (BCM2711), SD controller, the real `linux-rpi` kernel + initramfs from the image | Kernel boots, SD card found (as `mmc1`), root located by **PARTUUID**, ext4 mounted rw, systemd reaches `System Initialization`. Userspace console is invisible there (QEMU cannot clock the BCM2711 PL011), so progress is read from the journal the boot writes onto the image's own root filesystem |
| `scripts/test-a76-nvme.sh` | The Pi 5's **Cortex-A76** core (TCG), root on an emulated **NVMe** controller — the exact path an NVMe HAT takes | Boots by PARTUUID from `nvme0n1p2`; every shipped binary runs with **no illegal-instruction faults**; Hyprland and quickshell start and render; 0 failed units. `omacalc`/`omawrite` exit 134 (SIGABRT) when run with no display — Qt aborting, not an ISA fault; both run under `QT_QPA_PLATFORM=offscreen` |

Not covered by anything virtual: BCM2712 peripherals, RP1, the V3D GPU driver,
and the real firmware's `config.txt` handling. Those need the board.

## Known Pi/ARM gotchas

### Found and fixed in this port

These were hit while getting Omarchy 4.0.1 to install on aarch64. Each is fixed
on the [`pi5` branch](https://github.com/vincenth19/omarchy/tree/pi5).

| Symptom | Cause | Fix |
|---|---|---|
| `bundled Node.js tarball missing` on first install | `install/user/mise-work.sh` globs `node-v*-linux-x64.tar.gz` unconditionally | Derive the suffix from `uname -m` |
| Install step dies before doing anything | `install/hardware/apple/fix-spi-keyboard.sh` reads `/sys/class/dmi/id/product_name`; the Pi has no DMI, so the assignment fails under `bash -eE` | `\|\| true` on the read |
| `Hook 'btrfs-overlayfs' cannot be found` | `omarchy_hooks.conf` HOOKS ends in a hook shipped by the Limine/snapper stack we do not install | Removed by our additive drop-in, not by editing their file |
| `module not found: 'thunderbolt'` | `thunderbolt_module.conf` adds a module the Pi kernel lacks | Removed by our additive drop-in |
| `snapper.sh` exits 127 | snapper is not installed on this port | Skip when the binary is absent |
| pacman left pointing at x86 mirrors | `post-install/pacman.sh` restores `default/pacman/pacman-$OMARCHY_MIRROR.conf`, defaulting to `stable` (Omarchy's Arch mirror has no aarch64 tree, and `[multilib]` does not exist for ARM) | Add a `pi` mirror variant and set `OMARCHY_MIRROR=pi` |

### Build-environment traps (not Omarchy bugs)

| Symptom | Cause |
|---|---|
| Kernel panics with no root device | `mkinitcpio`'s `autodetect` hook trims modules to the *build* machine's hardware. Generic images must not autodetect |
| A rebuilt package has no effect | pacman installs the stale cached tarball, since a rebuild keeps the same version-release. Evict it from the cache first |
| Package build killed while linking | Docker Desktop's 4 GB default. Not an ARM issue — raise the memory or build with `JOBS=1` |
| Script dies mid-run with a syntax error | bash reads scripts incrementally; editing a mounted script while a container runs it corrupts that run. `build-all.sh` snapshots them |

### Expected on real hardware (not yet verified)

| Issue | Mitigation |
|---|---|
| Fractional scaling breaks rendering (black waybar) | Integer scaling only — see [config/hypr/monitors.conf](../config/hypr/monitors.conf) |
| `hyprlock` reported to crash on ARM | Use `hyprlock-git` if it reproduces |
| Chromium unstable on ARM | Brave or Firefox |

Re-verify the third group against current Omarchy and Mesa before carrying the
workaround forward — some may already be fixed upstream.

## Keeping upstream updates safe

How the port avoids letting an Omarchy release break a user's Pi — the
three tiers of patching and the release gate — is in
[ADAPTER.md](ADAPTER.md).

## Update workflow

**Omarchy 4 ships itself as pacman packages, not a git checkout.** The `omarchy`
package installs to `/usr/share/omarchy`, and `omarchy-update` upgrades it from
`pkgs.omarchy.org` — which publishes x86_64 only. So tracking upstream means
rebuilding packages, not pulling a repo.

Two pieces:

**1. Source patches** live on the `pi5` branch of our
[omarchy fork](https://github.com/vincenth19/omarchy), based on the upstream
stable tag. On each upstream release:

```
git fetch upstream --tags
git rebase v<new-tag> pi5
git push --force-with-lease origin pi5
```

**2. Packages** are rebuilt from that branch for aarch64 and published to our
own repo. The upstream PKGBUILD supports `OMARCHY_SRC=/path/to/checkout`, so we
build the patched tree directly rather than maintaining a source fork of the
packaging.

Our `omarchy` PKGBUILD ([pkgbuilds/omarchy](../pkgbuilds/omarchy/PKGBUILD))
drops the `limine` / `limine-mkinitcpio-hook` / `limine-snapper-sync` / `snapper`
hard dependencies. Those assume PC-style UEFI boot and a btrfs root; the Pi
boots from its own firmware off the FAT partition.

Users then update normally — pacman pulls from our aarch64 repo instead of
upstream's x86_64 one. That is what makes this painless for people who are not
maintaining the port.

## Non-goals

- Supporting Pi 4 or other SBCs (until Pi 5 works well)
- Diverging from upstream behavior beyond what ARM/Pi strictly requires
