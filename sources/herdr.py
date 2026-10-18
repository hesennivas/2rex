"""one-time, read-only herdr capture and recoverable rex structure import."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sys
import time
import uuid

from rex_common import (Error, Rex, atomic_json, clean, leaves, lock, private_dir,
                        read_json, run, shell_layout)

STATE = Path.home() / ".local/state/2rex/herdr"
# receipts from before the rename, moved on first use
LEGACY_STATE = Path.home() / ".local/state/herdr-to-rex"


def digest(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def herdr_call(sockpath, method, params=None):
    if method not in {"session.snapshot", "layout.export"}:
        raise Error("Herdr mutation is forbidden")
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5)
        sock.connect(str(sockpath))
        sock.sendall((json.dumps({"id": "2rex", "method": method,
                                 "params": params or {}}) + "\n").encode())
        with sock.makefile("r") as stream:
            line = stream.readline(16 * 1024 * 1024)
    reply = json.loads(line)
    if reply.get("error"):
        raise Error(str(reply["error"]))
    return reply["result"]


def topology(snapshot):
    return {k: snapshot[k] for k in ("workspaces", "tabs", "layouts")}


def capture_live(sockpath):
    for _ in range(3):
        before = herdr_call(sockpath, "session.snapshot")["snapshot"]
        exports = {t["tab_id"]: herdr_call(sockpath, "layout.export", {"tab_id": t["tab_id"]})["layout"]
                   for t in before["tabs"]}
        after = herdr_call(sockpath, "session.snapshot")["snapshot"]
        if topology(before) == topology(after):
            return {"format": "herdr-live-v1", "snapshot": after, "exports": exports}
    raise Error("Herdr layout changed during capture; retry when stable")


def pane_label(pid, label):
    # herdr names an unnamed pane by what runs in it, so only a name the user gave carries over
    return label if label and label != pid else None


def normalize_tree(node, panes=None, depth=0):
    if depth > 64 or not isinstance(node, dict):
        raise Error("Malformed or excessively deep layout tree")
    if set(node) == {"Pane"}:
        pid = str(node["Pane"])
        if panes is None or pid not in panes:
            raise Error(f"Missing pane {pid}")
        pane = dict(panes[pid])
        return {"type": "pane", "id": pid, "label": pane_label(pid, pane.get("custom_name") or pane.get("label")),
                "cwd": pane.get("cwd")}
    if set(node) == {"Split"}:
        split = node["Split"]
        # herdr v3: horizontal is left/right, vertical is top/bottom
        if not isinstance(split, dict):
            raise Error("Malformed saved Split")
        direction = {"Horizontal": "right", "Vertical": "down"}.get(split.get("direction"))
        node = {"type": "split", "direction": direction, "ratio": split.get("ratio"),
                "first": split.get("first"), "second": split.get("second")}
    if node.get("type") == "pane":
        pid = str(node.get("pane_id", node.get("id", "")))
        return {"type": "pane", "id": pid, "label": pane_label(pid, node.get("label")), "cwd": node.get("cwd")}
    if node.get("type") != "split" or node.get("direction") not in {"right", "down"}:
        raise Error("Unsupported layout node or split direction")
    ratio = node.get("ratio")
    if isinstance(ratio, bool) or not isinstance(ratio, (float, int)) or not 0 < ratio < 1:
        raise Error(f"Invalid split ratio: {ratio}")
    return {"type": "split", "direction": node["direction"], "ratio": ratio,
            "first": normalize_tree(node.get("first"), panes, depth + 1),
            "second": normalize_tree(node.get("second"), panes, depth + 1)}


def panes_in(tree):
    if tree["type"] == "pane":
        yield tree
    else:
        yield from panes_in(tree["first"])
        yield from panes_in(tree["second"])


def normalize(source, name):
    result = []
    exported = source.get("result", {}).get("layout") if isinstance(source.get("result"), dict) else None
    exported = exported or (source if "root" in source else None)
    if exported:
        # a standalone layout.export, possibly still in its socket envelope
        wid, tid = exported.get("workspace_id", "workspace"), exported.get("tab_id", "tab")
        source = {"format": "herdr-live-v1", "snapshot": {
            "workspaces": [{"workspace_id": wid, "label": exported.get("workspace_label") or str(wid), "active_tab_id": tid}],
            "tabs": [{"tab_id": tid, "workspace_id": wid, "label": exported.get("tab_label") or "1"}],
            "panes": []}, "exports": {tid: exported}}
    if source.get("format") == "herdr-live-v1":
        snap = source["snapshot"]
        for w in snap["workspaces"]:
            tabs = []
            for t in snap["tabs"]:
                if t["workspace_id"] != w["workspace_id"]:
                    continue
                export = source["exports"][t["tab_id"]]
                tree = normalize_tree(export["root"])
                tabs.append({"id": t["tab_id"], "label": t["label"], "tree": tree,
                             "focus": export.get("focused_pane_id"), "zoom": export.get("zoomed", False)})
            result.append({"source_session": name, "id": w["workspace_id"], "label": w["label"],
                           "tabs": tabs, "active_tab": w.get("active_tab_id")})
    elif source.get("version") == 3:
        for w in source["workspaces"]:
            tabs = []
            for i, t in enumerate(w["tabs"]):
                tree = normalize_tree(t["layout"], t["panes"])
                tabs.append({"id": str(i), "label": t.get("custom_name") or str(i + 1), "tree": tree,
                             "focus": str(t.get("focused", "")), "zoom": t.get("zoomed", False)})
            result.append({"source_session": name, "id": w["id"],
                           "label": w.get("custom_name") or Path(w.get("identity_cwd") or "/").name or w["id"],
                           "tabs": tabs, "active_tab": str(w.get("active_tab", 0))})
    else:
        raise Error(f"Unsupported Herdr source version/format: {source.get('version', source.get('format'))}")
    for w in result:
        if not w["tabs"]:
            raise Error(f"Workspace {w['label']} has no tabs")
        for t in w["tabs"]:
            ids = [p["id"] for p in panes_in(t["tree"])]
            if len(ids) != len(set(ids)):
                raise Error("Duplicate pane IDs in layout")
    return result


def discover(args):
    captures, workspaces, warnings = [], [], []
    if args.source:
        src = json.loads(Path(args.source).read_text())
        name = args.session or "offline"
        captures.append({"name": name, "mode": "offline", "data": src})
        workspaces += normalize(src, name)
    else:
        binary = args.herdr_bin or shutil.which("herdr")
        if not binary:
            raise Error("Herdr not found; use --source or --herdr-bin")
        sessions = json.loads(run([binary, "session", "list", "--json"]))["sessions"]
        if args.session:
            sessions = [s for s in sessions if s["name"] == args.session]
            if not sessions:
                raise Error(f"Unknown Herdr session: {args.session}")
        for s in sessions:
            mode = "saved"
            if s["running"]:
                try:
                    src = capture_live(s["socket_path"])
                    mode = "live"
                except (OSError, ValueError, KeyError, Error) as exc:
                    warnings.append(f"{s['name']}: live capture unavailable ({exc}); using SAVED state")
                    src = json.loads((Path(s["session_dir"]) / "session.json").read_text())
            else:
                src = json.loads((Path(s["session_dir"]) / "session.json").read_text())
            captures.append({"name": s["name"], "mode": mode, "data": src})
            workspaces += normalize(src, s["name"])
    return captures, workspaces, warnings


def remap(path, mappings):
    if not isinstance(path, str) or not path:
        raise Error("Pane has no directory")
    for old, new in sorted(mappings, key=lambda pair: -len(pair[0])):
        if path == old or path.startswith(old.rstrip("/") + "/"):
            path = new.rstrip("/") + path[len(old):]
            break
    if not os.path.isabs(path) or not Path(path).is_dir():
        raise Error(f"Unresolved or missing directory: {path}")
    return path


def rex_layout(tree):
    if tree["type"] == "pane":
        return shell_layout(tree["cwd"])
    return {"split": {"direction": "horizontal" if tree["direction"] == "right" else "vertical",
                      "ratio": tree["ratio"], "before": rex_layout(tree["first"]),
                      "after": rex_layout(tree["second"])}}


def bind_existing(rex, workspace, sid):
    view = rex.call("session.view", {"session_id": sid})
    windows = view.get("windows") or []
    if len(windows) != len(workspace["tabs"]):
        raise Error(f"Destination {sid} has changed; inspect receipt before recovery")
    result = []
    for tab, win in zip(workspace["tabs"], windows):
        layers = [l for l in win["layers"] if l["kind"] == "tiled"]
        if len(layers) != 1:
            raise Error("Unexpected destination layers")
        actual = list(leaves(layers[0]["layout"]))
        expected = list(panes_in(tab["tree"]))
        if len(actual) != len(expected):
            raise Error("Destination leaf count changed; refusing to relabel")
        def check(src, dst):
            if src["type"] == "pane":
                if not dst.get("block_id"):
                    raise Error("Destination leaf ordering differs")
            else:
                split = dst.get("split") or {}
                if split.get("direction") != ("horizontal" if src["direction"] == "right" else "vertical") or abs(split.get("ratio", -1)-src["ratio"]) > .001:
                    raise Error("Destination split geometry differs")
                check(src["first"], split["before"])
                check(src["second"], split["after"])
        check(tab["tree"], layers[0]["layout"])
        blocks = {b["block_id"]: b for b in layers[0]["blocks"]}
        for p, leaf in zip(expected, actual):
            cwd = None
            for _ in range(30):
                process = rex.terminal("process", sid, leaf["block_id"])
                cwd = (process.get("foreground") or {}).get("cwd") or (process.get("child") or {}).get("cwd")
                if cwd:
                    break
                time.sleep(.1)
            if not cwd:
                raise Error(f"Destination directory not observable yet for {leaf['block_id']}; use --recover after shell startup")
            if os.path.realpath(cwd) != os.path.realpath(p["cwd"]):
                raise Error(f"Destination directory differs: {cwd} != {p['cwd']}")
            result.append({"pane_id": p["id"], "block_id": leaf["block_id"],
                           "window_id": win["window_id"], "label": p["label"], "cwd": p["cwd"]})
    return result


def import_workspaces(rex, workspaces, captures, state, key):
    private_dir(state)
    receipt_path = state / f"{key}.json"
    with lock(state / "import.lock"):
        status = rex.call("server.status")
        receipt = read_json(receipt_path)
        if receipt and receipt["instance_id"] != status["instance_id"]:
            raise Error("Rex server instance changed. Old IDs are invalid; use --restore explicitly")
        if receipt and receipt["state"] == "rolled-back":
            raise Error("This import was rolled back; use --restore explicitly")
        inventory = rex.call("session.list").get("sessions") or []
        live = {s["session_id"]: s for s in inventory}
        if receipt and receipt["state"] == "complete":
            missing = [r["session_id"] for r in receipt["resources"] if r["session_id"] not in live]
            if missing:
                raise Error("Imported sessions were closed; use --restore to recreate explicitly")
            print(f"Already imported: {len(receipt['resources'])} sessions. No changes. Receipt: {receipt_path}")
            return receipt
        if not receipt:
            receipt = {"version": 1, "key": key, "instance_id": status["instance_id"],
                       "server": rex.server, "state": "applying", "resources": [],
                       "source_hash": digest(captures), "captures": captures, "workspaces": workspaces}
            atomic_json(state / f"{key}.source.json", captures)
            atomic_json(receipt_path, receipt)
        else:
            # keep the frozen input even if herdr changed since
            workspaces = receipt["workspaces"]
        for i, w in enumerate(workspaces):
            if i < len(receipt["resources"]):
                record = receipt["resources"][i]
                sid = record.get("session_id")
                if not sid:
                    # the staging label was journaled before create
                    matches = [s for s in inventory if s["label"] == record["staging_label"]]
                    if len(matches) != 1:
                        raise Error("Creation outcome uncertain. Inspect Rex and receipt; automatic retry is disabled")
                    sid = record["session_id"] = matches[0]["session_id"]
                    atomic_json(receipt_path, receipt)
                elif sid not in live:
                    raise Error("Partially imported session was closed; refusing to resurrect it")
            else:
                staging = "herdr-import-" + uuid.uuid4().hex
                record = {"source_id": w["id"], "source_session": w["source_session"],
                          "staging_label": staging, "session_id": None}
                receipt["resources"].append(record)
                atomic_json(receipt_path, receipt)
                created = rex.create_session({"label": staging, "initial_windows": [
                    {"window_label": t["label"], "layout": rex_layout(t["tree"])} for t in w["tabs"]]})
                sid = record["session_id"] = created["session_id"]
                # persist the id before any further mutation
                atomic_json(receipt_path, receipt)
            record["blocks"] = bind_existing(rex, w, sid)
            for block in (b for b in record["blocks"] if b["label"]):
                rex.call("session.set_block_label", {"session_id": sid, "block_id": block["block_id"], "label": block["label"]})
            for tab in w["tabs"]:
                focus = next((b for b in record["blocks"] if b["pane_id"] == tab["focus"]), None)
                if focus:
                    rex.call("session.focus_block", {"session_id": sid, "block_id": focus["block_id"]})
                    if tab["zoom"]:
                        rex.call("session.zoom_block", {"session_id": sid, "block_id": focus["block_id"], "zoom": True})
            active = next((t for t in w["tabs"] if t["id"] == w["active_tab"]), w["tabs"][0])
            target = next((b for b in record["blocks"] if b["pane_id"] == active["focus"]), record["blocks"][0])
            rex.call("session.focus_window", {"session_id": sid, "window_id": target["window_id"]})
            label = w["label"]
            if sum(v["label"] == label for v in workspaces) > 1 or any(s["label"] == label and s["session_id"] != sid for s in inventory):
                label = w["source_session"] + "/" + label
            if any(s["label"] == label and s["session_id"] != sid for s in inventory):
                label += "/" + w["id"]
            rex.call("session.set_label", {"session_id": sid, "label": label})
            record["label"] = label
            atomic_json(receipt_path, receipt)
        receipt["state"] = "complete"
        atomic_json(receipt_path, receipt)
        print(f"Verified {len(workspaces)} sessions, {sum(len(w['tabs']) for w in workspaces)} windows, "
              f"{sum(len(r['blocks']) for r in receipt['resources'])} terminal blocks.\nReceipt: {receipt_path}")
        return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(prog="2rex herdr", description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--session")
    parser.add_argument("--herdr-bin")
    parser.add_argument("--rex-bin")
    parser.add_argument("--server")
    parser.add_argument("--state-dir", type=Path, default=STATE)
    parser.add_argument("--map-path", action="append", default=[], metavar="OLD=NEW")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true")
    recovery = parser.add_mutually_exclusive_group()
    recovery.add_argument("--rollback", type=Path, metavar="RECEIPT")
    recovery.add_argument("--recover", type=Path, metavar="RECEIPT", help="finish an interrupted import")
    recovery.add_argument("--restore", type=Path, metavar="RECEIPT", help="explicitly recreate closed structure")
    args = parser.parse_args(argv)
    if args.state_dir == STATE and LEGACY_STATE.is_dir() and not STATE.exists():
        private_dir(STATE.parent)
        LEGACY_STATE.rename(STATE)
        print(f"Moved receipts from {LEGACY_STATE} to {STATE}")
    rex = Rex(args.rex_bin, args.server)
    if args.rollback:
        receipt = read_json(args.rollback)
        if not receipt:
            raise Error("Receipt missing")
        if receipt["server"] != args.server or receipt["instance_id"] != rex.call("server.status")["instance_id"]:
            raise Error("Receipt belongs to another server or server instance")
        print("Rollback closes ONLY recorded imported sessions and their processes:")
        for r in receipt["resources"]:
            print(clean(r.get("session_id")))
        if args.dry_run:
            return
        confirm(args, "Close these imported sessions?")
        with lock(args.rollback.parent / "import.lock"):
            live = {s["session_id"] for s in rex.call("session.list").get("sessions") or []}
            for r in receipt["resources"]:
                if r.get("session_id") in live:
                    rex.call("session.destroy", {"session_id": r["session_id"]})
            receipt["state"] = "rolled-back"
            atomic_json(args.rollback, receipt)
        return
    if args.recover or args.restore:
        receipt = read_json(args.recover or args.restore)
        if not receipt or receipt["server"] != args.server:
            raise Error("Receipt missing or destination server differs")
        captures, workspaces, warnings = receipt["captures"], receipt["workspaces"], []
    else:
        captures, workspaces, warnings = discover(args)
    mappings = []
    for text in args.map_path:
        if "=" not in text:
            raise Error("--map-path must be OLD=NEW")
        mappings.append(tuple(text.split("=", 1)))
    errors = []
    for c in captures:
        print(f"Source {clean(c['name'])}: {c['mode']} state")
    for w in workspaces:
        print(f"\nWorkspace: {clean(w['label'])} ({clean(w['source_session'])})")
        for t in w["tabs"]:
            print(f"  Tab: {clean(t['label'])}")
            for p in panes_in(t["tree"]):
                try:
                    p["cwd"] = remap(p["cwd"], mappings)
                except Error as exc:
                    errors.append(str(exc))
                print(f"    {clean(p['label'] or p['id'])}: {clean(p['cwd'])}")
    print(f"\n{len(workspaces)} workspaces, {sum(len(w['tabs']) for w in workspaces)} tabs, "
          f"{sum(1 for w in workspaces for t in w['tabs'] for _ in panes_in(t['tree']))} panes")
    for item in warnings:
        print("Notice:", clean(item))
    for item in errors:
        print("UNRESOLVED:", clean(item))
    if errors:
        raise Error("Resolve source problems before applying")
    if not workspaces or args.dry_run:
        print("No changes made.")
        return
    confirm(args, "Create these Rex sessions?")
    # a rerun must never make a second copy, whatever changed in the source since;
    # a receipt owns one source selection on one destination
    scope = {"source": str(args.source.expanduser().resolve()) if args.source else "local-herdr",
             "session": args.session or "*", "config": os.environ.get("HERDR_CONFIG_PATH"),
             "server": args.server}
    key = digest(scope)
    if args.recover:
        key = receipt["key"]
        args.state_dir = args.recover.parent
    if args.restore:
        key = digest({"restore": key, "nonce": uuid.uuid4().hex})
    import_workspaces(rex, workspaces, captures, args.state_dir, key)


def confirm(args, prompt):
    if not args.yes and (not sys.stdin.isatty() or input(prompt + " [y/N] ").strip().lower() != "y"):
        raise Error("Not applied; use --yes for explicit noninteractive execution")

