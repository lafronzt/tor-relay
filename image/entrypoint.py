#!/usr/bin/python3
"""Refuse unsafe effective configuration before executing Tor as PID 1."""
import os
from pathlib import Path
import shlex
import subprocess
import sys


def check_config(text):
    options = {}
    for line in text.splitlines():
        fields = shlex.split(line, comments=True)
        if fields:
            options.setdefault(fields[0].lower(), []).append(" ".join(fields[1:]))
    required = {
        "exitrelay": ["0"], "exitpolicy": ["reject *:*"], "ipv6exit": ["0"],
        "socksport": ["0"], "controlport": ["0"], "dirport": ["0"],
        "dnsport": ["0"], "transport": ["0"], "httptunnelport": ["0"],
        "bridgerelay": ["0"], "clientonly": ["0"],
        "orport": ["9001 IPv4Only"],
        "datadirectory": ["/var/lib/tor/data"],
        "controlsocket": ["/run/tor/private/control"],
        "cookieauthentication": ["1"],
        "cookieauthfile": ["/run/tor/private/control.authcookie"],
        "cookieauthfilegroupreadable": ["0"],
        "controlsocketsgroupwritable": ["0"],
    }
    for key, value in required.items():
        if options.get(key) != value:
            raise ValueError(f"unsafe effective Tor option: {key}")


def main():
    os.umask(0o077)
    # A private child avoids Tor objecting to a root-owned fsGroup PVC root.
    for name in ("/var/lib/tor/data", "/run/tor/private"):
        path = Path(name)
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.is_symlink() or path.stat().st_uid != os.getuid():
            raise ValueError(f"{name} must be owned by UID {os.getuid()}")
        path.chmod(0o700)
    args = ["/usr/bin/tor", "-f", "/etc/tor/torrc"]
    subprocess.run(args + ["--verify-config"], check=True)
    # --quiet keeps diagnostic logging out of the machine-readable dump.
    result = subprocess.run(args + ["--quiet", "--dump-config", "full"],
                            check=True, capture_output=True, text=True)
    check_config(result.stdout)
    os.execv(args[0], args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"Tor startup refused: {exc}", file=sys.stderr)
        sys.exit(1)
