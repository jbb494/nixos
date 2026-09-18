#!/usr/bin/env python3
"""Generic, declaratively configured desktop popup broker."""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass, field
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time
from typing import Any


ID_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
CLASS_PATTERN = re.compile(r"^[a-zA-Z][a-zA-Z0-9_.-]{2,255}$")
ADDRESS_PATTERN = re.compile(r"^0x[0-9a-f]+$", re.IGNORECASE)
MAX_MESSAGE_BYTES = 16 * 1024


class SummonError(RuntimeError):
    pass


@dataclass(frozen=True)
class PopupSpec:
    identifier: str
    command: tuple[str, ...]
    window_class: str
    title: str
    working_directory: str
    environment: dict[str, str]
    preload: bool
    max_width: int
    max_height: int
    width_ratio: float
    height_ratio: float


@dataclass
class PopupState:
    spec: PopupSpec
    process: subprocess.Popen[bytes] | None = None
    generation: int = 0
    address: str | None = None
    ready: asyncio.Event = field(default_factory=asyncio.Event)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    open_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


def runtime_directory() -> Path:
    override = os.environ.get("SUMMON_RUNTIME_DIR")
    if override:
        if not os.path.isabs(override):
            raise SummonError("SUMMON_RUNTIME_DIR must be absolute.")
        return Path(override)
    value = os.environ.get("XDG_RUNTIME_DIR")
    if not value or not os.path.isabs(value):
        value = f"/run/user/{os.getuid()}"
    return Path(value) / "summon"


def socket_path() -> Path:
    return runtime_directory() / "control.sock"


def require_string(value: Any, name: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        raise SummonError(f"{name} must be a non-empty string.")
    if "\0" in value:
        raise SummonError(f"{name} cannot contain NUL.")
    return value


def require_number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise SummonError(f"{name} must be a finite number.")
    result = float(value)
    if result < minimum or result > maximum:
        raise SummonError(f"{name} must be between {minimum} and {maximum}.")
    return result


def parse_config(value: Any) -> dict[str, PopupSpec]:
    if not isinstance(value, dict) or set(value) != {"apps"} or not isinstance(value["apps"], dict):
        raise SummonError("The configuration must contain only an apps object.")

    result: dict[str, PopupSpec] = {}
    classes: set[str] = set()
    for identifier, raw in value["apps"].items():
        if not isinstance(identifier, str) or not ID_PATTERN.fullmatch(identifier):
            raise SummonError(f"Invalid popup identifier: {identifier!r}.")
        if not isinstance(raw, dict):
            raise SummonError(f"Popup {identifier} must be an object.")
        allowed = {
            "command", "class", "title", "workingDirectory", "environment", "preload",
            "maxWidth", "maxHeight", "widthRatio", "heightRatio",
        }
        unknown = set(raw) - allowed
        if unknown:
            raise SummonError(f"Popup {identifier} has unknown settings: {', '.join(sorted(unknown))}.")

        command_value = raw.get("command")
        if not isinstance(command_value, list) or not command_value:
            raise SummonError(f"Popup {identifier}.command must be a non-empty list.")
        command = tuple(require_string(item, f"Popup {identifier}.command") for item in command_value)
        if not os.path.isabs(command[0]):
            raise SummonError(f"Popup {identifier}.command[0] must be an absolute path.")

        window_class = require_string(raw.get("class"), f"Popup {identifier}.class")
        if not CLASS_PATTERN.fullmatch(window_class) or "." not in window_class:
            raise SummonError(f"Popup {identifier}.class must be a valid GTK application identifier.")
        if window_class in classes:
            raise SummonError(f"Popup class {window_class} is registered more than once.")
        classes.add(window_class)

        environment_value = raw.get("environment", {})
        if not isinstance(environment_value, dict):
            raise SummonError(f"Popup {identifier}.environment must be an object.")
        environment = {
            require_string(key, f"Popup {identifier}.environment key"): require_string(item, f"Popup {identifier}.environment.{key}", nonempty=False)
            for key, item in environment_value.items()
        }
        preload = raw.get("preload", False)
        if not isinstance(preload, bool):
            raise SummonError(f"Popup {identifier}.preload must be a boolean.")

        result[identifier] = PopupSpec(
            identifier=identifier,
            command=command,
            window_class=window_class,
            title=require_string(raw.get("title", identifier), f"Popup {identifier}.title"),
            working_directory=require_string(raw.get("workingDirectory", str(Path.home())), f"Popup {identifier}.workingDirectory"),
            environment=environment,
            preload=preload,
            max_width=int(require_number(raw.get("maxWidth", 1100), f"Popup {identifier}.maxWidth", 1, 16384)),
            max_height=int(require_number(raw.get("maxHeight", 820), f"Popup {identifier}.maxHeight", 1, 16384)),
            width_ratio=require_number(raw.get("widthRatio", 0.85), f"Popup {identifier}.widthRatio", 0.1, 1),
            height_ratio=require_number(raw.get("heightRatio", 0.85), f"Popup {identifier}.heightRatio", 0.1, 1),
        )
    return result


def read_config(path: Path) -> dict[str, PopupSpec]:
    try:
        if path.stat().st_size > 1024 * 1024:
            raise SummonError("The configuration is unexpectedly large.")
        return parse_config(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError) as error:
        raise SummonError(f"Could not read configuration {path}: {error}") from error


def lua_string(value: str) -> str:
    output: list[str] = ['"']
    for character in value:
        codepoint = ord(character)
        if character in {'\\', '"'}:
            output.append(f"\\{character}")
        elif codepoint < 32 or codepoint == 127:
            output.append(f"\\{codepoint:03d}")
        else:
            output.append(character)
    output.append('"')
    return "".join(output)


def popup_target(monitors: Any, spec: PopupSpec) -> tuple[int | str, int, int]:
    if not isinstance(monitors, list):
        raise SummonError("Hyprland returned an invalid monitor list.")
    monitor = next((item for item in monitors if isinstance(item, dict) and item.get("focused") is True), None)
    if monitor is None:
        raise SummonError("Hyprland has no focused monitor.")
    try:
        scale = float(monitor["scale"])
        monitor_width = float(monitor["width"])
        monitor_height = float(monitor["height"])
        transform = int(monitor.get("transform", 0))
        reserved = monitor["reserved"]
        active = monitor["activeWorkspace"]
        special = monitor["specialWorkspace"]
        if scale <= 0 or len(reserved) != 4:
            raise ValueError
        rotated = transform % 2 != 0
        usable_width = (monitor_height if rotated else monitor_width) / scale - float(reserved[0]) - float(reserved[2])
        usable_height = (monitor_width if rotated else monitor_height) / scale - float(reserved[1]) - float(reserved[3])
        workspace: int | str = special["name"] if int(special["id"]) != 0 else int(active["id"])
    except (KeyError, TypeError, ValueError, IndexError) as error:
        raise SummonError("Hyprland returned invalid focused-monitor data.") from error
    if usable_width <= 0 or usable_height <= 0 or workspace == "":
        raise SummonError("The focused monitor has no usable workspace.")
    return (
        workspace,
        max(1, math.floor(min(spec.max_width, usable_width * spec.width_ratio))),
        max(1, math.floor(min(spec.max_height, usable_height * spec.height_ratio))),
    )


def workspace_lua(workspace: int | str) -> str:
    return str(workspace) if isinstance(workspace, int) else lua_string(workspace)


def popup_rule(spec: PopupSpec, width: int, height: int, hidden_workspace: str) -> str:
    return f'''hl.window_rule({{
  name = {lua_string(f"summon-{spec.identifier}")},
  match = {{ class = {lua_string(f"^{re.escape(spec.window_class)}$")} }},
  float = true, center = true,
  size = {{ {width}, {height} }},
  workspace = {lua_string(f"special:{hidden_workspace} silent")}
}})'''


def focus_popup(spec: PopupSpec, address: str, workspace: int | str, width: int, height: int) -> str:
    if not ADDRESS_PATTERN.fullmatch(address):
        raise SummonError("Hyprland returned an invalid popup address.")
    return f'''local window = hl.get_window({lua_string(f"address:{address}")})
if not window or not window.mapped or window.class ~= {lua_string(spec.window_class)} then
  error("Summon popup disappeared.")
end
hl.dispatch(hl.dsp.window.float({{ window = window, action = "on" }}))
hl.dispatch(hl.dsp.window.move({{ window = window, workspace = {workspace_lua(workspace)}, follow = false }}))
hl.dispatch(hl.dsp.window.resize({{ window = window, x = {width}, y = {height}, relative = false }}))
hl.dispatch(hl.dsp.window.center({{ window = window }}))
hl.dispatch(hl.dsp.focus({{ window = window }}))'''


def popup_command(spec: PopupSpec, generation: int, host_pid: int | None = None) -> list[str]:
    scope = f"summon-popup-{spec.identifier}-{host_pid or os.getpid()}-{generation}"
    return [
        "systemd-run", "--user", "--scope", "--quiet", "--collect", f"--unit={scope}", "--",
        "ghostty",
        f"--class={spec.window_class}",
        f"--title={spec.title}",
        "--gtk-single-instance=false",
        "--wait-after-command=false",
        "--quit-after-last-window-closed=true",
        f"--working-directory={spec.working_directory}",
        "--window-width=120",
        "--window-height=38",
        "-e",
        *spec.command,
    ]


class PopupHost:
    def __init__(self, specs: dict[str, PopupSpec], directory: Path) -> None:
        self.states = {identifier: PopupState(spec) for identifier, spec in specs.items()}
        self.directory = directory
        self.hidden_workspace = "summon"
        self.shutting_down = False
        self.tasks: set[asyncio.Task[Any]] = set()

    def add_task(self, coroutine: Any) -> asyncio.Task[Any]:
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    async def hyprctl(self, *arguments: str) -> str:
        process = await asyncio.create_subprocess_exec(
            "hyprctl", *arguments,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=2)
        except TimeoutError:
            process.kill()
            await process.wait()
            raise SummonError("Hyprland did not respond within two seconds.")
        if process.returncode != 0:
            message = stderr.decode("utf-8", "replace").strip() or "unknown error"
            raise SummonError(f"hyprctl failed: {message}")
        return stdout.decode("utf-8", "replace")

    async def evaluate(self, code: str) -> None:
        result = (await self.hyprctl("eval", code)).strip()
        if result != "ok":
            raise SummonError(f"Hyprland rejected a popup operation: {result}")

    async def monitors(self) -> Any:
        try:
            return json.loads(await self.hyprctl("-j", "monitors"))
        except json.JSONDecodeError as error:
            raise SummonError("Hyprland returned invalid monitor JSON.") from error

    async def clients(self) -> Any:
        try:
            value = json.loads(await self.hyprctl("-j", "clients"))
        except json.JSONDecodeError as error:
            raise SummonError("Hyprland returned invalid client JSON.") from error
        if not isinstance(value, list):
            raise SummonError("Hyprland returned an invalid client list.")
        return value

    async def start(self) -> None:
        monitors = await self.monitors()
        for state in self.states.values():
            _, width, height = popup_target(monitors, state.spec)
            await self.evaluate(popup_rule(state.spec, width, height, self.hidden_workspace))
        await asyncio.gather(*(self.ensure_started(state) for state in self.states.values() if state.spec.preload))

    def popup_environment(self, spec: PopupSpec) -> dict[str, str]:
        environment = dict(os.environ)
        environment.update(spec.environment)
        for name in ("TMUX", "TMUX_PANE", "STY"):
            environment.pop(name, None)
        environment["SUMMON_POPUP_ID"] = spec.identifier
        return environment

    async def ensure_started(self, state: PopupState) -> None:
        async with state.lock:
            if state.process is not None and state.process.poll() is None:
                return
            state.ready.clear()
            state.address = None
            state.generation += 1
            generation = state.generation
            log_path = self.directory / f"{state.spec.identifier}.log"
            flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(log_path, flags, 0o600)
            try:
                state.process = subprocess.Popen(
                    popup_command(state.spec, generation),
                    stdin=subprocess.DEVNULL,
                    stdout=descriptor,
                    stderr=descriptor,
                    env=self.popup_environment(state.spec),
                    start_new_session=True,
                )
            finally:
                os.close(descriptor)
            process = state.process
            self.add_task(self.discover_window(state, process, generation))
            self.add_task(self.watch_process(state, process, generation))

    async def discover_window(self, state: PopupState, process: subprocess.Popen[bytes], generation: int) -> None:
        deadline = time.monotonic() + 10
        while not self.shutting_down and time.monotonic() < deadline:
            if process.poll() is not None:
                return
            try:
                clients = await self.clients()
            except SummonError:
                await asyncio.sleep(0.1)
                continue
            window = next((
                client for client in clients
                if isinstance(client, dict)
                and client.get("mapped") is True
                and client.get("class") == state.spec.window_class
                and client.get("pid") == process.pid
                and isinstance(client.get("address"), str)
                and ADDRESS_PATTERN.fullmatch(client["address"])
            ), None)
            if window is not None:
                async with state.lock:
                    if state.generation == generation and state.process is process:
                        state.address = window["address"]
                        state.ready.set()
                return
            await asyncio.sleep(0.05)

    async def watch_process(self, state: PopupState, process: subprocess.Popen[bytes], generation: int) -> None:
        return_code = await asyncio.to_thread(process.wait)
        async with state.lock:
            if state.generation != generation or state.process is not process:
                return
            state.process = None
            state.address = None
            state.ready.clear()
        if not self.shutting_down:
            print(f"summon: {state.spec.identifier} exited with status {return_code}", file=sys.stderr, flush=True)
            if state.spec.preload:
                await asyncio.sleep(0.2)
                await self.ensure_started(state)

    async def validate_window(self, state: PopupState) -> str:
        process = state.process
        address = state.address
        if process is None or process.poll() is not None or address is None:
            raise SummonError(f"Popup {state.spec.identifier} is not ready.")
        clients = await self.clients()
        valid = any(
            isinstance(client, dict)
            and client.get("mapped") is True
            and client.get("address") == address
            and client.get("class") == state.spec.window_class
            and client.get("pid") == process.pid
            for client in clients
        )
        if not valid:
            state.address = None
            state.ready.clear()
            self.add_task(self.discover_window(state, process, state.generation))
            raise SummonError(f"Popup {state.spec.identifier} window disappeared.")
        return address

    async def open(self, identifier: str) -> None:
        state = self.states.get(identifier)
        if state is None:
            raise SummonError(f"Unknown popup: {identifier}")
        async with state.open_lock:
            await self.ensure_started(state)
            try:
                await asyncio.wait_for(state.ready.wait(), timeout=10)
            except TimeoutError as error:
                raise SummonError(f"Timed out waiting for popup {identifier}.") from error
            address = await self.validate_window(state)
            workspace, width, height = popup_target(await self.monitors(), state.spec)
            await self.evaluate(focus_popup(state.spec, address, workspace, width, height))

    async def close(self, identifier: str) -> None:
        state = self.states.get(identifier)
        if state is None:
            raise SummonError(f"Unknown popup: {identifier}")
        process = state.process
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def status(self) -> dict[str, Any]:
        return {
            identifier: {
                "preload": state.spec.preload,
                "running": state.process is not None and state.process.poll() is None,
                "ready": state.ready.is_set(),
            }
            for identifier, state in self.states.items()
        }

    async def stop(self) -> None:
        self.shutting_down = True
        processes = [state.process for state in self.states.values() if state.process is not None and state.process.poll() is None]
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        if processes:
            await asyncio.gather(*(asyncio.to_thread(process.wait, 2) for process in processes), return_exceptions=True)
        for process in processes:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for task in list(self.tasks):
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)


async def send_response(writer: asyncio.StreamWriter, value: dict[str, Any]) -> None:
    writer.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    await writer.drain()


async def handle_client(host: PopupHost, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        line = await asyncio.wait_for(reader.readline(), timeout=2)
        if not line or len(line) > MAX_MESSAGE_BYTES or not line.endswith(b"\n"):
            raise SummonError("Invalid control message.")
        request = json.loads(line)
        if not isinstance(request, dict) or set(request) - {"action", "id"}:
            raise SummonError("Invalid control request.")
        action = request.get("action")
        if action == "open":
            identifier = require_string(request.get("id"), "id")
            await host.open(identifier)
            result: Any = {"id": identifier, "state": "open"}
        elif action == "close":
            identifier = require_string(request.get("id"), "id")
            await host.close(identifier)
            result = {"id": identifier, "state": "closing"}
        elif action == "status":
            if "id" in request:
                raise SummonError("status does not accept an id.")
            result = host.status()
        else:
            raise SummonError(f"Unknown control action: {action!r}")
        await send_response(writer, {"ok": True, "result": result})
    except (SummonError, json.JSONDecodeError) as error:
        await send_response(writer, {"ok": False, "error": str(error)})
    except Exception as error:
        print(f"summon: unexpected request error: {error}", file=sys.stderr, flush=True)
        await send_response(writer, {"ok": False, "error": "Internal Summon error."})
    finally:
        writer.close()
        await writer.wait_closed()


async def run_daemon(config_path: Path) -> None:
    specs = read_config(config_path)
    directory = runtime_directory()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    control_socket = socket_path()
    if control_socket.exists() or control_socket.is_socket():
        try:
            mode = control_socket.lstat().st_mode
            if not stat.S_ISSOCK(mode):
                raise SummonError(f"Refusing to replace non-socket path {control_socket}.")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.2)
            try:
                probe.connect(str(control_socket))
            except (ConnectionRefusedError, FileNotFoundError):
                control_socket.unlink(missing_ok=True)
            else:
                raise SummonError("Another Summon service is already running.")
            finally:
                probe.close()
        except OSError as error:
            raise SummonError(f"Could not prepare control socket: {error}") from error

    host = PopupHost(specs, directory)
    await host.start()
    server = await asyncio.start_unix_server(lambda reader, writer: handle_client(host, reader, writer), path=str(control_socket), limit=MAX_MESSAGE_BYTES)
    os.chmod(control_socket, 0o600)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stopped.set)
    print(f"summon: serving {len(specs)} popup(s)", file=sys.stderr, flush=True)
    try:
        await stopped.wait()
    finally:
        server.close()
        await server.wait_closed()
        await host.stop()
        try:
            control_socket.unlink()
        except FileNotFoundError:
            pass


def request_daemon(action: str, identifier: str | None) -> Any:
    request = {"action": action}
    if identifier is not None:
        request["id"] = identifier
    path = socket_path()
    started = False
    deadline = time.monotonic() + 4
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(12)
                connection.connect(str(path))
                connection.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
                response = b""
                while not response.endswith(b"\n") and len(response) <= MAX_MESSAGE_BYTES:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    response += chunk
            if not response.endswith(b"\n") or len(response) > MAX_MESSAGE_BYTES:
                raise SummonError("Summon returned an invalid response.")
            decoded = json.loads(response)
            if not isinstance(decoded, dict) or not isinstance(decoded.get("ok"), bool):
                raise SummonError("Summon returned an invalid response.")
            if not decoded["ok"]:
                raise SummonError(require_string(decoded.get("error"), "Summon error"))
            return decoded.get("result")
        except (FileNotFoundError, ConnectionRefusedError):
            if not started:
                subprocess.run(["systemctl", "--user", "start", "summon.service"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                started = True
            if time.monotonic() >= deadline:
                raise SummonError("Summon service is unavailable. Check `systemctl --user status summon.service`.")
            time.sleep(0.05)
        except (OSError, json.JSONDecodeError) as error:
            raise SummonError(f"Could not contact Summon: {error}") from error


def main() -> None:
    parser = argparse.ArgumentParser(prog=Path(sys.argv[0]).name, description="Open registered desktop popups.")
    subparsers = parser.add_subparsers(dest="action", required=True)
    daemon_parser = subparsers.add_parser("daemon", help=argparse.SUPPRESS)
    daemon_parser.add_argument("--config", type=Path, required=True)
    for action in ("open", "close"):
        action_parser = subparsers.add_parser(action)
        action_parser.add_argument("id")
    subparsers.add_parser("status")
    arguments = parser.parse_args()
    if arguments.action == "daemon":
        asyncio.run(run_daemon(arguments.config))
        return
    result = request_daemon(arguments.action, getattr(arguments, "id", None))
    if arguments.action == "status":
        print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except SummonError as error:
        print(f"summon: {error}", file=sys.stderr)
        raise SystemExit(1)
