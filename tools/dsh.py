#!/usr/bin/env python3
"""Run a command on the reCamera over SSH and print stdout/stderr.

Credentials come from the environment (nothing is hardcoded):
    RC_HOST (default 192.168.4.82), RC_USER (default root), RC_PASS

    RC_PASS=123123 ./tools/dsh.py 'cat /proc/cvitek/venc | head -3'
"""
import os
import sys

import paramiko

HOST = os.environ.get("RC_HOST", "192.168.4.82")
USER = os.environ.get("RC_USER", "root")
PASS = os.environ.get("RC_PASS", "")


def client():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = os.path.expanduser(os.environ.get("RC_KEY", "~/.ssh/id_rsa"))
    try:
        c.connect(HOST, username=USER, key_filename=key, timeout=10,
                  look_for_keys=True, allow_agent=False)
    except Exception:
        if not PASS:
            raise SystemExit("set RC_PASS (or install your SSH key) to connect")
        c.connect(HOST, username=USER, password=PASS, timeout=10,
                  look_for_keys=False, allow_agent=False)
    return c


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
    c = client()
    _, stdout, stderr = c.exec_command(cmd, timeout=300, get_pty=False)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    sys.stdout.write(out)
    if err.strip():
        sys.stdout.write("\n--- stderr ---\n" + err)
    sys.stdout.write("\n--- exit=%d ---\n" % rc)
    c.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
