"""Run an iOS CI command with progress, a full log, and a hard deadline."""
import argparse
import collections
import os
from pathlib import Path
import signal
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    args.log.parent.mkdir(parents=True, exist_ok=True)
    recent = collections.deque(maxlen=30)
    started = time.monotonic()
    print(f"Starting {command[0]}; deadline {args.timeout:g}s; full log: {args.log}", flush=True)
    with args.log.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, errors="replace", start_new_session=True)

        def read_output():
            for line in process.stdout:
                log.write(line)
                log.flush()
                recent.append(line.rstrip())
                if any(marker in line for marker in ("Test Case", "Test Suite", "** ", " error:", "Testing failed")):
                    print(line.rstrip(), flush=True)

        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        deadline = started + args.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(f"::error::Timed out after {args.timeout:g}s: {command[0]}", flush=True)
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                result = 124
                break
            try:
                result = process.wait(timeout=min(60, remaining))
                break
            except subprocess.TimeoutExpired:
                elapsed = int(time.monotonic() - started)
                latest = recent[-1] if recent else "No output yet"
                print(f"Progress: {command[0]} running for {elapsed}s. Latest: {latest}", flush=True)
        reader.join(timeout=10)
        if result:
            print("\nLast command output:\n" + "\n".join(recent), flush=True)
        print(f"Finished {command[0]} after {int(time.monotonic() - started)}s, exit {result}", flush=True)
        return result


if __name__ == "__main__":
    raise SystemExit(main())
