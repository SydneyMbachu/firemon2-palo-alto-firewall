#!/usr/bin/env python3
"""Run on the lab client; a TCP connection tests policy, not SSH login or TLS."""
import argparse
import socket

parser = argparse.ArgumentParser()
parser.add_argument("scenario", choices=["current", "broad", "scoped"])
args = parser.parse_args()
expected = {"current": (False, False), "broad": (True, True), "scoped": (True, False)}
failed = False
for port, wanted in zip((8443, 22), expected[args.scenario]):
    try:
        with socket.create_connection(("10.77.2.20", port), timeout=5):
            allowed = True
    except (TimeoutError, OSError):
        allowed = False
    ok = allowed == wanted
    failed |= not ok
    print(f"TCP {port}: {'reachable' if allowed else 'unreachable'}; expected {'reachable' if wanted else 'unreachable'}: {'PASS' if ok else 'FAIL'}")
raise SystemExit(int(failed))
