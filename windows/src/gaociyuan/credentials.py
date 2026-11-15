"""凭据只进 Windows 凭据管理器和 DPAPI。library.json 不保存密钥。"""

from __future__ import annotations

import sys
from pathlib import Path

from gaociyuan.errors import AppError

SERVICE = "com.gaoseries.GaoQiNianSan.credentials"
CRED_MAX = 2560


def target_name(account_id: str) -> str:
    return f"GaoCiYuan:{SERVICE}:{account_id}"


class MemoryCredentialStore:
    backend = "memory"

    def __init__(self) -> None:
        self._items: dict[str, str] = {}

    def put(self, account_id: str, secret: str) -> None:
        _require_secret(secret)
        self._items[account_id] = secret

    def get(self, account_id: str) -> str | None:
        return self._items.get(account_id)

    def delete(self, account_id: str) -> None:
        self._items.pop(account_id, None)

    def has(self, account_id: str) -> bool:
        return account_id in self._items


class WindowsCredentialStore:
    """DPAPI 文件是持久副本；长度允许时同时写入凭据管理器。"""

    backend = "windows"

    def __init__(self, directory: Path):
        if sys.platform != "win32":
            raise AppError("Windows 凭据库只能在 Windows 上使用。", "platform")
        self.directory = Path(directory) / "credentials"

    def put(self, account_id: str, secret: str) -> None:
        _require_secret(secret)
        blob = secret.encode("utf-8")
        self.directory.mkdir(parents=True, exist_ok=True)
        path = self._path(account_id)
        protected = _protect(blob)
        temporary = path.with_suffix(".tmp")
        temporary.write_bytes(protected)
        temporary.replace(path)
        if len(blob) <= CRED_MAX:
            _cred_write(account_id, blob)
        else:
            _cred_delete(account_id)

    def get(self, account_id: str) -> str | None:
        path = self._path(account_id)
        if path.is_file():
            try:
                return _unprotect(path.read_bytes()).decode("utf-8")
            except OSError as exc:
                raise AppError("凭据无法读取。", "credential") from exc
        blob = _cred_read(account_id)
        if blob is None:
            return None
        return blob.decode("utf-8")

    def delete(self, account_id: str) -> None:
        path = self._path(account_id)
        if path.exists():
            path.unlink()
        _cred_delete(account_id)

    def has(self, account_id: str) -> bool:
        return self.get(account_id) is not None

    def _path(self, account_id: str) -> Path:
        safe = account_id.replace("/", "").replace("\\", "")
        return self.directory / f"{safe}.dpapi"


def open_credential_store(directory: Path, force_memory: bool = False):
    if force_memory or sys.platform != "win32":
        return MemoryCredentialStore()
    return WindowsCredentialStore(directory)


def _require_secret(secret: str) -> None:
    if not isinstance(secret, str) or not secret.strip():
        raise AppError("凭据不能为空。", "credential")


def _protect(blob: bytes) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    incoming = DATA_BLOB(len(blob), ctypes.cast(ctypes.create_string_buffer(blob), ctypes.POINTER(ctypes.c_char)))
    outgoing = DATA_BLOB()
    if not crypt32.CryptProtectData(ctypes.byref(incoming), "GaoCiYuan", None, None, None, 0, ctypes.byref(outgoing)):
        raise AppError("DPAPI 无法保护凭据。", "credential")
    try:
        return ctypes.string_at(outgoing.pbData, outgoing.cbData)
    finally:
        kernel32.LocalFree(outgoing.pbData)


def _unprotect(blob: bytes) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    incoming = DATA_BLOB(len(blob), ctypes.cast(ctypes.create_string_buffer(blob), ctypes.POINTER(ctypes.c_char)))
    outgoing = DATA_BLOB()
    if not crypt32.CryptUnprotectData(ctypes.byref(incoming), None, None, None, None, 0, ctypes.byref(outgoing)):
        raise AppError("DPAPI 无法解开凭据。", "credential")
    try:
        return ctypes.string_at(outgoing.pbData, outgoing.cbData)
    finally:
        kernel32.LocalFree(outgoing.pbData)


def _credential_type():
    return 1  # CRED_TYPE_GENERIC


def _cred_write(account_id: str, blob: bytes) -> None:
    import ctypes
    from ctypes import wintypes

    class CREDENTIALW(ctypes.Structure):
        _fields_ = [
            ("Flags", wintypes.DWORD),
            ("Type", wintypes.DWORD),
            ("TargetName", wintypes.LPWSTR),
            ("Comment", wintypes.LPWSTR),
            ("LastWritten", wintypes.FILETIME),
            ("CredentialBlobSize", wintypes.DWORD),
            ("CredentialBlob", ctypes.POINTER(ctypes.c_char)),
            ("Persist", wintypes.DWORD),
            ("AttributeCount", wintypes.DWORD),
            ("Attributes", ctypes.c_void_p),
            ("TargetAlias", wintypes.LPWSTR),
            ("UserName", wintypes.LPWSTR),
        ]

    advapi = ctypes.windll.advapi32
    buffer = ctypes.create_string_buffer(blob)
    credential = CREDENTIALW()
    credential.Type = _credential_type()
    credential.TargetName = target_name(account_id)
    credential.Comment = "搞词元 Agent 凭据"
    credential.CredentialBlobSize = len(blob)
    credential.CredentialBlob = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char))
    credential.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE
    credential.UserName = account_id
    credential.AttributeCount = 0
    if not advapi.CredWriteW(ctypes.byref(credential), 0):
        raise AppError("无法写入 Windows 凭据管理器。", "credential")


def _cred_read(account_id: str) -> bytes | None:
    import ctypes
    from ctypes import wintypes

    class CREDENTIALW(ctypes.Structure):
        _fields_ = [
            ("Flags", wintypes.DWORD),
            ("Type", wintypes.DWORD),
            ("TargetName", wintypes.LPWSTR),
            ("Comment", wintypes.LPWSTR),
            ("LastWritten", wintypes.FILETIME),
            ("CredentialBlobSize", wintypes.DWORD),
            ("CredentialBlob", ctypes.POINTER(ctypes.c_char)),
            ("Persist", wintypes.DWORD),
            ("AttributeCount", wintypes.DWORD),
            ("Attributes", ctypes.c_void_p),
            ("TargetAlias", wintypes.LPWSTR),
            ("UserName", wintypes.LPWSTR),
        ]

    advapi = ctypes.windll.advapi32
    pointer = ctypes.POINTER(CREDENTIALW)()
    found = advapi.CredReadW(target_name(account_id), _credential_type(), 0, ctypes.byref(pointer))
    if not found:
        return None
    try:
        size = int(pointer.contents.CredentialBlobSize)
        return ctypes.string_at(pointer.contents.CredentialBlob, size)
    finally:
        advapi.CredFree(pointer)


def _cred_delete(account_id: str) -> None:
    import ctypes

    ctypes.windll.advapi32.CredDeleteW(target_name(account_id), _credential_type(), 0)
