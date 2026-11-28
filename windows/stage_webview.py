"""Stage the pinned pywebview package with the x64 runtime lookup used by our bundle."""

from importlib.metadata import version
from importlib.util import find_spec
from pathlib import Path
from shutil import copytree, ignore_patterns
import sys


MULTI_ARCH_LOOKUP = (
    "for platform in ('win-arm64', 'win-x64', 'win-x86'):\n"
    "    os.environ['Path'] += ';' + interop_dll_path(platform)\n"
)
X64_LOOKUP = "os.environ['Path'] += ';' + interop_dll_path('win-x64')\n"


def x64_backend(source: str) -> str:
    if source.count(MULTI_ARCH_LOOKUP) != 1:
        raise ValueError('Recheck the pinned pywebview Edge loader lookup before building.')
    return source.replace(MULTI_ARCH_LOOKUP, X64_LOOKUP)


def stage(output: Path) -> None:
    spec = find_spec('webview')
    if spec is None or spec.origin is None or version('pywebview') != '6.1':
        raise ValueError('The Windows build expects pywebview 6.1.')
    package = Path(spec.origin).parent
    backend = Path('platforms', 'edgechromium.py')
    selected = x64_backend((package / backend).read_text(encoding='utf-8'))
    staged_package = output / 'webview'
    copytree(package, staged_package, ignore=ignore_patterns(
        '__pycache__', 'win-arm64', 'win-x86', 'WebBrowserInterop.*', 'pywebview-android.jar',
    ))
    (staged_package / backend).write_text(selected, encoding='utf-8')


if __name__ == '__main__':
    stage(Path(sys.argv[1]))
