"""Bundle only pywebview's Windows x64 Edge WebView2 renderer and assets."""

from pathlib import Path

from PyInstaller.utils.hooks import copy_metadata, get_package_paths


_, package_path = get_package_paths('webview')
package = Path(package_path)
loader_dir = 'lib/runtimes/win-x64/native'

datas = [(str(package / 'js'), 'webview/js'), *copy_metadata('pywebview')]
binaries = [
    (str(package / 'lib' / name), 'webview/lib')
    for name in ('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll')
]
binaries.append((str(package / loader_dir / 'WebView2Loader.dll'), f'webview/{loader_dir}'))
hiddenimports = ['webview.platforms.winforms', 'webview.platforms.edgechromium']
excludedimports = [
    f'webview.platforms.{name}' for name in ('android', 'cef', 'cocoa', 'gtk', 'mshtml', 'qt')
]
