#!/usr/bin/env python3
"""Run a command with a deadline and terminate its process group on timeout."""

import argparse
import os
import signal
import subprocess
import sys
import time


def terminate(process, requested_signal):
    try:
        os.killpg(process.pid, requested_signal)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 10
    while True:
        # Reap the leader, but allow descendants their own grace period.
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.1, remaining))
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.seconds <= 0 or not args.command:
        parser.error("Provide a positive deadline and a command.")
    process = subprocess.Popen(args.command, start_new_session=True)
    try:
        status = process.wait(timeout=args.seconds)
        return status if status >= 0 else 128 - status
    except subprocess.TimeoutExpired:
        print(f"Command exceeded its {args.seconds}-second deadline: {args.command[0]}", file=sys.stderr)
        terminate(process, signal.SIGTERM)
        return 124
    except KeyboardInterrupt:
        terminate(process, signal.SIGINT)
        return 130


if __name__ == "__main__":
    sys.exit(main())
