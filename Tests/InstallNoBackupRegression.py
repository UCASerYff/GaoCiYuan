#!/usr/bin/env python3
"""Isolated no-backup installer regression; fake bundles are never executed."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def check(condition, message):
    if not condition:
        raise AssertionError(message)


project_root = Path(__file__).resolve().parents[1]
original = (project_root / 'scripts/install.sh').read_text()
with tempfile.TemporaryDirectory(prefix='gaociyuan-install-no-backup-', suffix='.noindex') as temporary:
    root = Path(temporary)
    stub = root / 'bin'
    stub.mkdir()
    helper = '''#!/usr/bin/env python3
import os,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
target=pathlib.Path(os.environ['FIXTURE_TARGET'])
if name=='pgrep':
    if os.environ.get('FIXTURE_RUNNING') or os.environ.get('FIXTURE_PS_FAIL'): print('555')
    else: sys.exit(1)
elif name=='ps':
    if os.environ.get('FIXTURE_PS_FAIL'): sys.exit(1)
    if os.environ.get('FIXTURE_RUNNING'): print('555 '+str(target/'Contents/MacOS/GaoCiYuan'))
    else: print('556 '+str(target/'Contents/MacOS/GaoCiYuan-copy'))
elif name=='codesign':
    app=pathlib.Path(args[-1])
    if '--verify' in args:
        if not (app/'Contents/Info.plist').is_file(): sys.exit(1)
    elif '-dv' in args: print('TeamIdentifier='+('WRONG' if (app/'bad-team').exists() else '5G96498KGJ'))
    elif '-dr' in args: print('designated => '+('changed' if (app/'bad-dr').exists() else 'fixture-stable-requirement'))
elif name=='lsregister':
    if '-f' in args and os.environ.get('FIXTURE_REGISTER_FAIL'): sys.exit(1)
elif name=='pluginkit':
    if '-r' in args and os.environ.get('FIXTURE_PLUGIN_FAIL'): sys.exit(1)
'''
    for name in ['pgrep', 'ps', 'codesign', 'lsregister', 'pluginkit']:
        path = stub / name
        path.write_text(helper)
        path.chmod(0o700)

    def case(name):
        project = root / name
        target = project / 'Applications/搞词元.app'
        (project / 'scripts').mkdir(parents=True)
        (project / 'scripts/install.sh').write_text(original.replace(
            'TARGET="/Applications/搞词元.app"', f'TARGET="{target}"').replace(
            'LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
            f'LSREGISTER="{stub / "lsregister"}"'))
        (project / 'scripts/install.sh').chmod(0o700)
        info = {'CFBundleIdentifier': 'com.gaoseries.GaoCiYuan', 'CFBundleShortVersionString': '4.13', 'CFBundleVersion': '14'}
        (project / 'Info.plist').write_bytes(plistlib.dumps(info))

        def bundle(path, version, build):
            (path / 'Contents/MacOS').mkdir(parents=True)
            contents = dict(info, CFBundleShortVersionString=version, CFBundleVersion=build)
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(contents))
            (path / 'Contents/MacOS/GaoCiYuan').write_text('Fixture text only; never executable.\n' + version)
            (path / 'Contents/alias').symlink_to('MacOS/GaoCiYuan')

        bundle(target, '4.12', '13')
        source = project / 'build.noindex/搞词元.app'
        source.parent.mkdir()
        bundle(source, '4.13', '14')
        env = dict(os.environ, PATH=str(stub) + os.pathsep + os.environ['PATH'], FIXTURE_TARGET=str(target))

        def run(arguments=(), **extra):
            return subprocess.run(['zsh', str(project / 'scripts/install.sh'), *arguments],
                                  env=dict(env, **extra), text=True, capture_output=True)

        def version():
            return plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']

        return project, target, source, run, version

    project, target, source, run, version = case('success')
    result = run()
    check(result.returncode == 0, result.stderr + result.stdout)
    check(version() == '4.13' and not source.exists(), 'install failed or left expanded build app')
    check(not (project / 'rollback.noindex').exists(), 'installer created a rollback backup')
    check(list(project.rglob('*.zip')) == [], 'installer created an application backup ZIP')
    check(list((project / '.install.noindex').iterdir()) == [], 'expanded staging app remained')
    result = run(('--rollback',))
    check(result.returncode != 0 and version() == '4.13', 'removed rollback route still works')

    project, target, source, run, version = case('registration-failure')
    result = run(FIXTURE_REGISTER_FAIL='1')
    check(result.returncode != 0 and version() == '4.13', 'failure unexpectedly restored or removed the new app')
    check(source.exists(), 'failure removed the pending build')
    check(not (project / 'rollback.noindex').exists(), 'failure created a backup')
    check(list((project / '.install.noindex').iterdir()) == [], 'failure leaked staging')

    project, target, source, run, version = case('widget-unregister-failure')
    extension = target / 'Contents/PlugIns/GaoCiYuanWidgets.appex/Contents'
    extension.mkdir(parents=True)
    (extension / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.gaoseries.GaoCiYuan.widgets'}))
    result = run(FIXTURE_PLUGIN_FAIL='1')
    check(result.returncode != 0 and version() == '4.12', 'widget failure did not stop before replacement')
    check(not (project / 'rollback.noindex').exists(), 'widget failure created a backup')

    for name, option in [('main-running', 'FIXTURE_RUNNING'), ('process-query-failure', 'FIXTURE_PS_FAIL')]:
        project, target, source, run, version = case(name)
        result = run(**{option: '1'})
        check(result.returncode != 0 and version() == '4.12', name + ' incorrectly permitted replacement')
        check(not (project / 'rollback.noindex').exists(), name + ' mutated backups before preflight')

    for name, marker in [('wrong-team', 'bad-team'), ('changed-dr', 'bad-dr')]:
        project, target, source, run, version = case(name)
        (source / marker).write_text('fixture')
        result = run()
        check(result.returncode != 0 and version() == '4.12', name + ' incorrectly permitted replacement')
        check(not (project / 'rollback.noindex').exists(), name + ' created a backup')

with (project_root / 'Info.plist').open('rb') as handle:
    release = plistlib.load(handle)
check((release['CFBundleShortVersionString'], release['CFBundleVersion']) == ('4.13', '14'), 'release version is not 4.13 / 14')
for forbidden in ['--rollback', 'rollback.noindex', 'application.zip', 'receipt.json']:
    check(forbidden not in original, 'obsolete installer surface remains: ' + forbidden)
print('No-backup installer regression passed: isolated install, no rollback/archive/receipt, failure stops without restoration, exact preflight and owned staging cleanup. No real app or user data touched.')
