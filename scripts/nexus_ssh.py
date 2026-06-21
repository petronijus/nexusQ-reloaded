#!/usr/bin/env python3
"""Run a command on the Nexus Q over SSH via paramiko (avoids the Windows
OpenSSH 1Password-agent gotcha when the harness backgrounds ssh).

Usage:
    NEXUS_PW=... python nexus_ssh.py "<remote command>"
    NEXUS_PW=... python nexus_ssh.py --put <localfile> <remotepath>
    NEXUS_PW=... python nexus_ssh.py --get <remotepath> <localfile>

Host/user overridable via NEXUS_HOST / NEXUS_USER.
"""
import os, sys
import paramiko

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HOST = os.environ.get("NEXUS_HOST", "192.168.20.179")
USER = os.environ.get("NEXUS_USER", "root")
# No hard-coded credential: the password must come from the environment.
PW = os.environ.get("NEXUS_PW")
if not PW:
    sys.exit("set NEXUS_PW (device root password) in the environment")


def client():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=20,
              look_for_keys=False, allow_agent=False)
    return c


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit("need a command or --put/--get")
    c = client()
    if a[0] in ("--put", "--get"):
        try:
            sftp = c.open_sftp()
            if a[0] == "--put":
                sftp.put(a[1], a[2])
            else:
                sftp.get(a[1], a[2])
            sftp.close()
            print(f"{a[0]} {a[1]} -> {a[2]} (sftp)")
            return
        except Exception as e:
            sys.stderr.write(f"sftp failed ({e}); falling back to base64 over exec\n")
    if a[0] == "--put":  # base64 fallback: local -> remote
        import base64
        with open(a[1], "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        stdin, stdout, stderr = c.exec_command(
            f"base64 -d > {a[2]}", timeout=300)
        stdin.write(b64)
        stdin.channel.shutdown_write()
        rc = stdout.channel.recv_exit_status()
        err = stderr.read().decode(errors="replace")
        if err:
            sys.stderr.write(err)
        print(f"put {a[1]} -> {a[2]} (base64) rc={rc}")
        sys.exit(rc)
    if a[0] == "--get":  # base64 fallback: remote -> local
        import base64
        stdin, stdout, stderr = c.exec_command(
            f"base64 {a[1]}", timeout=300)
        data = stdout.read()
        rc = stdout.channel.recv_exit_status()
        err = stderr.read().decode(errors="replace")
        if err:
            sys.stderr.write(err)
        if rc == 0:
            with open(a[2], "wb") as f:
                f.write(base64.b64decode(data))
        print(f"get {a[1]} -> {a[2]} (base64) rc={rc}")
        sys.exit(rc)
    cmd = " ".join(a)
    stdin, stdout, stderr = c.exec_command(cmd, timeout=120)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    sys.exit(rc)


if __name__ == "__main__":
    main()
