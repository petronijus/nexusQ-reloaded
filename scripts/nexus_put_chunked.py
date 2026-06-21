#!/usr/bin/env python3
"""Robust binary upload to the Nexus Q: chunked base64 append over short exec
sessions. paramiko sftp upload stalls on this device's sftp server over WiFi
(downloads are fine), so we avoid one long-lived transfer entirely.

Each chunk is sent in its own exec session ('base64 -d >> remote'), with retry.
First chunk truncates the file ('>'), the rest append ('>>'). Final sha256 is
verified against the local file.

    NEXUS_PW=... python nexus_put_chunked.py <localfile> <remotepath>
"""
import os, sys, base64, hashlib, time
import paramiko

HOST = os.environ.get("NEXUS_HOST", "192.168.20.179")
USER = os.environ.get("NEXUS_USER", "root")
# No hard-coded credential: the password must come from the environment.
PW = os.environ.get("NEXUS_PW")
if not PW:
    sys.exit("set NEXUS_PW (device root password) in the environment")
CHUNK = 256 * 1024  # raw bytes per chunk


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=20,
              look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, stdin_data=None, timeout=60):
    stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    if stdin_data is not None:
        stdin.write(stdin_data)
        stdin.channel.shutdown_write()
    out = stdout.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    err = stderr.read().decode(errors="replace")
    return rc, out, err


def main():
    local, remote = sys.argv[1], sys.argv[2]
    data = open(local, "rb").read()
    local_sha = hashlib.sha256(data).hexdigest()
    n = (len(data) + CHUNK - 1) // CHUNK
    print(f"uploading {len(data)} bytes in {n} chunks of {CHUNK} -> {remote}")
    c = connect()
    for i in range(n):
        piece = data[i * CHUNK:(i + 1) * CHUNK]
        b64 = base64.b64encode(piece).decode()
        redir = ">" if i == 0 else ">>"
        cmd = f"base64 -d {redir} {remote}"
        for attempt in range(4):
            try:
                rc, out, err = run(c, cmd, stdin_data=b64, timeout=60)
                if rc == 0:
                    break
                sys.stderr.write(f"chunk {i} rc={rc} err={err.strip()} (try {attempt})\n")
            except Exception as e:
                sys.stderr.write(f"chunk {i} exception: {e} (try {attempt})\n")
                try:
                    c.close()
                except Exception:
                    pass
                time.sleep(1)
                c = connect()
        else:
            sys.exit(f"FAILED on chunk {i}")
        if (i + 1) % 5 == 0 or i == n - 1:
            print(f"  {i+1}/{n} chunks sent")
    rc, out, err = run(c, f"sha256sum {remote}")
    remote_sha = out.split()[0] if out.split() else "?"
    print(f"local : {local_sha}")
    print(f"remote: {remote_sha}")
    if remote_sha == local_sha:
        print("OK: checksums match")
        sys.exit(0)
    sys.exit("MISMATCH")


if __name__ == "__main__":
    main()
