"""Remote helper for the HEAR reproduction.

Reads credentials.txt internally (its values are never printed), connects with
paramiko, and runs everything inside the permitted work directory
($HOME/<dir from credentials.txt>). IP, username and password are redacted
from every line of output.

Usage:
  remote.py run  [--timeout S] [--nologin]   (shell script read from stdin)
  remote.py put  <local_path> <remote_rel_path>
  remote.py get  <remote_rel_path> <local_path>
  remote.py waitjob <jobid> [--poll S] [--max S]
"""
import argparse
import os
import posixpath
import sys
import time

import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
# credentials.txt is never committed. Default location: next to the repo folder
# (../credentials.txt from the repo root); override with HEAR_CREDENTIALS.
# Format: "IP address: ...", "username: ...", "password: ...", "Directory to work in: ...".
CRED = os.environ.get("HEAR_CREDENTIALS",
                      os.path.normpath(os.path.join(HERE, "..", "..", "credentials.txt")))
KNOWN_HOSTS = os.path.normpath(os.path.join(HERE, "..", "known_hosts_cluster"))


def load_creds():
    vals = {}
    for line in open(CRED, encoding="utf-8-sig").read().splitlines():
        k, sep, v = line.partition(":")
        if sep:
            vals[k.strip().lower()] = v.strip()
    return (vals["ip address"], vals["username"], vals["password"],
            vals["directory to work in"])


IP, USER, PW, WORKDIR = load_creds()


def redact(text):
    for secret, tag in ((PW, "<PASSWORD>"), (USER, "<user>"), (IP, "<cluster-ip>")):
        if secret:
            text = text.replace(secret, tag)
    return text


def out(text, stream=sys.stdout):
    stream.write(redact(text))
    stream.flush()


def connect(retries=3):
    last = None
    for attempt in range(retries):
        try:
            cli = paramiko.SSHClient()
            if os.path.exists(KNOWN_HOSTS):
                cli.load_host_keys(KNOWN_HOSTS)
            cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            cli.connect(IP, port=22, username=USER, password=PW, timeout=30,
                        banner_timeout=60, auth_timeout=60,
                        look_for_keys=False, allow_agent=False)
            cli.save_host_keys(KNOWN_HOSTS)
            return cli
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(5 * (attempt + 1))
    out(f"CONNECT FAILED: {type(last).__name__}: {last}\n", sys.stderr)
    sys.exit(2)


def remote_workdir(cli):
    sftp = cli.open_sftp()
    home = sftp.normalize(".")
    sftp.close()
    return posixpath.join(home, WORKDIR)


def run_script(cli, script, timeout=600, login=True):
    """Run a bash script (sent on stdin) inside the work directory."""
    full = ('cd "$HOME/%s" || { echo "WORKDIR MISSING"; exit 99; }\n' % WORKDIR) + script
    cmd = "bash -l -s" if login else "bash -s"
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=timeout)
    stdin.write(full)
    stdin.channel.shutdown_write()
    chan = stdout.channel
    buf_o, buf_e = [], []
    t0 = time.time()
    while True:
        while chan.recv_ready():
            buf_o.append(chan.recv(65536).decode("utf-8", "replace"))
        while chan.recv_stderr_ready():
            buf_e.append(chan.recv_stderr(65536).decode("utf-8", "replace"))
        if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
            break
        if time.time() - t0 > timeout:
            buf_e.append(f"\n[remote.py] TIMEOUT after {timeout}s\n")
            chan.close()
            return "".join(buf_o), "".join(buf_e), 124
        time.sleep(0.05)
    return "".join(buf_o), "".join(buf_e), chan.recv_exit_status()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--timeout", type=int, default=600)
    r.add_argument("--nologin", action="store_true")
    p = sub.add_parser("put")
    p.add_argument("local")
    p.add_argument("remote")
    g = sub.add_parser("get")
    g.add_argument("remote")
    g.add_argument("local")
    w = sub.add_parser("waitjob")
    w.add_argument("jobid")
    w.add_argument("--poll", type=int, default=60)
    w.add_argument("--max", type=int, default=6 * 3600)
    a = ap.parse_args()

    cli = connect()
    try:
        if a.cmd == "run":
            script = sys.stdin.read()
            o, e, rc = run_script(cli, script, a.timeout, login=not a.nologin)
            out(o)
            if e:
                out(e, sys.stderr)
            out(f"[exit {rc}]\n")
            sys.exit(0 if rc == 0 else 1)
        elif a.cmd in ("put", "get"):
            base = remote_workdir(cli)
            rel = a.remote.lstrip("/")
            if ".." in rel.split("/"):
                out("refusing path outside work dir\n", sys.stderr)
                sys.exit(3)
            rpath = posixpath.join(base, rel)
            sftp = cli.open_sftp()
            if a.cmd == "put":
                sftp.put(a.local, rpath)
                out(f"uploaded {os.path.basename(a.local)} -> <workdir>/{rel} "
                    f"({os.path.getsize(a.local)} bytes)\n")
            else:
                sftp.get(rpath, a.local)
                out(f"downloaded <workdir>/{rel} -> {a.local}\n")
            sftp.close()
        elif a.cmd == "waitjob":
            t0 = time.time()
            last_state = None
            while time.time() - t0 < a.max:
                try:
                    # PBS here keeps no job history: a finished job simply
                    # disappears ("Unknown Job Id").
                    o, e, rc = run_script(cli, f"/opt/pbs/bin/qstat -f {a.jobid} 2>&1",
                                          timeout=120, login=False)
                except Exception:  # noqa: BLE001  (reconnect and retry)
                    time.sleep(10)
                    cli = connect()
                    continue
                state = None
                for line in o.splitlines():
                    if "job_state" in line:
                        state = line.split("=")[-1].strip()
                if state is None and ("Unknown Job" not in o and "has finished" not in o):
                    out(f"[{time.strftime('%H:%M:%S')}] unexpected qstat output, retrying: {o[:200]}\n")
                    time.sleep(a.poll)
                    continue
                if state != last_state:
                    out(f"[{time.strftime('%H:%M:%S')}] job {a.jobid}: state={state or 'finished'}\n")
                    last_state = state
                if state is None or state == "F":
                    break
                time.sleep(a.poll)
            else:
                out(f"waitjob: gave up after {a.max}s\n")
    finally:
        cli.close()


if __name__ == "__main__":
    main()
