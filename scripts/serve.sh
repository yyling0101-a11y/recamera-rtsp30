#!/bin/bash
# serve.sh [PORT] -- host-side development helper for serving this repository.
set -e
cd "$(dirname "$0")/.."
PORT="${1:-8000}"
IP=$(ip -4 addr show 2>/dev/null | awk '/inet .*192\.168/{split($2,a,"/"); print a[1]; exit}')
echo "serving $(pwd) on http://${IP:-<PC_IP>}:$PORT"
echo "This helper only serves repository files; use scripts/install-linux.sh or scripts/install-windows.ps1 to deploy."
exec python3 -m http.server "$PORT"
