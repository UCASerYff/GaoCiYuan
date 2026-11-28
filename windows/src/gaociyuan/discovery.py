"""Discover Windows Agent installations without opening their data stores."""

from __future__ import annotations

import ctypes
import os
import re
import time
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from gaociyuan.catalog import (
    AGENT_LOCAL, ANTIGRAVITY_REPORT, CLAUDE_STATUSLINE, CODEX, DSH, GEMINI_APP, KIMI_DESKTOP,
    WORKBUDDY, agent_software, default_agent_name, default_connection,
)


@dataclass(frozen=True)
class Identity:
    apps: tuple[str, ...] = ()
    commands: tuple[str, ...] = ()
    names: tuple[str, ...] = ()


IDENTITIES = {
    "openai": Identity(("Codex", "ChatGPT"), ("codex",), ("OpenAI Codex",)),
    "claude": Identity(("Claude",), ("claude",), ("Claude Code",)),
    "gemini": Identity(("Antigravity", "Antigravity IDE"), ("antigravity", "agy")),
    "grok": Identity(("Grok Bot", "Grok"), names=("GrokBot",)),
    "deepseek": Identity(("DeepSeek",)),
    "kimi": Identity(("Kimi", "Kimi Work"), ("kimi",), ("Kimi Code",)),
    "glm": Identity(("Zcode",), ("zcode",), ("ZCode CLI",)),
    "qwen": Identity(commands=("qwen",)),
    "qoder": Identity(("Qoder", "QoderCN"), ("qodercli", "qoder")),
    "doubao": Identity(("Doubao", "豆包", "豆包 Work")),
    "minimax": Identity(("MiniMax", "MiniMax Code"), ("mmx",)),
    "workbuddy": Identity(("WorkBuddy",), ("workbuddy",)),
    "mimo": Identity(("MiMo", "MiMo Agent"), ("mimo-code", "mimo")),
    "cursor": Identity(("Cursor",), ("cursor-agent", "cursor")),
    "copilot": Identity(commands=("copilot",), names=("GitHub Copilot CLI",)),
    "devin": Identity(("Devin", "Windsurf"), ("devin",)),
    "ollama": Identity(("Ollama",), ("ollama",)),
    "commandcode": Identity(commands=("command-code", "cmdc"), names=("Command Code",)),
    "dsh": Identity(("DeepSeek Harness", "DeepSeekHarness"), ("dsh",)),
    "opencode": Identity(("OpenCode",), ("opencode",)),
    "cline": Identity(("Cline",), ("cline",)),
    "factory": Identity(("Factory Droid",), ("droid",), ("Droid",)),
    "zed": Identity(("Zed",), ("zed",)),
    "kiro": Identity(("Kiro",), ("kiro-cli",)),
    "trae": Identity(("Trae", "Trae CN"), ("trae",)),
}

AUTOMATIC_ROUTES = {
    "openai": (CODEX, "USD"),
    "claude": (CLAUDE_STATUSLINE, "USD"),
    "gemini": (ANTIGRAVITY_REPORT, "USD"),
    "grok": (AGENT_LOCAL, "USD"),
    "kimi": (KIMI_DESKTOP, "CNY"),
    "doubao": (AGENT_LOCAL, "CNY"),
    "dsh": (DSH, "CNY"),
    "workbuddy": (WORKBUDDY, "CNY"),
}

LOCAL_RAIL_CONNECTIONS = {AGENT_LOCAL, CODEX, CLAUDE_STATUSLINE, GEMINI_APP, KIMI_DESKTOP,
                          DSH, WORKBUDDY, "Claude 桌面会话", "Cursor 编辑器登录态", "Devin 本机保存 plan"}
_PACKAGE_FAMILIES = {"codex": "OpenAI.Codex_2p2nqsd0c76g0", "claude": "Claude_pzs8sxrjxfjjc"}


def automatic_provider(account: dict) -> str | None:
    provider = account.get("provider")
    if provider not in AUTOMATIC_ROUTES:
        return None
    if provider == "grok" and account.get("connection") != AGENT_LOCAL:
        return None
    if provider == "gemini" and account.get("connection") != ANTIGRAVITY_REPORT:
        return None
    return provider


def _normalize(name: str) -> str:
    return re.sub(r"\s+\((?:x64|x86|arm64|user)\)$", "", name.strip().casefold())


def _read_registry(identities: dict[str, Identity]) -> tuple[set[str], set[str]]:
    import winreg

    app_names = {f"{name.casefold()}.exe" for item in identities.values() for name in item.apps}
    app_paths = r"Software\Microsoft\Windows\CurrentVersion\App Paths"
    uninstall = r"Software\Microsoft\Windows\CurrentVersion\Uninstall"
    named, registered = set(), set()
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for view in (winreg.KEY_WOW64_32KEY, winreg.KEY_WOW64_64KEY):
            access = winreg.KEY_READ | view
            for executable in app_names:
                try:
                    with winreg.OpenKey(hive, app_paths + "\\" + executable, 0, access) as key:
                        path, _ = winreg.QueryValueEx(key, "")
                    if Path(os.path.expandvars(path.strip('"'))).is_file():
                        registered.add(executable[:-4])
                except (OSError, TypeError, AttributeError):
                    continue
            try:
                with winreg.OpenKey(hive, uninstall, 0, access) as entries:
                    for index in range(winreg.QueryInfoKey(entries)[0]):
                        try:
                            with winreg.OpenKey(entries, winreg.EnumKey(entries, index), 0, access) as entry:
                                label, _ = winreg.QueryValueEx(entry, "DisplayName")
                            if isinstance(label, str):
                                named.add(_normalize(label))
                        except OSError:
                            continue
            except OSError:
                continue
    return named, registered


class _ProcessEntry(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", wintypes.LONG), ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.WCHAR * 260),
    ]


def _running_names() -> set[str]:
    """Use the supported Tool Help process snapshot, limited to this interactive session."""
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateToolhelp32Snapshot
    create.argtypes, create.restype = (wintypes.DWORD, wintypes.DWORD), wintypes.HANDLE
    first, next_entry = kernel.Process32FirstW, kernel.Process32NextW
    for func in (first, next_entry):
        func.argtypes, func.restype = (wintypes.HANDLE, ctypes.POINTER(_ProcessEntry)), wintypes.BOOL
    session_id = kernel.ProcessIdToSessionId
    session_id.argtypes, session_id.restype = (wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)), wintypes.BOOL
    close = kernel.CloseHandle
    close.argtypes, close.restype = (wintypes.HANDLE,), wintypes.BOOL
    own_session = wintypes.DWORD()
    if not session_id(os.getpid(), ctypes.byref(own_session)):
        return set()
    result = set()
    snapshot = create(2, 0)  # TH32CS_SNAPPROCESS
    if snapshot == ctypes.c_void_p(-1).value:
        return result
    try:
        entry = _ProcessEntry()
        entry.dwSize = ctypes.sizeof(entry)
        found = first(snapshot, ctypes.byref(entry))
        while found:
            session = wintypes.DWORD()
            if session_id(entry.th32ProcessID, ctypes.byref(session)) and session.value == own_session.value:
                result.add(Path(entry.szExeFile).stem.casefold())
            found = next_entry(snapshot, ctypes.byref(entry))
    finally:
        close(snapshot)
    return result


def _installed_packages() -> set[str]:
    """Check known MSIX identities through the current user's package registration."""
    get_packages = ctypes.WinDLL("kernel32", use_last_error=True).GetPackagesByPackageFamily
    uint_pointer = ctypes.POINTER(wintypes.UINT)
    get_packages.argtypes = (wintypes.LPCWSTR, uint_pointer, ctypes.POINTER(wintypes.LPWSTR), uint_pointer, wintypes.LPWSTR)
    get_packages.restype = wintypes.LONG
    installed = set()
    for name, family in _PACKAGE_FAMILIES.items():
        count, length = wintypes.UINT(), wintypes.UINT()
        status = get_packages(family, ctypes.byref(count), None, ctypes.byref(length), None)
        if status in (0, 122) and count.value > 0:  # success or requested array size provided
            installed.add(name)
    return installed


def _path_roots() -> list[Path]:
    roots = []
    for raw in os.environ.get("PATH", "").split(os.pathsep):
        path = Path(raw.strip('"'))
        if path.is_absolute() and path not in roots:
            roots.append(path)
    return roots


def find_command(names: tuple[str, ...], *, native: bool = False) -> Path | None:
    endings = (".exe",) if native else (".exe", ".cmd", ".bat")
    for directory in _path_roots():
        if str(directory).startswith(("\\\\", "//")):
            continue
        for name in names:
            for ending in endings:
                path = directory / (name + ending)
                if path.is_file():
                    return path
    return None


def _known_install(identity: Identity) -> bool:
    roots = []
    for key in ("LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)"):
        raw = os.environ.get(key)
        if raw:
            roots.append(Path(raw))
            if key == "LOCALAPPDATA":
                roots.append(Path(raw) / "Programs")
    return any((root / name / (name + ".exe")).is_file() for name in identity.apps for root in roots)


def collect_observations() -> list[dict]:
    if os.name != "nt":
        return []
    names, registered = _read_registry(IDENTITIES)
    return observations_from(names, registered | _installed_packages(), _running_names(), find_command, _known_install)


def observations_from(
    installed_names: set[str],
    registered_apps: set[str],
    running_names: set[str],
    command_path: Callable[[tuple[str, ...]], Path | None],
    known_install: Callable[[Identity], bool],
) -> list[dict]:
    result = []
    for provider, identity in IDENTITIES.items():
        app_names = {name.casefold() for name in identity.apps}
        cli = command_path(identity.commands) if identity.commands else None
        command_names = set(identity.commands)
        app_running = bool((app_names - command_names) & running_names)
        is_running = app_running or bool(command_names & running_names)
        app_installed = (
            app_running or bool(app_names & (installed_names | registered_apps)) or known_install(identity)
            or bool(identity.apps and {_normalize(name) for name in identity.names} & installed_names)
        )
        recognized = any(_normalize(name) in installed_names for name in identity.names)
        if app_installed or is_running or cli or recognized:
            result.append({
                "id": provider, "provider": provider, "softwareName": agent_software(provider),
                "isRunning": is_running, "cliPath": str(cli) if cli else None,
                "appInstalled": app_installed,
                "status": "软件运行中" if is_running else "未启动",
                "defaultConnection": default_connection(provider),
            })
    return result


class ProviderDiscovery:
    def __init__(self, enabled: bool = True, collect: Callable[[], list[dict]] = collect_observations):
        self.enabled = enabled
        self._collect = collect
        self._rows: list[dict] = []
        self._collected_at = float("-inf")
        self.completed = False

    def observations(self, force: bool = False) -> list[dict]:
        if self.enabled and (force or time.monotonic() - self._collected_at >= 30):
            self._rows = self._collect()
            self._collected_at = time.monotonic()
            self.completed = True
        return self._rows

    @staticmethod
    def automatic_accounts(observations: list[dict]) -> list[dict]:
        installed = {row["provider"] for row in observations}
        return [
            {"provider": provider, "connection": connection, "currency": currency,
             "name": default_agent_name(provider), "autoDiscovered": True}
            for provider, (connection, currency) in AUTOMATIC_ROUTES.items()
            # A detected installation is not proof of authorization or API access.
            if provider in installed and provider != "dsh"
        ]

    def rail_visible(self, account: dict) -> bool:
        if not account.get("showInRail", True):
            return False
        # Hide auto-discovered desktop routes on verified uninstall. Keep user-created
        # routes (including CLI shims and manual Grok reports) independently usable.
        if not self.completed or not account.get("autoDiscovered") or account.get("connection") not in LOCAL_RAIL_CONNECTIONS:
            return True
        provider = account.get("provider")
        return provider not in IDENTITIES or any(row["provider"] == provider for row in self._rows)
