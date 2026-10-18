"""dependency-free rex cli client and private state helpers (python 3.11+)."""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


class Error(RuntimeError):
    pass


def run(argv, timeout=15, input=None):
    try:
        result = subprocess.run([str(a) for a in argv], capture_output=True, text=True, timeout=timeout,
                                input=input, stdin=None if input is not None else subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Error(f"{argv[0]}: {exc}") from exc
    if result.returncode:
        raise Error((result.stderr or result.stdout).strip() or f"Exit {result.returncode}")
    return result.stdout


def private_dir(path):
    path = Path(path).expanduser().absolute()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.stat().st_uid != os.getuid():
        raise Error(f"Unsafe state directory: {path}")
    path.chmod(0o700)
    return path


def atomic_json(path, value):
    path = Path(path)
    private_dir(path.parent)
    fd, tmp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(value, out, ensure_ascii=False, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


@contextlib.contextmanager
def lock(path):
    private_dir(Path(path).parent)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Error("Another operation is already running") from exc
        yield
    finally:
        os.close(fd)


def find_rex(override=None):
    # the app keeps updated servers in its support folder; newest build first
    versions = Path.home() / "Library/Application Support/com.superlogical.rex/RexServer/Versions"
    builds = sorted((p for p in versions.glob("*") if p.name.isdigit()), key=lambda p: -int(p.name))
    candidates = [override, shutil.which("rex"),
                  *(str(p / "Rex Server.app/Contents/MacOS/rex") for p in builds),
                  "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex",
                  "/Applications/Rex.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex"]
    for item in candidates:
        if item and Path(item).is_file() and os.access(item, os.X_OK):
            return str(Path(item).absolute())
    raise Error("Rex binary not found; use --rex-bin")


# a block belongs to the client that created it until that client gives it up,
# which only works from the same connection; each `rex api call` is a new one
CREATE_SESSION = """
local created, err = rex.call('session.create', rex.args)
if not created then error(err, 0) end
local _, aerr = rex.call('session.attach', {session_id = created.session_id})
if aerr then error(aerr, 0) end
local _, derr = rex.call('session.disown_block', {session_id = created.session_id})
if derr then error(derr, 0) end
return created
"""


class Rex:
    def __init__(self, binary=None, server=None):
        self.binary = find_rex(binary)
        self.server = server

    def command(self, *args):
        result = [self.binary, "--autostart=false", "--timeout=5s", "--color=never"]
        if self.server:
            result += ["--server", self.server]
        return result + list(args)

    def call(self, method, args=None):
        return json.loads(run(self.command("api", "call", method,
                                          json.dumps(args or {}, ensure_ascii=False))))

    def create_session(self, args):
        return json.loads(run(self.command("do", "-", "--args", json.dumps(args, ensure_ascii=False)),
                              input=CREATE_SESSION))

    def terminal(self, method, sid, bid):
        return self.call("com.superlogical.terminal." + method,
                         {"session_id": sid, "block_id": bid, "args": {}})


def shell_layout(cwd):
    return {"block": {"flavor": "com.superlogical.terminal.shell", "options": {"cwd": cwd}}}


def leaves(node):
    if node.get("block_id"):
        yield node
    elif node.get("split"):
        yield from leaves(node["split"]["before"])
        yield from leaves(node["split"]["after"])


def clean(text):
    """strip terminal controls from labels, paths and agent text before display."""
    return "".join(c if c.isprintable() else " " for c in str(text))
