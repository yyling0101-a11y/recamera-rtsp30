#!/bin/sh
# uninstall-rtsp30.sh -- run ON the reCamera: stop and remove rtsp30 completely.
# The stock firmware is never modified, so a reboot returns the board to factory boot.
SUPFILE=/var/run/rtsp30.sup

for p in $(ps | awk '/rtsp30\.sh|S99rtsp30/ && !/awk/ {print $1}'); do kill -9 "$p" 2>/dev/null; done
[ -f "$SUPFILE" ] && kill "$(cat $SUPFILE)" 2>/dev/null
pid=$(pidof rtsp30) && kill -TERM "$pid" 2>/dev/null
i=0
while [ $i -lt 40 ] && [ -n "$(pidof rtsp30)" ]; do usleep 250000 2>/dev/null || sleep 1; i=$((i + 1)); done
killall -9 rtsp30 2>/dev/null

rm -f /etc/init.d/S99rtsp30 /etc/init.d/S99fps30
rm -f /root/rtsp30 /root/rtsp30.sh /root/rtsp30-status.sh /root/uninstall-rtsp30.sh
rm -f /root/fps30 /root/fps30.sh "$SUPFILE" /var/run/fps30.sup
echo "rtsp30 removed. Reboot to return to the factory boot sequence."
