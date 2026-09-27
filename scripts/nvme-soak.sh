#!/bin/bash
# nvme-soak — write every block of an NVMe drive once, read it all back and
# verify it, while logging the Pi's 5 V rail, throttle flags and temperatures
# every second.
#
#   sudo scripts/nvme-soak.sh /dev/nvme0n1
#
# DESTROYS ALL DATA on the target. Run it from a system that does not live on
# the target (the Pi booted from SD). Written 2026-09-27 for a drive whose
# writes stalled silently twice while it held the root filesystem: with root
# elsewhere, a stall now shows up in the kernel log instead of freezing the box.
#
# Output in $OUT (default /var/log/nvme-soak):
#   fio.log      progress every 15 s, then the result; "verify" errors are fatal
#   sensors.csv  ts,throttled,ext5v_v,soc_mc,nvme_mc,sect_written,sect_read
# Watch: systemctl status nvme-soak; journalctl -k -f | grep -iE 'nvme|voltage'
set -euo pipefail

DEV=${1:?usage: nvme-soak.sh /dev/nvmeXn1}
OUT=${OUT:-/var/log/nvme-soak}
dn=$(basename "$DEV")

[[ -b $DEV ]] || { echo "not a block device: $DEV" >&2; exit 1; }
if [[ $(findmnt -no SOURCE /) == "$DEV"* ]]; then
  echo "refusing: the root filesystem is on $DEV" >&2; exit 1
fi
if findmnt -rn -o SOURCE | grep -q "^$DEV"; then
  echo "refusing: $DEV has mounted partitions (umount them first)" >&2; exit 1
fi

pacman -S --needed --noconfirm fio >/dev/null
mkdir -p "$OUT"
blockdev --setrw "$DEV"
for p in "$DEV"p*; do [[ -b $p ]] && blockdev --setrw "$p"; done

nvme_temp=""
for h in /sys/class/hwmon/hwmon*; do
  [[ $(cat "$h/name") == nvme ]] && nvme_temp=$h/temp1_input
done

cat > "$OUT/sensors.sh" <<'SENSORS'
#!/bin/bash
# /sys/block/<dev>/stat fields 3 and 7: sectors read, sectors written.
echo "ts,throttled,ext5v_v,soc_mc,nvme_mc,sect_written,sect_read" > "$OUT/sensors.csv"
while :; do
  read -r _ _ sr _ _ _ sw _ < "/sys/block/$DN/stat"
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date +%T)" \
    "$(vcgencmd get_throttled | cut -d= -f2)" \
    "$(vcgencmd pmic_read_adc EXT5V_V | sed -E 's/.*=([0-9.]+)V/\1/')" \
    "$(cat /sys/class/thermal/thermal_zone0/temp)" \
    "$(cat "$NVME_TEMP" 2>/dev/null)" "$sw" "$sr" >> "$OUT/sensors.csv"
  sleep 1
done
SENSORS

systemctl stop nvme-soak nvme-soak-sensors 2>/dev/null || true
systemd-run --quiet --unit=nvme-soak-sensors --collect \
  -E OUT="$OUT" -E DN="$dn" -E NVME_TEMP="$nvme_temp" bash "$OUT/sensors.sh"

systemd-run --quiet --unit=nvme-soak --collect \
  -p StandardOutput=append:"$OUT/fio.log" -p StandardError=append:"$OUT/fio.log" \
  -p ExecStopPost="systemctl stop nvme-soak-sensors" \
  fio --name=soak --filename="$DEV" --rw=write --bs=1M --direct=1 \
      --ioengine=libaio --iodepth=16 --refill_buffers \
      --verify=crc32c --verify_fatal=1 --eta=always --eta-newline=15

[[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER": "$OUT"
echo "started on $DEV; logs in $OUT"
