#!/bin/sh
# =============================================================================
#  remote-install.sh -- runs ON the reCamera as root.
#
#  Installs the files that were staged in $STAGE_DIR by a PC-side installer.
#
#  Steps: disable node-red + sscma services -> stop anything owning the camera
#         pipeline -> install binary/supervisor/init script -> start -> verify.
#  Idempotent: safe to run as many times as you like.
# =============================================================================
set -u

STAGE_DIR=${STAGE_DIR:-/tmp/rtsp30-install}
APP_DIR=/root
INIT_DIR=/etc/init.d
INIT_NAME=S99rtsp30
SUPFILE=/var/run/rtsp30.sup
LOG=/tmp/rtsp30.log
PORT=8554

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root (the PC installer elevates with sudo for you)"
[ -d /proc/cvitek ] || die "/proc/cvitek missing -- not a CVITEK/SG2002 board?"
case "$(uname -m)" in
    riscv64) ;;
    *) die "unsupported arch '$(uname -m)' (the prebuilt binary is riscv64 musl)" ;;
esac
[ -f "$STAGE_DIR/rtsp30" ] || die "staged files not found in $STAGE_DIR"

# ------------------------------------------------- 1. disable node-red / sscma
# These own the camera pipeline and port 8554; rtsp30 cannot run alongside them.
# Firmware revisions name these services differently, so match the service names
# and move their init scripts into the requested disable directory.
DISABLE_DIR="$INIT_DIR/disable"

disable_services() {
    mkdir -p "$DISABLE_DIR" 2>/dev/null
    found=0
    for f in "$INIT_DIR"/*node-red* "$INIT_DIR"/*sscma-node* "$INIT_DIR"/*sscma-supervisor*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        found=1
        sh "$f" stop >/dev/null 2>&1
        mv "$f" "$DISABLE_DIR/$name" 2>/dev/null \
            && ok "disabled $name -> $DISABLE_DIR/" \
            || warn "could not move $name (already disabled?)"
    done
    [ "$found" = 0 ] && ok "node-red / sscma services already disabled"
    # A moved init script does not kill what is already running.
    for p in node-red sscma_supervisor sscma-supervisor maix sscma; do
        pid=$(pidof "$p" 2>/dev/null) && { kill -TERM $pid 2>/dev/null; ok "stopped running $p (pid $pid)"; }
    done
    pid=$(pidof node 2>/dev/null) && { kill -TERM $pid 2>/dev/null; ok "stopped running node/node-red (pid $pid)"; }
}

# ------------------------------------------------------ 2. free the media stack
stop_streamers() {
    for p in $(ps | awk '/rtsp30\.sh|fps30\.sh|S99rtsp30|S99fps30/ && !/awk/ {print $1}'); do
        kill -9 "$p" 2>/dev/null
    done
    rm -f "$SUPFILE" /var/run/fps30.sup
    # SIGTERM first: the app tears the CVI pipeline down cleanly. A SIGKILLed
    # pipeline leaves VENC/VPSS driver state wedged and needs a reboot.
    for name in rtsp30 fps30 video_demo; do
        pid=$(pidof "$name") && kill -TERM "$pid" 2>/dev/null
    done
    i=0
    while [ $i -lt 60 ] && [ -n "$(pidof rtsp30 fps30 video_demo)" ]; do
        usleep 250000 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    for name in rtsp30 fps30 video_demo; do
        pid=$(pidof "$name") && { warn "SIGKILL $name (pid $pid) -- reboot recommended"; kill -9 "$pid"; }
    done
    sleep 1
}

# ------------------------------------------------------------ 3. writable rootfs
ensure_writable() {
    touch "$APP_DIR/.wtest" 2>/dev/null && { rm -f "$APP_DIR/.wtest"; return 0; }
    if command -v rootfs_rw >/dev/null 2>&1; then
        warn "$APP_DIR not writable -- running 'rootfs_rw on'"
        rootfs_rw on >/dev/null 2>&1
        mount -o remount,rw / >/dev/null 2>&1
    fi
    touch "$APP_DIR/.wtest" 2>/dev/null || die "$APP_DIR not writable (try: rootfs_rw on)"
    rm -f "$APP_DIR/.wtest"
}

say "rtsp30 on-device installer"
say "  stage dir : $STAGE_DIR"
say "  app dir   : $APP_DIR"

say "Disabling node-red / sscma ..."
disable_services

say "Stopping current media pipeline ..."
stop_streamers

ensure_writable

# ------------------------------------------------------------------- 4. install
head -c 4 "$STAGE_DIR/rtsp30" | grep -q "ELF" || die "$STAGE_DIR/rtsp30 is not an ELF binary"
if [ -f "$STAGE_DIR/rtsp30.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    want=$(awk '{print $1}' "$STAGE_DIR/rtsp30.sha256")
    got=$(sha256sum "$STAGE_DIR/rtsp30" | awk '{print $1}')
    [ "$want" = "$got" ] || die "sha256 mismatch: expected $want got $got"
    ok "sha256 verified ${want%${want#??????????????}}..."
fi

# legacy names from earlier revisions
for f in "$APP_DIR/fps30" "$APP_DIR/fps30.sh" "$INIT_DIR/S99fps30"; do
    [ -e "$f" ] && { rm -f "$f"; ok "removed legacy $f"; }
done

cp "$STAGE_DIR/rtsp30"    "$APP_DIR/rtsp30"    && chmod 0755 "$APP_DIR/rtsp30"
cp "$STAGE_DIR/rtsp30.sh" "$APP_DIR/rtsp30.sh" && chmod 0755 "$APP_DIR/rtsp30.sh"
ok "installed $APP_DIR/rtsp30 + $APP_DIR/rtsp30.sh"

for pair in rtsp30-status.sh rtsp30-sample.sh uninstall-rtsp30.sh; do
    [ -f "$STAGE_DIR/$pair" ] && { cp "$STAGE_DIR/$pair" "$APP_DIR/$pair"; chmod 0755 "$APP_DIR/$pair"; }
done

cp "$STAGE_DIR/S99rtsp30" "$INIT_DIR/$INIT_NAME" && chmod 0755 "$INIT_DIR/$INIT_NAME"
ok "autostart $INIT_DIR/$INIT_NAME (persists: /etc is an overlay on /userdata)"

# -------------------------------------------------------------------- 5. start
say "Starting ..."
rm -f "$LOG"
setsid "$INIT_DIR/$INIT_NAME" start >/dev/null 2>&1
i=0
while [ $i -lt 40 ] && [ -z "$(pidof rtsp30)" ]; do usleep 250000 2>/dev/null || sleep 1; i=$((i + 1)); done
[ -n "$(pidof rtsp30)" ] || die "rtsp30 did not start; see $LOG"
sleep 8
e0=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
sleep 6
e1=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
rate=0
[ -n "$e0" ] && [ -n "$e1" ] && rate=$(( (e1 - e0) / 6 ))

IP=$(ip -4 addr show 2>/dev/null | awk '/inet .*(eth0|wlan0|usb0)/{split($2,a,"/"); print a[1]; exit}')
[ -z "$IP" ] && IP="<device-ip>"

say ""
if [ "$rate" -ge 25 ]; then
    ok "encoder running at ~$rate fps"
elif [ "$rate" -gt 0 ]; then
    warn "encoder only at ~$rate fps -- see $LOG and 'sh $APP_DIR/rtsp30-status.sh'"
else
    warn "encoder produced no frames. Usually the previous owner of the pipeline"
    warn "was SIGKILLed and left the driver wedged: reboot and rtsp30 will come up"
    warn "at 30 fps (the watchdog also reboots automatically within ~2 minutes)."
fi
say ""
say "  stream   rtsp://$IP:$PORT/live0   (1920x1080 H.264, ~30 fps)"
say "  test     ffplay rtsp://$IP:$PORT/live0"
say "  status   sh $APP_DIR/rtsp30-status.sh"
say "  log      tail -f $LOG"
say "  stop     $INIT_DIR/$INIT_NAME stop"
say "  remove   sh $APP_DIR/uninstall-rtsp30.sh"
exit 0
