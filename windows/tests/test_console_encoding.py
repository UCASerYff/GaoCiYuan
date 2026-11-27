import os
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.parametrize(
    ('arguments', 'expected_exit', 'stream', 'expected_text'),
    [
        ([], 0, 'stdout', '搞词元 Windows 版'),
        (['--help'], 0, 'stdout', '搞词元 Windows 版'),
        (['--inspect', 'gaociyuan://invalid'], 2, 'stderr', '无效的搞词元深链。'),
    ],
)
def test_console_entry_writes_utf8_to_redirected_streams(tmp_path, arguments, expected_exit, stream, expected_text):
    launcher = Path(__file__).resolve().parents[1] / 'launch_cli.py'
    profile = tmp_path / 'console-profile'
    result = subprocess.run(
        [sys.executable, str(launcher), '--data-dir', str(profile), *arguments],
        capture_output=True,
        env={**os.environ, 'PYTHONIOENCODING': 'cp1252:strict', 'PYTHONUTF8': '0'},
        timeout=10,
    )
    assert result.returncode == expected_exit, result.stderr.decode('utf-8', errors='replace')
    assert expected_text in getattr(result, stream).decode('utf-8')
    assert not profile.exists()
