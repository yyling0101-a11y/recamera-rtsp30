#!/bin/bash
# serve.sh [PORT] -- host-side: serve this repo over HTTP so a reCamera that
# cannot reach GitHub can still run install.sh against the LAN mirror.
#   PC:     ./scripts/serve.sh 8000
#   device: wget -qO- http://<PC_IP>:8000/install.sh | sh -s -- --base-url http://<PC_IP>:8000
set -e
cd "$(dirname "$0")/.."
PORT="${1:-8000}"
IP=$(ip -4 addr show 2>/dev/null | awk '/inet .*192\.168/{split($2,a,"/"); print a[1]; exit}')
echo "serving $(pwd) on http://${IP:-<PC_IP>}:$PORT"
echo "on the reCamera run:"
echo "  wget -qO- http://${IP:-<PC_IP>}:$PORT/install.sh | sh -s -- --base-url http://${IP:-<PC_IP>}:$PORT"
exec python3 -m http.server "$PORT"
