#!/bin/sh
# sample.sh [SECONDS] -- run ON the reCamera: per-stage frame rates over a window.
# Shows exactly where frames are lost when the stream is below 30 fps.
N="${1:-10}"
get() {
    SOF=$(sed -n 's/^VISofCh0Cnt[ \t]*:[ \t]*\([0-9]*\).*/\1/p' /proc/cvitek/vi_dbg)
    POST=$(sed -n 's/^VIPostCnt[ \t]*:[ \t]*\([0-9]*\).*/\1/p' /proc/cvitek/vi_dbg)
    DROP=$(sed -n 's/^VIDropCnt[ \t]*:[ \t]*\([0-9]*\).*/\1/p' /proc/cvitek/vi_dbg)
    RECV=$(awk '/VPSS GRP WORK STATUS/{f=1} f&&/^ *# 0/{print $3; exit}' /proc/cvitek/vpss)
    FAIL=$(awk '/DRV WORK STATUS DEV1/{f=1} f&&/^ *# 0/{print $4; exit}' /proc/cvitek/vpss)
    COST=$(awk '/VPSS GRP WORK STATUS/{f=1} f&&/^ *# 0/{print $7, $9; exit}' /proc/cvitek/vpss)
    ENC=$(sed -n 's/.*EncodedFrame: \([0-9]*\).*/\1/p' /proc/cvitek/venc | head -1)
    FREE=$(awk '/PoolId    : 2/{f=1} f&&/^Free/{print $3; exit}' /proc/cvitek/vb)
}
get; T0=$(date +%s); S0=$SOF; P0=$POST; R0=$RECV; F0=$FAIL; E0=$ENC; D0=$DROP
sleep "$N"
get; T1=$(date +%s); EL=$((T1 - T0)); [ "$EL" -lt 1 ] && EL=1
echo "window=${EL}s"
echo "  sensor SOF    $(( (SOF - S0) / EL )) fps"
echo "  VI post       $(( (POST - P0) / EL )) fps   drop+$((DROP - D0))"
echo "  VPSS recv     $(( (RECV - R0) / EL )) fps   startfail+$((FAIL - F0))"
echo "  VENC encoded  $(( (ENC - E0) / EL )) fps"
echo "  VPSS cost(avg,hw) = $COST us"
echo "  VB pool free  $FREE"
