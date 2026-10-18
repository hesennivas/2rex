#!/usr/bin/env python3
"""measure new window to agent panel time in a disposable rex session.

usage: python3 tests/latency.py SESSION_ID [RUNS]
the session must be shown in the rex app and an agent panel must be running.
"""
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from rex_common import find_rex

REX = os.environ.get("REX_BIN") or find_rex()


def rex(*args):
    out = subprocess.run([REX, "--autostart=false", *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout) if out.stdout.strip() else {}


def main():
    sid, runs = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 20
    stream = subprocess.Popen([REX, "--autostart=false", "events", "-s", sid, "--json"],
                              stdout=subprocess.PIPE, text=True)
    events = []
    threading.Thread(target=lambda: [events.append((time.monotonic(), json.loads(l))) for l in stream.stdout],
                     daemon=True).start()
    time.sleep(0.5)
    created, painted, from_event = [], [], []
    try:
        for _ in range(runs):
            mark = len(events)
            t0 = time.monotonic()
            win = rex("api", "call", "session.new_window", json.dumps({"session_id": sid, "layout": {
                "block": {"flavor": "com.superlogical.terminal.shell", "options": {"cwd": "/tmp"}}}}))
            own = set(win["block_ids"])
            panel = t_block = t_paint = t_window = None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and t_paint is None:
                for t, e in events[mark:]:
                    ev = e.get("payload", {}).get("event", {})
                    pl = ev.get("payload", {})
                    if ev.get("type") == "window_created" and pl.get("window_id") == win["window_id"]:
                        t_window = t
                    if ev.get("type") == "block_created" and pl.get("block_id") not in own and panel is None:
                        panel, t_block = pl["block_id"], t
                    if panel and pl.get("block_id") == panel and pl.get("name") == "title_changed" \
                            and (pl.get("payload") or {}).get("title") == "agents":
                        t_paint = t
                time.sleep(0.002)
            if t_paint:
                created.append((t_block - t0) * 1000)
                painted.append((t_paint - t0) * 1000)
                if t_window:
                    from_event.append((t_paint - t_window) * 1000)
            else:
                print("no panel within 10 s")
            rex("api", "call", "session.close_window", json.dumps({"session_id": sid, "window_id": win["window_id"]}))
            time.sleep(0.4)
    finally:
        stream.terminate()
    for name, xs in (("panel block created", created), ("panel first frame", painted),
                     ("window_created event to first frame", from_event)):
        if xs:
            print(f"{name}: median {statistics.median(xs):.0f} ms, min {min(xs):.0f}, max {max(xs):.0f}, n={len(xs)}")


if __name__ == "__main__":
    main()
