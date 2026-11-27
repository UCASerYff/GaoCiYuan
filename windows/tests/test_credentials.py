import sys
import uuid

import pytest

from gaociyuan.credentials import MemoryCredentialStore, target_name


def test_memory_store_round_trip():
    vault = MemoryCredentialStore()
    vault.put("abc", "value")
    assert vault.get("abc") == "value"
    assert vault.has("abc")
    vault.delete("abc")
    assert vault.get("abc") is None
    assert target_name("abc").startswith("GaoCiYuan:com.gaoseries.GaoQiNianSan.credentials:")


@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI and Credential Manager")
def test_windows_dpapi_and_credential_manager(tmp_path):
    from gaociyuan.credentials import WindowsCredentialStore, _cred_read

    vault = WindowsCredentialStore(tmp_path)
    account = 'test-' + str(uuid.uuid4())
    try:
        vault.put(account, "windows-secret")
        assert vault.get(account) == "windows-secret"
        assert _cred_read(account) == b"windows-secret"
        assert b"windows-secret" not in (tmp_path / "credentials" / f'{account}.dpapi').read_bytes()
    finally:
        vault.delete(account)
    assert vault.get(account) is None
