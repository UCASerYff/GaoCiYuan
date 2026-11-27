"""Translate registered Windows deep links into app navigation only."""

import re
from urllib.parse import parse_qs, urlencode, urlsplit

VIEWS = {'overview', 'agents', 'catalog', 'analytics', 'settings'}
ACCOUNT_ID = re.compile(r'[A-Za-z0-9_-]{1,128}')


def app_fragment(page: str = 'overview', account: str = '') -> str:
    if page not in VIEWS or account and (page not in ('agents', 'overview') or not ACCOUNT_ID.fullmatch(account)):
        raise ValueError('invalid app route')
    return '#' + page + ('?' + urlencode({'account': account}) if account else '')


def deep_link(value: str) -> str:
    if len(value) > 1024 or '\\' in value or any(ord(ch) < 32 for ch in value):
        raise ValueError('invalid deep link')
    parsed = urlsplit(value)
    query = parse_qs(parsed.query, max_num_fields=1, strict_parsing=True)
    if parsed.scheme != 'gaociyuan' or parsed.path not in ('', '/') or parsed.fragment or query.keys() - {'account'}:
        raise ValueError('invalid deep link')
    return app_fragment(parsed.netloc.lower(), query.get('account', [''])[0])
