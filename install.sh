#!/bin/sh
# =============================================================================
#  rtsp30 installer -- run this ON the Seeed reCamera (SG2002 / CV181X).
#
#  Downloads the prebuilt executable + autostart scripts (no compilation),
#  stops whatever else owns the camera pipeline, installs, starts and verifies.
#  Safe to run repeatedly: every step is idempotent.
#
#  One-liner (device must be able to resolve GitHub):
#    wget -qO- https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sh
#
#  LAN mirror (device has no GitHub access -- run on your PC first:
#              `cd <repo> && python3 -m http.server 8000`):
#    wget -qO- http://<PC_IP>:8000/install.sh | sh -s -- --base-url http://<PC_IP>:8000
#
#  Offline (copy the repo to the device first, e.g. scp -r . root@<ip>:/tmp/repo):
#    sh /tmp/repo/install.sh --from-dir /tmp/repo
#
#  Options:
#    --base-url URL    download base URL (skips GitHub + mirrors)
#    --from-dir DIR    install from a local directory, no download
#    --branch BR       GitHub branch/tag (default: main)
#    --no-start        install + enable autostart, but do not start now
#    --no-autostart    do not install /etc/init.d/S99rtsp30
#    --uninstall       remove rtsp30 and its autostart entry
#    -h | --help
# =============================================================================
set -u

# ---- edit this once when you publish the repo -------------------------------
REPO="${RTSP30_REPO:-OWNER/recamera-rtsp30}"
BRANCH="${RTSP30_BRANCH:-main}"
# ----------------------------------------------------------------------------

# Mirrors tried in order when the plain GitHub raw URL is unreachable.
MIRRORS="
https://raw.githubusercontent.com
https://ghproxy.net/https://raw.githubusercontent.com
https://gh-proxy.com/https://raw.githubusercontent.com
https://mirror.ghproxy.com/https://raw.githubusercontent.com
"

APP_DIR=/root
INIT_DIR=/etc/init.d
INIT_NAME=S99rtsp30
SUPFILE=/var/run/rtsp30.sup
LOG=/tmp/rtsp30.log
PORT=8554
BASE_URL=""
FROM_DIR=""
DO_START=1
DO_AUTOSTART=1
DO_UNINSTALL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --base-url)    BASE_URL="${2:-}"; shift 2 ;;
        --from-dir)    FROM_DIR="${2:-}"; shift 2 ;;
        --branch)      BRANCH="${2:-}"; shift 2 ;;
        --no-start)    DO_START=0; shift ;;
        --no-autostart) DO_AUTOSTART=0; shift ;;
        --uninstall)   DO_UNINSTALL=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------- preconditions
[ "$(id -u)" = 0 ] || die "must run as root"
[ -d /proc/cvitek ] || die "/proc/cvitek missing -- this does not look like a CVITEK/SG2002 board"
ARCH=$(uname -m)
case "$ARCH" in
    riscv64) ;;
    *) die "unsupported arch '$ARCH' (the prebuilt binary is riscv64 musl)" ;;
esac

# Rootfs is mounted read-only; /root and /etc are overlays on /userdata.
# Make sure they are writable before touching them.
if ! touch "$APP_DIR/.wtest" 2>/dev/null; then
    if command -v rootfs_rw >/dev/null 2>&1; then
        warn "$APP_DIR not writable -- running 'rootfs_rw on'"
        rootfs_rw on >/dev/null 2>&1
        mount -o remount,rw / >/dev/null 2>&1
    fi
    touch "$APP_DIR/.wtest" 2>/dev/null || die "$APP_DIR is not writable (try: rootfs_rw on)"
fi
rm -f "$APP_DIR/.wtest"

# -------------------------------------------------------------------- download
DL_DIR=/tmp/rtsp30.dl

fetch_one() {  # fetch_one URL DEST
    url=$1; dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 120 -o "$dest" "$url" 2>/dev/null && return 0
    fi
    wget -q -T 15 -t 1 -O "$dest" "$url" 2>/dev/null && return 0
    return 1
}

fetch() {  # fetch PATH DEST -- try every base URL until one works
    rel=$1; dest=$2
    if [ -n "$FROM_DIR" ]; then
        [ -f "$FROM_DIR/$rel" ] || die "missing $FROM_DIR/$rel"
        cp "$FROM_DIR/$rel" "$dest" || die "copy failed: $rel"
        return 0
    fi
    if [ -n "$BASE_URL" ]; then
        say "  GET ${BASE_URL%/}/$rel"
        fetch_one "${BASE_URL%/}/$rel" "$dest" || die "download failed: ${BASE_URL%/}/$rel"
        return 0
    fi
    case "$REPO" in
        OWNER/*) die "repository not configured: edit REPO= in install.sh (or pass RTSP30_REPO=owner/name)" ;;
    esac
    for m in $MIRRORS; do
        url="${m%/}/$REPO/$BRANCH/$rel"
        say "  GET $url"
        if fetch_one "$url" "$dest"; then
            [ -s "$dest" ] && return 0
        fi
    done
    die "all download sources failed for $rel
       Common causes: the device cannot resolve github.com (DNS poisoning) or has no CA certs.
       Workarounds:
         1) LAN mirror : on your PC  'cd <repo> && python3 -m http.server 8000'
                         on device   'sh install.sh --base-url http://<PC_IP>:8000'
         2) offline    : 'scp -r <repo> root@<device-ip>:/tmp/repo && sh /tmp/repo/install.sh --from-dir /tmp/repo'"
}

# ---------------------------------------------------------------------- stop old
stop_streamers() {
    # Supervisors first so they cannot respawn their app.
    for p in $(ps | awk '/rtsp30\.sh|fps30\.sh|S99rtsp30|S99fps30/ && !/awk/ {print $1}'); do
        kill -9 "$p" 2>/dev/null
    done
    rm -f "$SUPFILE" /var/run/fps30.sup
    # SIGTERM the media apps: they tear the pipeline down cleanly. SIGKILL leaves
    # VENC/VPSS driver state wedged and the next start stalls at 0 fps.
    for name in rtsp30 fps30 video_demo; do
        pid=$(pidof "$name") && kill -TERM "$pid" 2>/dev/null
    done
    i=0
    while [ $i -lt 60 ] && [ -n "$(pidof rtsp30 fps30 video_demo)" ]; do
        usleep 250000 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    for name in rtsp30 fps30 video_demo; do
        pid=$(pidof "$name") && { warn "SIGKILL $name (pid $pid) -- a reboot may be needed"; kill -9 "$pid"; }
    done
    sleep 1
}

# --------------------------------------------------------------- sscma services
check_sscma() {
    for s in S91sscma-node S92node-red S93sscma-supervisor; do
        if [ -f "$INIT_DIR/$s" ]; then
            warn "$s is enabled and will fight for the camera pipeline."
            warn "  disable with:  mkdir -p $INIT_DIR/disabled && mv $INIT_DIR/$s $INIT_DIR/disabled/"
        fi
    done
}

# -------------------------------------------------------------------- uninstall
if [ "$DO_UNINSTALL" = 1 ]; then
    say "Uninstalling rtsp30 ..."
    stop_streamers
    [ -f "$INIT_DIR/$INIT_NAME" ] && { rm -f "$INIT_DIR/$INIT_NAME"; ok "removed $INIT_DIR/$INIT_NAME"; }
    for f in "$APP_DIR/rtsp30" "$APP_DIR/rtsp30.sh" "$APP_DIR/uninstall-rtsp30.sh" \
             "$APP_DIR/rtsp30-status.sh" "$APP_DIR/rtsp30-sample.sh"; do
        [ -e "$f" ] && { rm -f "$f"; ok "removed $f"; }
    done
    say "Done. The stock firmware is untouched; reboot to return to the factory boot sequence."
    exit 0
fi

# ----------------------------------------------------------------------- install
say "rtsp30 installer"
say "  target : $ARCH reCamera (CVITEK), app dir $APP_DIR"
[ -n "$FROM_DIR" ] && say "  source : local dir $FROM_DIR"
[ -n "$BASE_URL" ] && say "  source : $BASE_URL"
[ -z "$FROM_DIR" ] && [ -z "$BASE_URL" ] && say "  source : github.com/$REPO@$BRANCH"

stop_streamers
mkdir -p "$DL_DIR"

say "Downloading ..."
fetch bin/rtsp30          "$DL_DIR/rtsp30"
fetch bin/rtsp30.sha256   "$DL_DIR/rtsp30.sha256"
fetch etc/rtsp30.sh       "$DL_DIR/rtsp30.sh"
fetch etc/S99rtsp30       "$DL_DIR/S99rtsp30"
# optional helpers: <repo path>:<on-device name>
HELPERS="scripts/rtsp30-status.sh:rtsp30-status.sh
scripts/uninstall-rtsp30.sh:uninstall-rtsp30.sh
scripts/sample.sh:rtsp30-sample.sh"
for pair in $HELPERS; do
    rel=${pair%%:*}; name=${pair##*:}
    fetch "$rel" "$DL_DIR/$name" || warn "optional $rel unavailable"
done
ok "downloaded"

# Integrity check: refuse to install a truncated / HTML-error-page "binary".
want=$(awk '{print $1}' "$DL_DIR/rtsp30.sha256" 2>/dev/null)
got=$(sha256sum "$DL_DIR/rtsp30" 2>/dev/null | awk '{print $1}')
[ -n "$want" ] || die "checksum file is empty"
[ "$want" = "$got" ] || die "checksum mismatch: expected $want got $got"
ok "sha256 ${got%${got#??????????????}}..."

head -c 4 "$DL_DIR/rtsp30" | grep -q "ELF" || die "rtsp30 is not an ELF binary (proxy returned an error page?)"

# Legacy names from earlier revisions.
for f in "$APP_DIR/fps30" "$APP_DIR/fps30.sh" "$INIT_DIR/S99fps30"; do
    [ -e "$f" ] && { rm -f "$f"; ok "removed legacy $f"; }
done

install -m 0755 "$DL_DIR/rtsp30"    "$APP_DIR/rtsp30"       2>/dev/null \
    || { cp "$DL_DIR/rtsp30" "$APP_DIR/rtsp30" && chmod 0755 "$APP_DIR/rtsp30"; }
install -m 0755 "$DL_DIR/rtsp30.sh" "$APP_DIR/rtsp30.sh"     2>/dev/null \
    || { cp "$DL_DIR/rtsp30.sh" "$APP_DIR/rtsp30.sh" && chmod 0755 "$APP_DIR/rtsp30.sh"; }
for pair in $HELPERS; do
    name=${pair##*:}
    [ -s "$DL_DIR/$name" ] && { cp "$DL_DIR/$name" "$APP_DIR/$name"; chmod 0755 "$APP_DIR/$name"; }
done
ok "installed $APP_DIR/rtsp30 + $APP_DIR/rtsp30.sh"

if [ "$DO_AUTOSTART" = 1 ]; then
    cp "$DL_DIR/S99rtsp30" "$INIT_DIR/$INIT_NAME" && chmod 0755 "$INIT_DIR/$INIT_NAME"
    ok "autostart $INIT_DIR/$INIT_NAME (persists: /etc is an overlay on /userdata)"
fi

check_sscma

if [ "$DO_START" = 1 ]; then
    say "Starting ..."
    rm -f "$LOG"
    if [ "$DO_AUTOSTART" = 1 ]; then
        sh "$INIT_DIR/$INIT_NAME" start >/dev/null 2>&1
    else
        setsid "$APP_DIR/rtsp30.sh" >/dev/null 2>&1 &
    fi

    # Wait for the pipeline to come up and prove frames are actually encoded.
    i=0
    while [ $i -lt 40 ] && [ -z "$(pidof rtsp30)" ]; do usleep 250000 2>/dev/null || sleep 1; i=$((i + 1)); done
    [ -n "$(pidof rtsp30)" ] || die "rtsp30 did not start; see $LOG"
    sleep 8
    e0=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
    sleep 6
    e1=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
    rate=0
    [ -n "$e0" ] && [ -n "$e1" ] && rate=$(( (e1 - e0) / 6 ))

    IP=$(ip -4 addr show 2>/dev/null | awk '/inet .*eth0|inet .*wlan0/{split($2,a,"/"); print a[1]; exit}')
    [ -z "$IP" ] && IP=$(ifconfig 2>/dev/null | awk '/inet addr:192\.168/{split($2,a,":"); split(a[2],b," "); print b[1]; exit}')
    [ -z "$IP" ] && IP="<device-ip>"

    say ""
    if [ "$rate" -ge 25 ]; then
        ok "encoder running at ~$rate fps"
    elif [ "$rate" -gt 0 ]; then
        warn "encoder only at ~$rate fps -- check $LOG and 'sh $APP_DIR/rtsp30-status.sh'"
    else
        warn "encoder produced no frames. Most likely the previous owner of the"
        warn "pipeline was SIGKILLed and left the driver wedged: reboot the board"
        warn "and rtsp30 will come up at 30 fps. (the watchdog reboots automatically)"
    fi
    say ""
    say "  stream   rtsp://$IP:$PORT/live0   (1920x1080 H.264, ~30 fps)"
    say "  test     ffplay rtsp://$IP:$PORT/live0"
    say "  status   sh $APP_DIR/rtsp30-status.sh"
    say "  log      tail -f $LOG"
    say "  stop     $INIT_DIR/$INIT_NAME stop"
    say "  remove   sh $APP_DIR/uninstall-rtsp30.sh"
fi
exit 0
