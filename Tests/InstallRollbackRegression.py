#!/usr/bin/env python3
"""Isolated installer regression; fake bundles are never executed or registered."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def check(condition, message):
    if not condition:
        raise AssertionError(message)


original = (Path(__file__).resolve().parents[1] / 'scripts/install.sh').read_text()
with tempfile.TemporaryDirectory(prefix='gaociyuan-install-fixture-', suffix='.noindex') as temporary:
    root = Path(temporary)
    stub = root / 'bin'
    stub.mkdir()
    helper = '''#!/usr/bin/env python3
import os,sys,pathlib,plistlib,signal
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
    if '-f' in args and os.environ.get('FIXTURE_REGISTER_FAIL'):
        marker=pathlib.Path(os.environ['FIXTURE_REGISTER_FAIL'])
        if not marker.exists(): marker.write_text('failed once');sys.exit(1)
elif name=='ditto':
    if '-c' in args and os.environ.get('FIXTURE_ARCHIVE_SIGNAL'):
        os.kill(os.getppid(),signal.SIGTERM); sys.exit(1)
    if '-c' in args and os.environ.get('FIXTURE_ARCHIVE_FAIL'): sys.exit(1)
    os.execv('/usr/bin/ditto',['ditto']+args)
elif name=='mv':
    if args[0]==str(target) and os.environ.get('FIXTURE_MOVE_FAIL'): sys.exit(1)
    os.execv('/bin/mv',['mv']+args)
elif name=='pluginkit':
    with open(os.environ['FIXTURE_PLUGIN_LOG'],'a') as out: out.write(' '.join(args)+'\\n')
    if '-r' in args and os.environ.get('FIXTURE_PLUGIN_FAIL'): sys.exit(1)
'''
    for name in ['pgrep', 'ps', 'codesign', 'lsregister', 'ditto', 'mv', 'pluginkit']:
        p = stub / name
        p.write_text(helper)
        p.chmod(0o700)

    def case(name):
        project = root / name
        target = project / 'Applications/搞词元.app'
        (project / 'scripts').mkdir(parents=True)
        (project / 'scripts/install.sh').write_text(original.replace(
            'TARGET="/Applications/搞词元.app"', f'TARGET="{target}"').replace(
            'LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
            f'LSREGISTER="{stub / "lsregister"}"'))
        (project / 'scripts/install.sh').chmod(0o700)
        info = {'CFBundleIdentifier': 'com.gaoseries.GaoCiYuan', 'CFBundleShortVersionString': '4.05', 'CFBundleVersion': '6'}
        (project / 'Info.plist').write_bytes(plistlib.dumps(info))
        def bundle(path, version, build):
            (path / 'Contents/MacOS').mkdir(parents=True)
            contents = dict(info, CFBundleShortVersionString=version, CFBundleVersion=build)
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(contents))
            (path / 'Contents/MacOS/GaoCiYuan').write_text('Fixture text only; never executable.\n'+version)
            (path / 'Contents/alias').symlink_to('MacOS/GaoCiYuan')
        bundle(target, '4.04', '5')
        # The complete parent .noindex exists before these .app directories.
        source = project / 'build.noindex/搞词元.app'
        source.parent.mkdir()
        bundle(source, '4.05', '6')
        env = dict(os.environ, PATH=str(stub)+os.pathsep+os.environ['PATH'], FIXTURE_TARGET=str(target), FIXTURE_PLUGIN_LOG=str(project/'plugins.log'))
        def run(arguments=(), **extra):
            result = subprocess.run(['zsh', str(project/'scripts/install.sh'), *arguments], env=dict(env, **extra), text=True, capture_output=True)
            return result
        def version():
            return plistlib.loads((target/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        return project, target, source, run, version

    project, target, source, run, version = case('success')
    result = run()
    check(result.returncode == 0, result.stderr + result.stdout)
    check(version() == '4.05' and not source.exists(), 'install failed or left expanded build app')
    rollback = project / 'rollback.noindex'
    pointer = json.loads((rollback/'latest.json').read_text())
    receipt = rollback / pointer['receipt']
    data = json.loads(receipt.read_text())
    archive = receipt.parent / data['archive']
    check(data['version'] == '4.04' and data['build'] == '5', 'receipt lost original version')
    check(hashlib.sha256(archive.read_bytes()).hexdigest() == data['sha256'], 'archive receipt digest mismatch')
    check((receipt.parent/'application.zip.sha256').is_file(), 'SHA256 sidecar missing')
    check(list(rollback.rglob('*.app')) == [], 'expanded old app remained after archive verification')
    check(list((project/'.install.noindex').iterdir()) == [], 'private expanded staging app remained')
    result = run(('--rollback', str(receipt)))
    check(result.returncode == 0 and version() == '4.04', 'receipt rollback failed: '+result.stderr+result.stdout)
    check(archive.exists(), 'rollback deleted the prior recovery archive')
    check(list(rollback.rglob('*.app')) == [], 'rollback left expanded backup app')
    result = run(('--rollback',))
    check(result.returncode == 0 and version() == '4.05', 'latest pointer rollback failed')

    for name, option in [('registration-failure', 'FIXTURE_REGISTER_FAIL'), ('archive-failure', 'FIXTURE_ARCHIVE_FAIL'), ('signal-during-archive', 'FIXTURE_ARCHIVE_SIGNAL')]:
        project, target, source, run, version = case(name)
        value = str(project/'failed.once') if option == 'FIXTURE_REGISTER_FAIL' else '1'
        result = run(**{option: value})
        check(result.returncode != 0 and version() == '4.04', name+' did not restore the old program')
        check(source.exists(), name+' removed the pending build on failure')
        check(list((project/'.install.noindex').iterdir()) == [], name+' leaked expanded staging app')

    for name, option in [('widget-unregister-failure', 'FIXTURE_PLUGIN_FAIL'), ('old-app-move-failure', 'FIXTURE_MOVE_FAIL')]:
        project, target, source, run, version = case(name)
        extension = target/'Contents/PlugIns/GaoCiYuanWidgets.appex/Contents'
        extension.mkdir(parents=True)
        (extension/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.gaoseries.GaoCiYuan.widgets'}))
        result = run(**{option:'1'})
        log=(project/'plugins.log').read_text().splitlines()
        check(result.returncode != 0 and version() == '4.04', name+' did not preserve old installation')
        check(log[0].startswith('-r ') and log[-1].startswith('-a '), name+' did not restore exact extension registration')

    for name, option in [('main-running', 'FIXTURE_RUNNING'), ('process-query-failure', 'FIXTURE_PS_FAIL')]:
        project, target, source, run, version = case(name)
        result = run(**{option: '1'})
        check(result.returncode != 0 and version() == '4.04', name+' incorrectly permitted replacement')
        check(not (project/'rollback.noindex').exists(), name+' mutated backups before preflight')

    for name, marker in [('wrong-team', 'bad-team'), ('changed-dr', 'bad-dr')]:
        project, target, source, run, version = case(name)
        (source/marker).write_text('fixture')
        result = run()
        check(result.returncode != 0 and version() == '4.04', name+' incorrectly permitted replacement')

    project, target, source, run, version = case('tampered-archive')
    check(run().returncode == 0, 'tamper fixture installation failed')
    rollback = project/'rollback.noindex'
    receipt = rollback/json.loads((rollback/'latest.json').read_text())['receipt']
    archive = receipt.parent/'application.zip'
    archive.write_bytes(archive.read_bytes()+b'altered')
    result = run(('--rollback',str(receipt)))
    check(result.returncode != 0 and version() == '4.05', 'tampered rollback archive changed installed program')
    check(list((project/'.install.noindex').iterdir()) == [], 'tampered archive left staging expansion')

print('Installer regression passed: isolated .noindex fake bundles; install and receipt/latest rollback; ZIP/SHA/manifest/symlink preservation; registration/archive failure restore; exact running PID/query-failure rejection; Team/DR rejection; tamper rejection; owned expansion cleanup. No real app launch, installation, registration or smoke test.')
