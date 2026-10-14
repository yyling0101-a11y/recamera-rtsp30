#!/bin/bash
# probe.sh [RTSP_URL] [SECONDS] -- host-side frame-rate meter (needs ffprobe).
# Measures decoded-frame timestamps, so it reports what a client actually receives.
URL="${1:-rtsp://192.168.4.82:8554/live0}"
DUR="${2:-15}"
TRANSPORT="${TRANSPORT:-udp}"
OUT=$(timeout $((DUR + 20)) ffprobe -hide_banner -loglevel error -rtsp_transport "$TRANSPORT" \
  -i "$URL" -select_streams v:0 -show_entries frame=pts_time \
  -of csv=p=0 -read_intervals "%+$DUR" 2>/dev/null)
echo "$OUT" | awk -v url="$URL" -v tr="$TRANSPORT" '
  NF && $1+0==$1 { t[NR]=$1+0; n++ }
  END{
    if (n<3) { printf "frames=%d -- NOT ENOUGH DATA\n", n; exit 1 }
    span=t[n]-t[1]
    printf "url=%s transport=%s frames=%d span=%.3fs avg_fps=%.2f\n", url, tr, n, span, (n-1)/span
    for(i=2;i<=n;i++){ d=t[i]-t[i-1]; s+=d; if(d>mx)mx=d; if(mn==""||d<mn)mn=d; h[int(d*100)]++ }
    printf "delta_ms: min=%.1f max=%.1f mean=%.2f\n", mn*1000, mx*1000, s/(n-1)*1000
    printf "hist(10ms buckets): "
    for(k=0;k<=200;k++) if(h[k]) printf "%d:%d ", k, h[k]
    printf "\n"
  }'
