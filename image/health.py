#!/usr/bin/python3
"""Authenticated local Tor control checks. Never prints the cookie or keys."""
import json
from pathlib import Path
import signal
import socket
import sys
import time
import os


class Control:
    def __enter__(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(2)
        self.sock.connect("/run/tor/private/control")
        self.stream = self.sock.makefile("rwb")
        cookie = Path("/run/tor/private/control.authcookie").read_bytes()
        if len(cookie) != 32:
            raise ValueError("invalid control cookie length")
        self.command("AUTHENTICATE " + cookie.hex())
        return self

    def __exit__(self, *_):
        self.stream.close()
        self.sock.close()

    def command(self, command):
        self.stream.write((command + "\r\n").encode("ascii"))
        self.stream.flush()
        result = []
        # Only single-line/multiline '-' responses used here, never descriptors.
        for _ in range(100):
            line = self.stream.readline(16384).decode("ascii").rstrip("\r\n")
            if not line.startswith("250"):
                raise ValueError("Tor control command failed")
            if line[3:4] == "+":
                raise ValueError("unexpected data reply")
            if line[4:] != "OK":
                result.append(line[4:])
            if line[3:4] == " ":
                return result
        raise ValueError("unbounded Tor reply")

    def info(self, key):
        lines = self.command("GETINFO " + key)
        return "\n".join(lines).removeprefix(key + "=")


def main(mode):
    if mode == "shutdown":
        # PID 1 is Tor after exec. Wait for the configured 30-second drain;
        # Kubernetes' 90-second grace period includes this hook.
        os.kill(1, signal.SIGINT)
        time.sleep(35)
        return
    with Control() as control:
        if mode == "live":
            control.info("version")
        elif mode == "ready":
            if "PROGRESS=100" not in control.info("status/bootstrap-phase"):
                raise ValueError("Tor has not bootstrapped")
            if control.info("accounting/hibernating") not in ("awake", ""):
                raise ValueError("Tor is accounting-hibernating")
            if control.info("net/listeners/or") in ("", '""'):
                raise ValueError("no OR listener")
        elif mode == "status":
            keys = ("version", "fingerprint", "status/bootstrap-phase",
                    "status/reachability-succeeded", "traffic/read",
                    "traffic/written", "accounting/hibernating")
            status = {key: control.info(key) for key in keys}
            status["configuration"] = control.command(
                "GETCONF ExitRelay ExitPolicy IPv6Exit SocksPort ControlPort ORPort")
            print(json.dumps(status, indent=2))
        else:
            raise ValueError("use live, ready, status, or shutdown")


if __name__ == "__main__":
    try:
        main(sys.argv[1] if len(sys.argv) == 2 else "status")
    except (OSError, ValueError) as exc:
        print(f"Tor health: {exc}", file=sys.stderr)
        sys.exit(1)
