"""t3-queue: T3 Code threads that are waiting for you.

Mirrors the opencode attention queue: `watch` keeps
$XDG_RUNTIME_DIR/t3-done-queue.json up to date for the shell bar, `select`
is an fzf picker over the same entries (the "T3" entry in the Super+D launcher), `goto` opens a
thread in the T3 desktop app and `prune` settles it (so it also leaves T3's
Active inbox).

A thread is waiting when it is top-level, not settled, not snoozed, and its
last run finished, failed, or needs input. It leaves the queue once you
settle it (Ctrl+Shift+S in T3, or dismiss here) and returns on new activity.

Talks to the local T3 server's MCP endpoint with a 30-day "mcp-client"
bearer session cached under $XDG_STATE_HOME/t3-queue/token.
"""

import json
import os
import shlex
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

T3_BIN_DIR = os.environ.get("T3_BIN_DIR", "/run/current-system/sw/bin")
T3 = os.path.join(T3_BIN_DIR, "t3")
T3_DESKTOP = os.path.join(T3_BIN_DIR, "t3code-desktop")
T3_HOME = os.environ.get("T3CODE_HOME", os.path.expanduser("~/.t3"))
RUNTIME_STATE = os.path.join(T3_HOME, "userdata", "server-runtime.json")
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "t3-queue"
)
TOKEN_FILE = os.path.join(STATE_DIR, "token")
QUEUE_FILE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "t3-done-queue.json"
)
STATE_DB = os.path.join(T3_HOME, "userdata", "statev2.sqlite")
# T3's sidebar: snoozed, then settled, then pinned, then Working (these
# statuses), and every other thread is Active. The tray is Pinned + Active.
WORKING_STATUSES = {"preparing", "queued", "starting", "running"}
# Bar widget vocabulary (shared with the opencode queue): idle | error |
# permission, plus working (only pinned threads show while running).
BAR_STATUS = {"failed": "error", "waiting": "permission", **{s: "working" for s in WORKING_STATUSES}}
T3_WINDOW_CLASS = "com.t3tools.T3Code"


class AuthError(Exception):
    pass


def server_origin():
    with open(RUNTIME_STATE) as f:
        return json.load(f)["origin"]


def issue_token():
    out = subprocess.run(
        [T3, "auth", "session", "issue", "--subject", "mcp-client", "--ttl", "30d",
         "--label", "t3-queue", "--scope", "orchestration:read",
         "--scope", "orchestration:operate", "--token-only"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(out)
    return out


def cached_token():
    try:
        with open(TOKEN_FILE) as f:
            tok = f.read().strip()
            if tok:
                return tok
    except FileNotFoundError:
        pass
    return issue_token()


class Client:
    def __init__(self):
        self.origin = server_origin()
        self.token = cached_token()
        self.session = None
        self.next_id = 0

    def _post(self, body):
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-06-18",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.origin + "/mcp", json.dumps(body).encode(), headers)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                self.session = r.headers.get("Mcp-Session-Id") or self.session
                raw = r.read().decode()
                ctype = r.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise AuthError() from e
            raise
        if not raw.strip():
            return None
        if "event-stream" in ctype:
            raw = [line[5:].strip() for line in raw.splitlines() if line.startswith("data:")][-1]
        return json.loads(raw)

    def _rpc(self, method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            self.next_id += 1
            body["id"] = self.next_id
        return self._post(body)

    def connect(self):
        self.session = None
        self._rpc("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "t3-queue", "version": "1"},
        })
        self._rpc("notifications/initialized", notify=True)

    def call(self, name, args):
        for attempt in range(2):
            try:
                if self.session is None:
                    self.connect()
                res = self._rpc("tools/call", {"name": name, "arguments": args})
                break
            except AuthError:
                if attempt:
                    raise
                self.token = issue_token()
                self.session = None
            except urllib.error.HTTPError as e:
                # Expired MCP session (e.g. after a server restart): reconnect once.
                if attempt or e.code not in (400, 404):
                    raise
                self.session = None
        if "error" in res:
            raise RuntimeError(f"{name}: {res['error']}")
        result = res["result"]
        if result.get("isError"):
            raise RuntimeError(f"{name}: {result.get('content')}")
        return result.get("structuredContent") or json.loads(result["content"][0]["text"])

    def paged(self, name, args, key):
        items, cursor = [], 0
        while cursor is not None:
            page = self.call(name, {**args, "limit": 100, "cursor": cursor})
            items += page[key]
            cursor = page.get("nextCursor")
        return items


def db_thread_flags():
    """(pinned, busy) thread ids from T3's state DB, which the MCP list lacks.

    busy: threads with pending background tasks, which T3 keeps in Working
    ("Waiting") even though their run has completed.
    """
    try:
        db = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=2)
        try:
            pinned = db.execute(
                "select thread_id from orchestration_v2_projection_threads"
                " where json_extract(payload_json, '$.pinnedAt') is not null"
                " and deleted_at is null and archived_at is null"
            ).fetchall()
            busy = db.execute(
                "select t.thread_id from orchestration_v2_projection_threads t"
                " join orchestration_v2_projection_provider_threads p"
                " on p.provider_thread_id = t.active_provider_thread_id"
                " where json_array_length(p.payload_json, '$.pendingBackgroundTasks') > 0"
            ).fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return set(), set()
    return {r[0] for r in pinned}, {r[0] for r in busy}


def is_working(t3, t, busy):
    """T3's Working section: a live run, a run blocked waiting on another
    thread, or pending background tasks. A run waiting on you is Active."""
    if t["status"] in WORKING_STATUSES or t["threadId"] in busy:
        return True
    if t["status"] == "waiting":
        thread = t3.call("t3_thread_read", {"threadId": t["threadId"], "limit": 1})["thread"]
        return not thread.get("pendingRequestCount")
    return False


def snapshot(t3):
    """Threads waiting for you, for the bar and the picker."""
    # Keep each entry's timestamp while its status is unchanged, so the bar
    # announces it once (T3 bumps updatedAt for unrelated reasons).
    previous = {e["session"]: e for e in read_json(QUEUE_FILE)}
    projects = {p["id"]: p["title"] for p in t3.paged("t3_project_list", {}, "projects")}
    threads = t3.paged("t3_thread_list", {"allProjects": True}, "threads")
    pinned, busy = db_thread_flags()
    queue = []
    for t in threads:
        if t.get("parentThreadId") or t["settled"] or t["snoozed"]:
            continue
        working = is_working(t3, t, busy)
        if working and t["threadId"] not in pinned:
            continue
        entry = {
            "session": t["threadId"],
            "window": "-",
            "title": t["title"],
            "status": "working" if working else BAR_STATUS.get(t["status"], "idle"),
            "t3Status": t["status"],
            "project": projects.get(t["projectId"], ""),
            "ts": int(time.mktime(time.strptime(t["updatedAt"][:19], "%Y-%m-%dT%H:%M:%S"))),
            "source": "t3",
            "link": t["link"],
        }
        prev = previous.get(t["threadId"])
        if prev and prev.get("t3Status") == t["status"]:
            entry["ts"] = prev["ts"]
        queue.append(entry)
    # Needs-you first (input, then failures), then newest.
    rank = {"permission": 0, "error": 1, "idle": 2, "working": 3}
    queue.sort(key=lambda e: (rank[e["status"]], -e["ts"]))
    return queue


def write_json(path, value):
    data = json.dumps(value, indent=1)
    try:
        with open(path) as f:
            if f.read() == data:
                return
    except FileNotFoundError:
        pass
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.replace(tmp, path)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def refresh(t3=None):
    write_json(QUEUE_FILE, snapshot(t3 or Client()))


def app_link(link):
    # https://app.t3.codes/threads/<env>/<thread> -> t3code://threads/<env>/<thread>
    return "t3code://threads/" + link.split("/threads/", 1)[1]


def find_link(thread_id):
    for e in read_json(QUEUE_FILE):
        if e["session"] == thread_id:
            return e["link"]
    for t in Client().paged("t3_thread_list", {"allProjects": True}, "threads"):
        if t["threadId"] == thread_id:
            return t["link"]
    sys.exit(f"t3-queue: unknown thread {thread_id}")


def cmd_goto(thread_id):
    # Wait for the launcher to hand the link to the running app (it exits
    # right after); a detached launch could be killed with the summon popup.
    try:
        subprocess.run([T3_DESKTOP, app_link(find_link(thread_id))], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=15)
    except subprocess.TimeoutExpired:
        pass
    focus_t3_window()


def focus_t3_window():
    # Hyprland's Lua config: `hyprctl dispatch focuswindow ...` no longer parses.
    try:
        clients = json.loads(subprocess.run(["hyprctl", "clients", "-j"], capture_output=True,
                                            text=True, check=True).stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return
    address = next((c["address"] for c in clients if c.get("class") == T3_WINDOW_CLASS), None)
    if address:
        lua = f'local w = hl.get_window("address:{address}"); if w then hl.dispatch(hl.dsp.focus({{ window = w }})) end'
        subprocess.run(["hyprctl", "eval", lua], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cmd_prune(thread_id):
    t3 = Client()
    t3.call("t3_thread_organize", {"threadId": thread_id, "action": "settle"})
    write_json(QUEUE_FILE, [e for e in read_json(QUEUE_FILE) if e["session"] != thread_id])


def cmd_watch(interval):
    t3 = None
    while True:
        try:
            t3 = t3 or Client()
            refresh(t3)
        except Exception as e:  # server down or restarting: keep the last queue, retry
            print(f"t3-queue: {e}", file=sys.stderr, flush=True)
            t3 = None
        time.sleep(interval)


ICON = {"permission": "\U000f02d7", "error": "\U000f0026", "idle": "\U000f05e0", "working": "\U000f051f"}
DIM, RESET = "\033[2m", "\033[0m"


def age(ts):
    m = int((time.time() - ts) // 60)
    return f"{m}m" if m < 60 else f"{m // 60}h" if m < 1440 else f"{m // 1440}d"


def queue_lines():
    """Exactly what the bar shows: threads waiting for you."""
    for e in read_json(QUEUE_FILE):
        yield f"{e['session']}\t{ICON[e['status']]}  {e['title']}  {DIM}{e['project']} · {e['t3Status']} · {age(e['ts'])}{RESET}"


def cmd_lines():
    for line in queue_lines():
        print(line)


def self_command(*args):
    # fzf runs commands through sh; the script is a plain (non-executable)
    # .py in the Nix store, so call it through this interpreter.
    return " ".join(shlex.quote(x) for x in (sys.executable, "-I", os.path.realpath(__file__), *args))


def cmd_select():
    """fzf over the queue. The Summon popup preloads it hidden, so it must stay
    current on its own: `fzf-watch` pushes a reload whenever the queue changes
    (same trick as `tmux-projects oc-queue select`)."""
    lines = self_command("lines")
    watch = self_command("fzf-watch")
    r = subprocess.run(
        ["fzf", "--listen", "--ansi", "--delimiter", "\t", "--with-nth", "2", "--no-sort",
         "--layout", "reverse", "--prompt", "T3> ", "--header", "enter: open",
         "--bind", f"start:reload({lines})+execute-silent(nohup {watch} >/dev/null 2>&1 &)"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
    )
    if r.returncode == 0 and r.stdout.strip():
        cmd_goto(r.stdout.split("\t", 1)[0])


def cmd_fzf_watch():
    """Started by fzf (inherits $FZF_PORT): reloads the picker when the queue
    file changes, exits when the picker is gone."""
    port = os.environ.get("FZF_PORT")
    if not port:
        return
    url = f"http://127.0.0.1:{port}"
    reload = f"reload({self_command('lines')})".encode()
    last = None
    while True:
        try:
            urllib.request.urlopen(url, timeout=2).read()
            try:
                current = os.stat(QUEUE_FILE).st_mtime_ns
            except FileNotFoundError:
                current = 0
            if current != last:
                urllib.request.urlopen(urllib.request.Request(url, data=reload, method="POST"), timeout=2).read()
                last = current
        except (urllib.error.URLError, ConnectionError, OSError):
            return
        time.sleep(1)


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "select"
    if cmd == "watch":
        cmd_watch(float(args[1]) if len(args) > 1 else 5)
    elif cmd == "list":
        print(json.dumps(snapshot(Client()), indent=1))
    elif cmd == "lines":
        cmd_lines()
    elif cmd == "fzf-watch":
        cmd_fzf_watch()
    elif cmd == "select":
        cmd_select()
    elif cmd == "goto" and len(args) == 2:
        cmd_goto(args[1])
    elif cmd == "prune" and len(args) == 2:
        cmd_prune(args[1])
    else:
        sys.exit("usage: t3-queue [watch [SECONDS]|list|lines|select|goto THREAD|prune THREAD]")


if __name__ == "__main__":
    main()
