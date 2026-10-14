#!/bin/sh
# rtsp30-status.sh -- run ON the reCamera: pipeline health + measured encode rate.
say() { printf '%s\n' "$*"; }

say "== processes"
ps | awk '/rtsp30|video_demo/ && !/awk/ {print "  " $0}'
[ -z "$(pidof rtsp30)" ] && say "  rtsp30 NOT RUNNING"

say "== vi  (/proc/cvitek/vi_dbg)"
grep -aE 'VIDevFPS|VIFPS|VISofCh0Cnt|VIPostCnt|VIDropCnt' /proc/cvitek/vi_dbg | sed 's/^/  /'

say "== vpss"
# field offsets: each row starts with '#' GrpID ['#' ChnID], so data begins at $3
awk '/VPSS GRP WORK STATUS/{f=1} f&&/^ *# 0/{printf "  grp  recv=%s lost=%s startfail=%s bStart=%s cost=%sus hw=%sus\n",$3,$4,$5,$6,$7,$9; exit}' /proc/cvitek/vpss
awk '/CHN OUTPUT RESOLUTION/{f=1} f&&/^ *# 0 *# 2/{printf "  chn2 %sx%s %s sendOK=%s fps=%s\n",$6,$7,$8,$11,$12; exit}' /proc/cvitek/vpss
awk '/DRV WORK STATUS DEV1/{f=1} f&&/^ *# 0/{printf "  dev1 trig=%s fail=%s irq=%s overflow=%s\n",$3,$4,$5,$6; exit}' /proc/cvitek/vpss

say "== venc"
sed -n 's/.*No.SendFramePerSec: \([0-9]*\).*No.EncFramePerSec: \([0-9]*\).*HwEncTime: \([0-9]*\).*/  send=\1fps enc=\2fps hw=\3us/p' /proc/cvitek/venc | head -1

say "== vb pool (1080p)"
awk '/PoolId    : 2/{f=1} f&&/^BlkCnt/{b=$3} f&&/^Free/{fr=$3} f&&/^MinFree/{printf "  BlkCnt=%s Free=%s MinFree=%s\n",b,fr,$3; exit}' /proc/cvitek/vb

say "== rtsp port"
netstat -ltn 2>/dev/null | awk '/:8554/{print "  listening " $4}'

say "== measured encode rate (6s)"
e0=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
sleep 6
e1=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
if [ -n "$e0" ] && [ -n "$e1" ]; then
    say "  $(( (e1 - e0) / 6 )) fps  (target: ~30)"
else
    say "  no VENC counters -- pipeline not running"
fi

say "== recent log"
tail -5 /tmp/rtsp30.log 2>/dev/null | sed 's/^/  /'
