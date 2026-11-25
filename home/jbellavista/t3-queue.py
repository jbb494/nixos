"""t3-queue: T3 Code threads that are waiting for you.

Mirrors the opencode attention queue: `watch` keeps
$XDG_RUNTIME_DIR/t3-done-queue.json up to date for the shell bar, `select`
is an fzf picker over the same entries (the "T3" entry in the Super+D
launcher), `goto` opens a thread in the T3 desktop app and `prune` settles it.

The queue is T3's sidebar Pinned + Active sections. `watch` follows the same
live feed the T3 app's sidebar uses (the server's internal
`orchestration.subscribeShell` RPC over its /ws socket) and sorts threads
with the sidebar's own rules (ported from T3 0.1.8, see `sidebar_section`).
That feed is not a public API: if a T3 update changes it, the bar shows one
red "T3 tray broken: ..." entry saying what no longer matches.

Settling uses the server's MCP endpoint (a 30-day "mcp-client" token); the
feed uses a separate read-only token. Both are cached under
$XDG_STATE_HOME/t3-queue/.
"""

import asyncio
import datetime
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

T3_BIN_DIR = os.environ.get("T3_BIN_DIR", "/run/current-system/sw/bin")
T3 = os.path.join(T3_BIN_DIR, "t3")
T3_DESKTOP = os.path.join(T3_BIN_DIR, "t3code-desktop")
T3_HOME = os.environ.get("T3CODE_HOME", os.path.expanduser("~/.t3"))
RUNTIME_STATE = os.path.join(T3_HOME, "userdata", "server-runtime.json")
ENVIRONMENT_ID_FILE = os.path.join(T3_HOME, "userdata", "environment-id")
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "t3-queue"
)
TOKEN_FILE = os.path.join(STATE_DIR, "token")
FEED_TOKEN_FILE = os.path.join(STATE_DIR, "feed-token")
QUEUE_FILE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "t3-done-queue.json"
)
T3_WINDOW_CLASS = "com.t3tools.T3Code"
ERROR_SESSION = "t3-queue-error"

# The live feed's protocol (packages/contracts/src/environment.ts in T3).
ORCHESTRATION_PROTOCOL = "2"
SHELL_RPC = "orchestration.subscribeShell"
# Run states T3 counts as a live run (client runtime "active" statuses).
ACTIVE_RUN_STATUSES = {"preparing", "queued", "starting", "running", "waiting"}
# Fields the sidebar rules read; a T3 update that drops one breaks the tray.
REQUIRED_THREAD_FIELDS = ("id", "projectId", "title", "status", "lineage", "archivedAt",
                          "settledOverride", "pendingRuntimeRequest", "updatedAt")


class AuthError(Exception):
    pass


def server_origin():
    with open(RUNTIME_STATE) as f:
        return json.load(f)["origin"]


def environment_id():
    with open(ENVIRONMENT_ID_FILE) as f:
        return f.read().strip()


def issue_token(path=TOKEN_FILE, subject="mcp-client", scopes=("orchestration:read", "orchestration:operate")):
    args = [T3, "auth", "session", "issue", "--subject", subject, "--ttl", "30d",
            "--label", "t3-queue", "--token-only"]
    for scope in scopes:
        args += ["--scope", scope]
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(out)
    return out


def issue_feed_token():
    # The feed socket refuses "mcp-client" tokens, so it gets its own, read-only.
    return issue_token(FEED_TOKEN_FILE, "t3-queue-feed", ("orchestration:read",))


def cached_token(path=TOKEN_FILE, issue=issue_token):
    try:
        with open(path) as f:
            tok = f.read().strip()
            if tok:
                return tok
    except FileNotFoundError:
        pass
    return issue()


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


class FeedBroken(Exception):
    """The live feed no longer looks like T3 0.1.8's: shown in the bar."""


def parse_time(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def is_listed(t):
    # isListedThreadLineage: subagents and side chats live inside their parent.
    lineage = t["lineage"]
    return lineage.get("relationshipToParent") != "subagent" and lineage.get("sideChat") is not True


def has_request(t):
    req = t["pendingRuntimeRequest"]
    return req is not None and req.get("kind") != "auth_refresh"


def holds_completion(tasks):
    # backgroundWorkHoldsCompletion: commands and monitors only when awaited.
    return any(task.get("awaited") is True or task.get("kind") in ("subagent", "background_task")
               for task in tasks)


def sidebar_section(t, threads, env, now, children_asking):
    """The section T3's sidebar puts a thread in, or None when it isn't listed.

    Port of the 0.1.8 client: snoozed, then settled, then pinned, then Working
    (a live run, a run blocked on another thread, or background work that
    holds completion, unless something waits on you), else Active.
    """
    if t["archivedAt"] is not None or not is_listed(t):
        return None
    parent = t.get("delegatedFrom")
    if parent and parent.get("environmentId") == env and parent.get("threadId") in threads:
        return None  # delegated work is shown under its (live) parent
    snoozed_until = parse_time(t.get("snoozedUntil"))
    if snoozed_until is not None and snoozed_until > now:
        return "snoozed"
    if t["settledOverride"] == "settled":
        return "settled"
    if t.get("pinnedAt") is not None:
        return "pinned"
    return "working" if is_working(t, children_asking) else "active"


def needs_you(t, children_asking):
    return (has_request(t) or t["id"] in children_asking
            or (t.get("pendingGuestMessageCount") or 0) > 0)


def is_working(t, children_asking):
    if needs_you(t, children_asking):
        return False
    run = t.get("activityRunStatus") or t["status"]
    return run in ACTIVE_RUN_STATUSES or holds_completion(t.get("pendingBackgroundTasks") or [])


def build_queue(threads, projects, env, previous):
    """Pinned + Active threads as bar entries."""
    now = time.time()
    for t in threads.values():
        missing = [k for k in REQUIRED_THREAD_FIELDS if k not in t]
        if missing:
            raise FeedBroken(f"thread data lacks {', '.join(missing)}")
    children_asking = {
        t["lineage"].get("parentThreadId") for t in threads.values()
        if t["lineage"].get("relationshipToParent") == "subagent" and has_request(t)
    }
    queue = []
    for t in threads.values():
        section = sidebar_section(t, threads, env, now, children_asking)
        if section not in ("pinned", "active"):
            continue
        working = is_working(t, children_asking)
        if needs_you(t, children_asking):
            status, label = "permission", "needs you"
        elif t["status"] == "failed" or t.get("lastError"):
            status, label = "error", "failed"
        elif working:
            status, label = "working", t.get("activityRunStatus") or t["status"]
        else:
            status, label = "idle", t["status"]
        entry = {
            "session": t["id"],
            "window": "-",
            "title": t["title"],
            "status": status,
            "t3Status": label,
            "project": projects.get(t["projectId"], ""),
            "ts": int(parse_time(t.get("latestRunCompletedAt")) or parse_time(t["updatedAt"]) or now),
            "source": "t3",
            "link": f"t3code://threads/{env}/{urllib.parse.quote(t['id'], safe='')}",
        }
        # Keep the timestamp while the state is unchanged, so the bar
        # announces each entry once.
        prev = previous.get(t["id"])
        if prev and prev.get("status") == status and prev.get("t3Status") == label:
            entry["ts"] = prev["ts"]
        queue.append(entry)
    # Needs-you first (input, then failures), then newest; pinned-but-running last.
    rank = {"permission": 0, "error": 1, "idle": 2, "working": 3}
    queue.sort(key=lambda e: (rank[e["status"]], -e["ts"]))
    return queue


def error_queue(message):
    """One red bar entry instead of a silently wrong tray."""
    prev = next((e for e in read_json(QUEUE_FILE) if e.get("session") == ERROR_SESSION), None)
    title = f"T3 tray broken: {message}"
    return [{
        "session": ERROR_SESSION,
        "window": "-",
        "title": title,
        "status": "error",
        "t3Status": "t3-queue",
        "project": "journalctl --user -u t3-queue",
        "ts": prev["ts"] if prev and prev.get("title") == title else int(time.time()),
        "source": "t3",
        "link": "",
    }]


class ShellFeed:
    """Client for T3's sidebar feed: an Effect RPC stream over a WebSocket."""

    def __init__(self):
        self.threads = {}
        self.projects = {}
        self.ready = False

    async def run(self, on_change):
        import websockets  # only `watch`/`list` need it

        origin = server_origin()
        url = origin.replace("http", "ws", 1) + f"/ws?orchestrationProtocol={ORCHESTRATION_PROTOCOL}"
        token = cached_token(FEED_TOKEN_FILE, issue_feed_token)
        for attempt in range(2):
            try:
                ws = await websockets.connect(
                    url, additional_headers={"Authorization": f"Bearer {token}"},
                    max_size=None, open_timeout=10)
                break
            except websockets.exceptions.InvalidStatus as e:
                code = e.response.status_code
                body = e.response.body.decode(errors="replace") if e.response.body else ""
                if code == 426:
                    try:
                        wanted = json.loads(body).get("orchestrationProtocolVersion")
                    except (json.JSONDecodeError, AttributeError):
                        wanted = "?"
                    raise FeedBroken(f"T3 feed protocol changed ({ORCHESTRATION_PROTOCOL} → {wanted})")
                if code in (401, 403) and attempt == 0:
                    token = issue_feed_token()
                    continue
                raise FeedBroken(f"feed refused the connection (HTTP {code})")
        async with ws:
            await ws.send(json.dumps({"_tag": "Request", "id": "1", "tag": SHELL_RPC,
                                      "payload": {}, "headers": []}))
            pinger = asyncio.create_task(self._ping(ws))
            try:
                async for raw in ws:
                    data = json.loads(raw)
                    for msg in data if isinstance(data, list) else [data]:
                        await self._handle(ws, msg)
                    if self.ready:
                        on_change(self)
            finally:
                pinger.cancel()

    async def _ping(self, ws):
        while True:
            await asyncio.sleep(20)
            await ws.send(json.dumps({"_tag": "Ping"}))

    async def _handle(self, ws, msg):
        tag = msg.get("_tag")
        if tag == "Chunk":
            await ws.send(json.dumps({"_tag": "Ack", "requestId": msg["requestId"]}))
            for item in msg["values"]:
                self._apply(item)
        elif tag == "Pong":
            pass
        elif tag == "Exit":
            raise FeedBroken(f"feed ended: {json.dumps(msg.get('exit'))[:200]}")
        else:
            raise FeedBroken(f"unexpected feed message {json.dumps(msg)[:200]}")

    def _apply(self, item):
        kind = item.get("kind")
        if kind == "snapshot":
            snap = item["snapshot"]
            if "resolvedRepositoryIdentityRoots" in item:
                # Partial refresh of project details; threads unchanged.
                self.projects.update({p["id"]: p["title"] for p in snap["projects"]})
                return
            self.threads = {t["id"]: t for t in snap["threads"]}
            self.projects = {p["id"]: p["title"] for p in snap["projects"]}
            self.ready = True
        elif kind == "thread.updated":
            t = item["thread"]
            if item["location"] == "active":
                self.threads[t["id"]] = t
            else:
                self.threads.pop(t["id"], None)
        elif kind == "thread.removed":
            self.threads.pop(item["threadId"], None)
        elif kind == "project.updated":
            self.projects[item["project"]["id"]] = item["project"]["title"]
        elif kind == "project.removed":
            self.projects.pop(item["projectId"], None)
        elif kind in ("synchronized", "snapshot-required"):
            pass
        else:
            raise FeedBroken(f"unknown feed item {kind!r}")


def queue_from_feed(feed, env):
    previous = {e["session"]: e for e in read_json(QUEUE_FILE)}
    try:
        return build_queue(feed.threads, feed.projects, env, previous)
    except (KeyError, TypeError, AttributeError, ValueError) as e:
        raise FeedBroken(f"thread data changed shape ({type(e).__name__}: {e})") from e


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


def app_link(link):
    # https://app.t3.codes/threads/<env>/<thread> or t3code://threads/... -> t3code://threads/<env>/<thread>
    return "t3code://threads/" + link.split("threads/", 1)[1]


def find_link(thread_id):
    for e in read_json(QUEUE_FILE):
        if e["session"] == thread_id:
            return e["link"]
    for t in Client().paged("t3_thread_list", {"allProjects": True}, "threads"):
        if t["threadId"] == thread_id:
            return t["link"]
    sys.exit(f"t3-queue: unknown thread {thread_id}")


def cmd_goto(thread_id):
    if thread_id == ERROR_SESSION:
        return
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
    if thread_id == ERROR_SESSION:  # just hide it until the next retry
        write_json(QUEUE_FILE, [e for e in read_json(QUEUE_FILE) if e["session"] != thread_id])
        return
    t3 = Client()
    t3.call("t3_thread_organize", {"threadId": thread_id, "action": "settle"})
    write_json(QUEUE_FILE, [e for e in read_json(QUEUE_FILE) if e["session"] != thread_id])


def cmd_watch():
    """Follow the feed; on a T3 update that breaks it, show the error and retry."""
    env = environment_id()

    def on_change(feed):
        write_json(QUEUE_FILE, queue_from_feed(feed, env))

    while True:
        delay = 3
        try:
            asyncio.run(ShellFeed().run(on_change))
        except FeedBroken as e:
            print(f"t3-queue: {e}", file=sys.stderr, flush=True)
            write_json(QUEUE_FILE, error_queue(str(e)))
            delay = 30
        except (OSError, EOFError, json.JSONDecodeError) as e:
            # T3 closed or restarting: nothing to go to.
            print(f"t3-queue: feed down ({type(e).__name__}: {e})", file=sys.stderr, flush=True)
            write_json(QUEUE_FILE, [])
        except Exception as e:  # websockets' ConnectionClosed and friends
            print(f"t3-queue: feed closed ({type(e).__name__}: {e})", file=sys.stderr, flush=True)
        time.sleep(delay)


def cmd_list():
    """The queue from one fresh snapshot (for testing)."""
    env = environment_id()
    result = {}

    class Done(Exception):
        pass

    def on_change(feed):
        result["queue"] = queue_from_feed(feed, env)
        raise Done()

    try:
        asyncio.run(ShellFeed().run(on_change))
    except Done:
        pass
    print(json.dumps(result.get("queue", []), indent=1))


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
        cmd_watch()  # an old "SECONDS" argument is ignored
    elif cmd == "list":
        cmd_list()
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
        sys.exit("usage: t3-queue [watch|list|lines|select|goto THREAD|prune THREAD]")


if __name__ == "__main__":
    main()
