from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from xml.sax.saxutils import quoteattr

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from gaociyuan.errors import AppError
from gaociyuan.routes import deep_link
from gaociyuan.store import TokenStore
from gaociyuan.timeutil import format_iso
from gaociyuan.updates import UpdateService, parse_appcast
from gaociyuan.web import serve

NOW = datetime(2026, 11, 27, 8, tzinfo=timezone.utc)


def test_platform_filtered_updates_require_explicit_verified_download(tmp_path):
    update = tmp_path / 'GaoCiYuan-Windows-4.14-x64-Setup.exe'
    original = b'synthetic build only'
    update.write_bytes(original)
    key = Ed25519PrivateKey.generate()
    public_key = base64.b64encode(key.public_key().public_bytes_raw()).decode()
    signature = base64.b64encode(key.sign(original)).decode()
    feed = tmp_path / 'appcast.xml'
    feed.write_text(f'''<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
      <item><enclosure s:os="macos" s:version="99.0" url={quoteattr(update.as_uri())} /></item>
      <item><enclosure s:os="windows" s:arch="arm64" s:version="98.0" url={quoteattr(update.as_uri())} /></item>
      <item><s:shortVersionString>v4.14</s:shortVersionString><enclosure s:os="windows" s:arch="x64"
        url={quoteattr(update.as_uri())} s:edSignature="{signature}" length="{len(original)}" /></item>
      </channel></rss>''', encoding='utf-8')
    service = UpdateService(tmp_path)
    assert service.check(feed.as_uri()) == {'status': 'available', 'version': '4.14'}
    assert not service.directory.exists()
    update.write_bytes(b'X' * len(original))
    with pytest.raises(AppError, match='签名'):
        service.download(feed.as_uri(), public_key)
    assert not service.directory.exists()
    update.write_bytes(original)
    result = service.download(feed.as_uri(), public_key)
    assert (service.directory / 'GaoCiYuan-Windows-4.14-x64.exe').read_bytes() == original
    assert result['version'] == '4.14'
    with pytest.raises(AppError):
        service.download('https://example.invalid/changed.xml', public_key)


def test_routes_and_loopback_hosts_are_validated(tmp_path):
    assert deep_link('gaociyuan://analytics') == '#analytics'
    assert deep_link('gaociyuan://agents?account=fixture-1') == '#agents?account=fixture-1'
    for link in ('https://example.invalid/analytics', 'gaociyuan://analytics?account=ids',
                 'gaociyuan://overview?account=../../outside', 'gaociyuan://example.invalid'):
        with pytest.raises(ValueError):
            deep_link(link)
    with pytest.raises(AppError):
        parse_appcast(b'<!DOCTYPE rss [<!ENTITY a "stuff">]><rss>&a;</rss>')
    store = TokenStore(tmp_path)
    server = serve(store, open_browser=False, start_timer=False)
    try:
        for headers in ({'Host': 'example.invalid'}, {'Origin': 'https://example.invalid'}):
            with pytest.raises(HTTPError) as result:
                urlopen(Request(server.url, headers=headers), timeout=5)
            assert result.value.code == 403
        with urlopen(server.url + 'brand/GaoCiYuanIcon.png', timeout=5) as result:
            assert result.headers['content-type'] == 'image/png'
        with urlopen(server.url + 'panel', timeout=5) as result:
            assert b'/panel.js' in result.read()
    finally:
        server.shutdown()
        server.server_close()


def test_alerts_rearm_and_survive_reload_without_duplicate_history(tmp_path):
    now = [NOW]
    notice = []
    store = TokenStore(tmp_path, now=lambda: now[0])
    store.notify = lambda account, message: notice.append((account['id'], message))
    store.update_settings({'notifyThreshold': 90, 'notifyOnReset': True, 'notifyFailures': True, 'notifyExhausted': True})
    path = tmp_path / 'fixture-snapshot.json'
    account = store.save_account({'provider': 'openai', 'name': '测试 Agent', 'connection': '自动读取快照文件', 'filePath': str(path)})

    def report(used, reset):
        data = {'observedAt': format_iso(now[0]), 'quotas': [{'id': 'week', 'title': '每周', 'usedPercent': used, 'resetsAt': format_iso(reset)}]}
        path.write_text(json.dumps(data), encoding='utf-8')

    reset = NOW + timedelta(days=1)
    report(94, reset)
    store.refresh(account['id'], user_initiated=True)
    assert notice[-1][1] == '每周 已用 90%'
    now[0] += timedelta(minutes=30)
    report(94, reset)
    store.refresh(account['id'], user_initiated=True)
    assert account['snapshot']['observedAt'] == format_iso(now[0])
    assert len(account['history']) == 1
    assert len(notice) == 1

    reopened = TokenStore(tmp_path, now=lambda: now[0])
    reopened.notify = store.notify
    reopened.refresh(account['id'], user_initiated=True)
    assert len(notice) == 1
    report(5, reset + timedelta(days=7))
    reopened.refresh(account['id'], user_initiated=True)
    assert notice[-1][1] == '每周 已重置'
    path.unlink()
    for _ in range(4):
        reopened.refresh(account['id'], user_initiated=True)
    assert len(notice) == 3
    assert '无法读取' in notice[-1][1]


def test_bulk_refresh_and_draft_test_never_read_the_grok_contract(tmp_path):
    store = TokenStore(tmp_path, now=lambda: NOW)
    grok = store.save_account({'provider': 'grok', 'connection': '本机软件自动读取'})
    with pytest.raises(AppError, match='读取本机额度'):
        store.test_account(grok)
    store.refresh_all()
    store.refresh_due()
    assert store.grok_reads == 0
