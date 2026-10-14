#!/bin/sh
# rtsp30.sh -- supervise the 1080p30 H.264 RTSP publisher (/root/rtsp30).
#
#   stream: rtsp://<device-ip>:8554/live0     log: /tmp/rtsp30.log
#   stop:   /etc/init.d/S99rtsp30 stop        (SIGTERM -- never kill -9, see README)
#
# The pipeline knobs are exported EXPLICITLY so an inherited environment (e.g. a
# stray RC_VB_BLKS=4) cannot silently throttle the stream back to 10 fps.
# Root cause of the stock 10 fps: VPSS chn u32Depth=3 pins 3 of the 4 VB pool
# blocks, so the ISP only processes 1 of every 3 sensor frames.
export LD_LIBRARY_PATH=/mnt/system/usr/lib:/mnt/system/usr/lib/3rd:/mnt/system/lib
export RC_WIDTH=${RC_WIDTH:-1920}
export RC_HEIGHT=${RC_HEIGHT:-1080}
export RC_FPS=${RC_FPS:-30}
export RC_VB_BLKS=${RC_VB_BLKS:-8}       # >= depth + in-flight + headroom
export RC_VPSS_DEPTH=${RC_VPSS_DEPTH:-1} # a VENC-bound channel needs no user queue
export RC_BITRATE=${RC_BITRATE:-4096}    # kbps; stock 1000 kbps is poor for 1080p30
export RC_GOP=${RC_GOP:-30}
export RC_ESBUF_KB=${RC_ESBUF_KB:-1024}
export RC_VIVPSS_MODE=${RC_VIVPSS_MODE:-1}   # VI_OFFLINE_VPSS_ONLINE (0 stalls the pipe)

APP=/root/rtsp30
LOG=/tmp/rtsp30.log
SUPFILE=/var/run/rtsp30.sup
STALL_LIMIT=${STALL_LIMIT:-6}     # 6 x 5s without a newly encoded frame -> restart app
REBOOT_LIMIT=${REBOOT_LIMIT:-3}   # consecutive failed recoveries -> reboot the board

# busybox has no pkill: enforce a single instance through the pidfile.
if [ -f "$SUPFILE" ] && kill -0 "$(cat $SUPFILE 2>/dev/null)" 2>/dev/null; then
    echo "[supervisor] already running (pid $(cat $SUPFILE)), not starting a second one" >> $LOG
    exit 0
fi
echo $$ > "$SUPFILE"

enc_frames() {
    sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1
}

watchdog() {
    stall=0; ok=0; failed=0; last=""
    while :; do
        sleep 5
        pid=$(pidof rtsp30)
        cur=$(enc_frames)
        if [ -z "$pid" ] || [ -z "$cur" ]; then
            stall=0; last=$cur; continue
        fi
        if [ "$cur" = "$last" ]; then stall=$((stall + 1)); else stall=0; fi
        last=$cur
        if [ "$stall" -ge "$STALL_LIMIT" ]; then
            failed=$((failed + 1))
            echo "[watchdog] encoder stalled, recovery #$failed (pid $pid)" >> $LOG
            kill -TERM $pid 2>/dev/null
            stall=0
            if [ "$failed" -ge "$REBOOT_LIMIT" ]; then
                echo "[watchdog] pipeline unrecoverable, rebooting" >> $LOG
                sync
                reboot
            fi
        elif [ "$failed" -gt 0 ]; then
            ok=$((ok + 1))
            [ "$ok" -ge 12 ] && { failed=0; ok=0; }
        fi
    done
}

cleanup() {
    trap - TERM INT
    [ -n "$wd" ] && kill "$wd" 2>/dev/null
    [ -n "$app" ] && kill -TERM "$app" 2>/dev/null
    i=0
    while [ $i -lt 40 ] && [ -n "$app" ] && kill -0 "$app" 2>/dev/null; do
        usleep 250000; i=$((i + 1))
    done
    rm -f "$SUPFILE"
    echo "[supervisor] stopped" >> $LOG
    exit 0
}
trap cleanup TERM INT

watchdog &
wd=$!
echo "[supervisor] pid $$ watchdog $wd logging to $LOG" >> $LOG

cd /root || exit 1
while :; do
    "$APP" >> $LOG 2>&1 &
    app=$!
    wait "$app"
    app=""
    echo "[supervisor] rtsp30 exited, restarting in 2s" >> $LOG
    sleep 2
done
