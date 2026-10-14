#!/usr/bin/env python3
"""Download this project's deployment payload on the PC and install over SSH."""
import io
import os
import subprocess
import sys
import tarfile
import urllib.request


def load_paramiko():
    try:
        import paramiko
        return paramiko
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "paramiko"])
        import paramiko
        return paramiko


def main():
    host = os.environ["RTSP30_DEVICE_IP"]
    username = os.environ["RTSP30_DEVICE_USER"]
    password = os.environ["RTSP30_DEVICE_PASSWORD"]
    repo = os.environ.get("RTSP30_REPO", "yyling0101-a11y/recamera-rtsp30")
    branch = os.environ.get("RTSP30_BRANCH", "main")

    url = f"https://codeload.github.com/{repo}/tar.gz/refs/heads/{branch}"
    print(f"Downloading deployment files from {repo}@{branch} ...")
    with urllib.request.urlopen(url, timeout=90) as response:
        archive = tarfile.open(fileobj=io.BytesIO(response.read()), mode="r:gz")

    wanted = {
        "bin/rtsp30": "rtsp30",
        "bin/rtsp30.sha256": "rtsp30.sha256",
        "etc/rtsp30.sh": "rtsp30.sh",
        "etc/S99rtsp30": "S99rtsp30",
        "scripts/rtsp30-status.sh": "rtsp30-status.sh",
        "scripts/uninstall-rtsp30.sh": "uninstall-rtsp30.sh",
        "scripts/sample.sh": "rtsp30-sample.sh",
        "scripts/remote-install.sh": "remote-install.sh",
    }
    prefix = archive.getmembers()[0].name.split("/")[0] + "/"
    files = {}
    for source, destination in wanted.items():
        member = archive.extractfile(prefix + source)
        if member is None:
            raise SystemExit(f"Required repository file missing: {source}")
        files[destination] = member.read()

    paramiko = load_paramiko()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, username=username, password=password,
                   timeout=20, look_for_keys=False, allow_agent=False)
    client.exec_command("mkdir -p /tmp/rtsp30-install")
    sftp = client.open_sftp()
    executables = {"rtsp30", "rtsp30.sh", "S99rtsp30", "remote-install.sh"}
    for name, content in files.items():
        path = "/tmp/rtsp30-install/" + name
        with sftp.file(path, "wb") as target:
            target.write(content)
        sftp.chmod(path, 0o755 if name in executables else 0o644)
        print(f"Uploaded {name}")
    sftp.close()

    print("Installing and starting rtsp30 on the reCamera ...")
    _, identity, _ = client.exec_command("id -u")
    is_root = identity.read().decode().strip() == "0"
    command = "STAGE_DIR=/tmp/rtsp30-install sh /tmp/rtsp30-install/remote-install.sh"
    if not is_root:
        command = "sudo -S -p '' env " + command
    stdin, stdout, stderr = client.exec_command(command, timeout=300)
    if not is_root:
        stdin.write(password + "\n")
        stdin.flush()
    for line in iter(stdout.readline, ""):
        print(line, end="")
    error = stderr.read().decode(errors="replace")
    code = stdout.channel.recv_exit_status()
    if error:
        print(error, file=sys.stderr, end="")
    client.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
