#!/usr/bin/env python3
"""Push the repo artifacts to the reCamera over SSH and start the service.

This is the PC-side path for a device that cannot reach GitHub; it is exactly
what the PC-side install scripts do, using the checked-out working tree.

    RC_PASS=123123 ./tools/deploy.py            # install + start + verify
    RC_PASS=123123 ./tools/deploy.py --no-start

Credentials come from the environment: RC_HOST, RC_USER, RC_PASS (or RC_KEY).
"""
import os
import stat
import sys

import paramiko

HOST = os.environ.get("RC_HOST", "192.168.4.82")
USER = os.environ.get("RC_USER", "root")
PASS = os.environ.get("RC_PASS", "")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = [
    ("bin/rtsp30", "/root/rtsp30"),
    ("etc/rtsp30.sh", "/root/rtsp30.sh"),
    ("etc/S99rtsp30", "/etc/init.d/S99rtsp30"),
    ("scripts/rtsp30-status.sh", "/root/rtsp30-status.sh"),
    ("scripts/uninstall-rtsp30.sh", "/root/uninstall-rtsp30.sh"),
    ("scripts/sample.sh", "/root/rtsp30-sample.sh"),
]

# Same sequence the remote installer uses: supervisors first, then SIGTERM of
# the media app so the CVI pipeline is torn down cleanly.
STOP = r"""
for p in $(ps | awk '/rtsp30\.sh|fps30\.sh|S99rtsp30|S99fps30/ && !/awk/ {print $1}'); do
    kill -9 $p 2>/dev/null
done
rm -f /var/run/rtsp30.sup /var/run/fps30.sup
for p in rtsp30 fps30 video_demo; do pid=$(pidof $p) && kill -TERM $pid; done
i=0
while [ $i -lt 60 ] && [ -n "$(pidof rtsp30 fps30 video_demo)" ]; do usleep 250000; i=$((i+1)); done
killall -9 rtsp30 fps30 video_demo 2>/dev/null
rm -f /etc/init.d/S99fps30 /root/fps30 /root/fps30.sh
sleep 1
echo "remaining: $(pidof rtsp30 fps30 video_demo)"
"""

START = ("rm -f /tmp/rtsp30.log; sh /etc/init.d/S99rtsp30 start; sleep 14; "
         "grep -a 'supervisor\\|\\[rtsp30\\]' /tmp/rtsp30.log | tail -3; "
         "sh /root/rtsp30-status.sh | tail -14")


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = os.path.expanduser(os.environ.get("RC_KEY", "~/.ssh/id_rsa"))
    try:
        c.connect(HOST, username=USER, key_filename=key, timeout=15,
                  look_for_keys=True, allow_agent=False)
    except Exception:
        if not PASS:
            raise SystemExit("set RC_PASS (or install your SSH key) to connect")
        c.connect(HOST, username=USER, password=PASS, timeout=15,
                  look_for_keys=False, allow_agent=False)
    return c


def main():
    c = connect()
    print(c.exec_command(STOP)[1].read().decode(errors="replace").strip())
    sftp = c.open_sftp()
    for src, dst in FILES:
        local = os.path.join(ROOT, src)
        if not os.path.exists(local):
            print("skip (missing): %s" % src)
            continue
        sftp.put(local, dst)
        sftp.chmod(dst, 0o755 if dst.endswith((".sh", "rtsp30")) else stat.S_IMODE(0o755))
        print("put %-28s -> %s" % (src, dst))
    sftp.close()
    if "--no-start" not in sys.argv:
        print(c.exec_command(START)[1].read().decode(errors="replace"))
    c.close()


if __name__ == "__main__":
    main()
