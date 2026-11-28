"""Opt-in Windows appcast check and explicit Ed25519-verified download."""

from __future__ import annotations

import base64
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, url2pathname
from xml.etree import ElementTree

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from gaociyuan.errors import AppError
from gaociyuan.version import MARKETING_VERSION, WINDOWS_BUILD

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
VERSION = re.compile(r'v?(\d{1,6}(?:\.\d{1,6}){0,5})', re.IGNORECASE)
PACKAGE = re.compile(r'GaoCiYuan-Windows-[\d.]+(?:-build\d+)?-x64\.(?:exe|zip)', re.IGNORECASE)
FEED_LIMIT = 1024 * 1024
PACKAGE_LIMIT = 200 * 1024 * 1024


def version_parts(value: str) -> tuple[int, ...]:
    match = VERSION.fullmatch(value.strip())
    if match is None:
        raise ValueError('invalid version')
    parts = tuple(int(part) for part in match[1].split('.'))
    return parts + (0,) * (6 - len(parts))


def update_url(value: str) -> str:
    try:
        parsed = urlsplit(value)
        if parsed.scheme == 'https' and parsed.hostname and parsed.username is None and parsed.password is None:
            parsed.port
            return value
        if parsed.scheme == 'file' and not parsed.netloc and not parsed.query and not parsed.fragment:
            path = url2pathname(parsed.path)
            if not path.startswith(('\\\\', '//')) and Path(path).is_absolute():
                return value
    except (TypeError, ValueError):
        pass
    raise AppError('更新源须使用 HTTPS 或本机文件。', 'update_url')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def read_resource(url: str, limit: int, seconds: int) -> bytes:
    url = update_url(url)
    parsed = urlsplit(url)
    deadline = time.monotonic() + seconds
    try:
        if parsed.scheme == 'file':
            response = open(url2pathname(parsed.path), 'rb')
        else:
            request = Request(url, headers={'User-Agent': f'GaoCiYuan-Windows/{MARKETING_VERSION}'})
            response = build_opener(NoRedirect()).open(request, timeout=min(seconds, 12))
        with response:
            chunks = bytearray()
            read = getattr(response, 'read1', response.read)
            while time.monotonic() < deadline:
                chunk = read(min(256 * 1024, limit + 1 - len(chunks)))
                if not chunk:
                    return bytes(chunks)
                chunks.extend(chunk)
                if len(chunks) > limit:
                    raise AppError('更新文件超过大小限制。', 'update_size')
    except (OSError, ValueError) as exc:
        raise AppError('无法读取更新源。请核对地址和连接。', 'update_read') from exc
    raise AppError('更新读取超时。', 'update_timeout')


@dataclass(frozen=True)
class Update:
    version: str
    url: str
    signature: str
    expected_length: int | None
    suffix: str
    build: int | None = None

    @property
    def display_version(self) -> str:
        return self.version if self.build is None else f'{self.version}+{self.build}'

    @property
    def sort_key(self) -> tuple[tuple[int, ...], int]:
        return (version_parts(self.version), self.build or 0)


def _windows_pe_build(marketing: str, full_version: str) -> int | None:
    full = VERSION.fullmatch(full_version.strip())
    if full is None:
        return None
    prefix = marketing.split('.')
    parts = full[1].split('.')
    if parts[:len(prefix)] != prefix:
        return None
    suffix = parts[len(prefix):]
    if len(suffix) != 1 and (len(suffix) != 2 or suffix[1] != '0'):
        return None
    build = int(suffix[0])
    return build if 0 < build <= 65_535 else None


def parse_appcast(data: bytes) -> list[Update]:
    try:
        xml = data.decode('utf-8-sig')
        if '<!DOCTYPE' in xml.upper() or '<!ENTITY' in xml.upper():
            raise ValueError('DTD not allowed')
        document = ElementTree.fromstring(xml)
    except (ElementTree.ParseError, UnicodeError, ValueError) as exc:
        raise AppError('更新源不是有效的 appcast XML。', 'update_feed') from exc
    items = []
    for entry in document.findall('.//item'):
        title_version = entry.findtext(SPARKLE + 'shortVersionString') or ''
        entry_version = entry.findtext(SPARKLE + 'version') or ''
        entry_os = entry.findtext(SPARKLE + 'os') or ''
        for enclosure in entry.findall('enclosure'):
            attributes = enclosure.attrib
            platform = attributes.get(SPARKLE + 'os', entry_os).strip().lower()
            architecture = attributes.get(SPARKLE + 'arch', '').strip().lower()
            if platform and platform not in ('windows', 'win32', 'win64', 'windows-x64'):
                continue
            if architecture and architecture not in ('x64', 'amd64', 'x86_64'):
                continue
            market_version = title_version or attributes.get(SPARKLE + 'shortVersionString') or ''
            enclosure_version = attributes.get(SPARKLE + 'version', '')
            candidate = market_version or enclosure_version
            try:
                version_parts(candidate)
                url = update_url(attributes.get('url', ''))
                filename = Path(unquote(urlsplit(url).path)).name.lower()
                suffix = Path(filename).suffix
                if suffix not in ('.exe', '.zip') or not platform and not ('windows' in filename and 'x64' in filename):
                    continue
                length = int(attributes['length']) if attributes.get('length') else None
                if length is not None and not 0 < length <= PACKAGE_LIMIT:
                    continue
            except (AppError, ValueError):
                continue
            normalized = VERSION.fullmatch(candidate.strip())[1]
            build = _windows_pe_build(normalized, enclosure_version or entry_version) if platform and market_version else None
            items.append(Update(normalized, url, attributes.get(SPARKLE + 'edSignature', ''), length, suffix, build))
    return items


class UpdateService:
    def __init__(self, directory: Path):
        self.directory = directory / 'updates'
        self.source = ''
        self.available: Update | None = None
        self.public_state: dict = {'status': 'unconfigured', 'version': MARKETING_VERSION}

    def check(self, source: str) -> dict:
        source = source.strip()
        self.source = source
        self.available = None
        self.public_state = {'status': 'unconfigured', 'version': MARKETING_VERSION}
        if not source:
            return self.public_state
        items = parse_appcast(read_resource(source, FEED_LIMIT, 15))
        if not items:
            raise AppError('更新源中没有可用的 Windows x64 条目。', 'update_feed')
        latest = max(items, key=lambda item: item.sort_key)
        if latest.sort_key > (version_parts(MARKETING_VERSION), int(WINDOWS_BUILD)):
            self.available = latest
        status = 'available' if self.available else 'current'
        self.public_state = {'status': status, 'version': self.available.display_version if self.available else MARKETING_VERSION}
        return self.public_state

    def download(self, source: str, public_key: str) -> dict:
        item = self.available
        if item is None or self.source != source.strip():
            raise AppError('请先检查可用的 Windows 更新。', 'update_unavailable')
        try:
            key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key.strip(), validate=True))
            signature = base64.b64decode(item.signature, validate=True)
            if len(signature) != 64:
                raise ValueError('invalid signature size')
        except ValueError as exc:
            raise AppError('更新源缺少有效的 Ed25519 公钥或签名。', 'update_signature') from exc
        payload = read_resource(item.url, item.expected_length or PACKAGE_LIMIT, 90)
        try:
            if item.expected_length is not None and len(payload) != item.expected_length:
                raise InvalidSignature
            key.verify(signature, payload)
        except InvalidSignature as exc:
            raise AppError('更新包签名或长度验证失败。', 'update_signature') from exc
        self.directory.mkdir(parents=True, exist_ok=True)
        version_suffix = item.version if item.build is None else f'{item.version}-build{item.build}'
        destination = self.directory / f'GaoCiYuan-Windows-{version_suffix}-x64{item.suffix}'
        temporary = destination.with_suffix('.partial')
        try:
            temporary.write_bytes(payload)
            if os.name == 'nt' and urlsplit(item.url).scheme == 'https':
                Path(f'{temporary}:Zone.Identifier').write_text('[ZoneTransfer]\nZoneId=3\n', encoding='ascii')
            os.replace(temporary, destination)
        except OSError as exc:
            raise AppError('无法将验证通过的更新包写到资料目录。', 'update_write') from exc
        finally:
            temporary.unlink(missing_ok=True)
        for previous in self.directory.iterdir():
            if previous != destination and PACKAGE.fullmatch(previous.name) and previous.is_file():
                previous.unlink(missing_ok=True)
        return {'path': str(destination), 'version': item.display_version}
