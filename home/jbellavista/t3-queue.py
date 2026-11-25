"""t3-queue: T3 Code threads that are waiting for you.

Mirrors the opencode attention queue: `watch` keeps
$XDG_RUNTIME_DIR/t3-done-queue.json up to date for the shell bar, `select`
is an fzf picker (the "T3" entry in the Super+D launcher), `goto` opens a
thread in the T3 desktop app and `prune` settles it (so it also leaves T3's
Active inbox).

A thread is waiting when it is top-level, not settled, not snoozed, and its
last run finished, failed, or needs input. It leaves the queue once you
settle it (Ctrl+Shift+S in T3, or dismiss here) and returns on new activity.

Orchestrators are threads whose project folder holds an `.orchestrator`
file, the marker `agent open <name> --orchestrator` creates, so new ones
are picked up automatically. They are listed first in the picker and only enter
the queue when they need input or failed: settling a pinned thread would
move it out of T3's Pinned section, so they are never asked to settle.

Talks to the local T3 server's MCP endpoint with a 30-day "mcp-client"
bearer session cached under $XDG_STATE_HOME/t3-queue/token.
"""

import json
import os
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
ORCH_MARKER = ".orchestrator"
ORCH_VIEW_FILE = os.path.join(os.path.dirname(QUEUE_FILE), "t3-orchestrators.json")
WAITING_STATUSES = {"completed", "failed", "interrupted", "cancelled", "rolled_back", "waiting"}
NEEDS_YOU_STATUSES = {"failed", "waiting"}
# Bar widget vocabulary (shared with the opencode queue): idle | error | permission.
BAR_STATUS = {"failed": "error", "waiting": "permission"}
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


def is_orchestrator_root(root):
    return bool(root) and os.path.exists(os.path.join(root, ORCH_MARKER))


def snapshot(t3):
    """Returns (queue, orchestrators).

    queue: threads waiting for you, for the bar and the picker.
    orchestrators: every thread marked as orchestrator, for the picker.
    Orchestrators only enter the queue when they need you (input or failure),
    never just for finishing, so they never have to be settled.
    """
    # Keep each entry's timestamp while its status is unchanged, so the bar
    # announces it once (T3 bumps updatedAt for unrelated reasons).
    previous = {e["session"]: e for e in read_json(QUEUE_FILE) + read_json(ORCH_VIEW_FILE)}
    project_list = t3.paged("t3_project_list", {}, "projects")
    projects = {p["id"]: p["title"] for p in project_list}
    orch_projects = {p["id"] for p in project_list if is_orchestrator_root(p.get("workspaceRoot"))}
    threads = t3.paged("t3_thread_list", {"allProjects": True}, "threads")
    queue, orchs = [], []
    for t in threads:
        if t.get("parentThreadId"):
            continue
        entry = {
            "session": t["threadId"],
            "window": "-",
            "title": t["title"],
            "status": BAR_STATUS.get(t["status"], "idle"),
            "t3Status": t["status"],
            "project": projects.get(t["projectId"], ""),
            "ts": int(time.mktime(time.strptime(t["updatedAt"][:19], "%Y-%m-%dT%H:%M:%S"))),
            "source": "t3",
            "settled": t["settled"],
            "snoozed": t["snoozed"],
            "link": t["link"],
        }
        prev = previous.get(t["threadId"])
        if prev and prev.get("t3Status") == t["status"]:
            entry["ts"] = prev["ts"]
        is_orch = t["projectId"] in orch_projects
        if is_orch:
            orchs.append(entry)
        if t["snoozed"]:
            continue
        if is_orch:
            if t["status"] in NEEDS_YOU_STATUSES:
                queue.append(entry)
        elif not t["settled"] and t["status"] in WAITING_STATUSES:
            queue.append(entry)
    # Needs-you first (input, then failures), then newest.
    rank = {"permission": 0, "error": 1, "idle": 2}
    queue.sort(key=lambda e: (rank[e["status"]], -e["ts"]))
    orchs.sort(key=lambda e: e["title"].lower())
    return queue, orchs


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
    queue, orchs = snapshot(t3 or Client())
    write_json(QUEUE_FILE, queue)
    write_json(ORCH_VIEW_FILE, orchs)


def app_link(link):
    # https://app.t3.codes/threads/<env>/<thread> -> t3code://threads/<env>/<thread>
    return "t3code://threads/" + link.split("/threads/", 1)[1]


def find_link(thread_id):
    for e in read_json(QUEUE_FILE) + read_json(ORCH_VIEW_FILE):
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
    if any(e["session"] == thread_id for e in read_json(ORCH_VIEW_FILE)):
        return  # settling would drop it out of Pinned; orchestrators clear themselves
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


ICON = {"permission": "\U000f02d7", "error": "\U000f0026", "idle": "\U000f05e0"}
ORCH_ICON = "\U000f0403"
DIM, RESET = "\033[2m", "\033[0m"


def age(ts):
    m = int((time.time() - ts) // 60)
    return f"{m}m" if m < 60 else f"{m // 60}h" if m < 1440 else f"{m // 1440}d"


def parked(e):
    if e.get("snoozed"):
        return "snoozed"
    if e.get("settled"):
        return "settled"
    return e["t3Status"]


def cmd_lines():
    queue = read_json(QUEUE_FILE)
    queued = {e["session"] for e in queue}
    for e in read_json(ORCH_VIEW_FILE):
        flag = f"  {ICON[e['status']]}" if e["session"] in queued else ""
        print(f"{e['session']}\t{ORCH_ICON}  {e['title']}{flag}  {DIM}orchestrator · {e['project']} · {parked(e)}{RESET}")
    for e in queue:
        if e["session"] in {o["session"] for o in read_json(ORCH_VIEW_FILE)}:
            continue
        print(f"{e['session']}\t{ICON[e['status']]}  {e['title']}  {DIM}{e['project']} · {e['t3Status']} · {age(e['ts'])}{RESET}")


def cmd_select():
    me = os.path.realpath(sys.argv[0])
    try:
        refresh()
    except Exception as e:
        print(f"t3-queue: {e}", file=sys.stderr)
    r = subprocess.run(
        ["fzf", "--ansi", "--delimiter", "\t", "--with-nth", "2", "--no-sort", "--layout", "reverse",
         "--prompt", "T3> ",
         "--header", "enter: open · ctrl-x: settle",
         "--bind", f"start:reload({me} lines)",
         "--bind", f"ctrl-x:execute-silent({me} prune {{1}})+reload({me} lines)"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
    )
    if r.returncode == 0 and r.stdout.strip():
        cmd_goto(r.stdout.split("\t", 1)[0])


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "select"
    if cmd == "watch":
        cmd_watch(float(args[1]) if len(args) > 1 else 5)
    elif cmd == "list":
        queue, orchs = snapshot(Client())
        print(json.dumps({"queue": queue, "orchestrators": orchs}, indent=1))
    elif cmd == "lines":
        cmd_lines()
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
