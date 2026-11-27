"""开发目录与 PyInstaller 解包目录里的只读页面资源。"""

from __future__ import annotations

import sys
from pathlib import Path


def asset_dir() -> Path:
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen) / "gaociyuan_assets"
    return Path(__file__).resolve().parent / "assets"


def brand_dir() -> Path:
    frozen = getattr(sys, "_MEIPASS", None)
    return Path(frozen) / "gaociyuan_brand" if frozen else Path(__file__).resolve().parents[3] / "Resources"
