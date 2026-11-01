#!/bin/zsh
set -euo pipefail
umask 077
ROOT=${0:A:h:h}
TARGET="/Applications/搞词元.app"
BUNDLE_ID=com.gaoseries.GaoCiYuan
TEAM=5G96498KGJ
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ROLLBACK="$ROOT/rollback.noindex"
MODE=install
RECEIPT=""
if [[ "${1:-}" == --rollback ]]; then
    MODE=rollback
    RECEIPT=${2:-"$ROLLBACK/latest.json"}
elif [[ $# -gt 0 ]]; then
    echo '用法：scripts/install.sh [--rollback [回滚收据路径]]' >&2; exit 1
fi

main_running() {
    local snapshot candidates code pattern
    pattern=$(python3 -c 'import re,sys; print("^"+re.escape(sys.argv[1])+"($| )")' "$TARGET/Contents/MacOS/GaoCiYuan") || return 2
    if candidates=$(pgrep -f "$pattern"); then
        [[ -n "$candidates" ]] || return 2
    else
        code=$?
        [[ "$code" == 1 ]] && return 1
        return 2
    fi
    snapshot=$(ps -ww -p "${(j:,:)${(f)candidates}}" -o pid=,comm=) || return 2
    [[ -n "$snapshot" ]] || return 2
    print -r -- "$snapshot" | python3 -c 'import sys
expected=sys.argv[1]
matches=[p[0] for line in sys.stdin if len(p:=line.strip().split(None,1))==2 and p[1]==expected]
if matches: print("主程序仍在运行（PID "+", ".join(matches)+"），请先退出；未强制关闭。",file=sys.stderr)
sys.exit(0 if matches else 1)' "$TARGET/Contents/MacOS/GaoCiYuan"
}
assert_stopped() {
    local code
    if main_running; then return 1; else code=$?; fi
    [[ "$code" == 1 ]] || { echo '无法核验主程序进程，未执行替换' >&2; return 1; }
}
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
requirement() { codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p'; }
verify_app() {
    [[ ! -L "$1" && -d "$1" ]] || { echo '程序目录缺失或为符号链接' >&2; return 1; }
    [[ "$(value "$1" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || { echo '程序 Bundle ID 不匹配' >&2; return 1; }
    codesign --verify --deep --strict "$1" || return 1
    [[ "$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM" ]] || { echo '程序签名团队不匹配' >&2; return 1; }
    [[ -n "$(requirement "$1")" ]] || { echo '程序缺少指定要求' >&2; return 1; }
}
assert_stopped
# Legacy backup pointers need a separate verified migration, never a rename.
if [[ -d "$ROOT/rollback" ]] && [[ -n "$(find "$ROOT/rollback" -type d -name '*.app' -print -quit)" ]]; then
    echo '普通 rollback/ 中仍有旧程序；请先核对备份收据与恢复路径并迁移，未执行安装。' >&2; exit 1
fi
mkdir -p "$ROOT/.install.noindex" "$ROLLBACK"
[[ ! -L "$ROOT/.install.noindex" && ! -L "$ROLLBACK" && ! -L "$ROOT/build.noindex" ]] || { echo '暂存容器不能为符号链接' >&2; exit 1; }
STAGE=$(mktemp -d "$ROOT/.install.noindex/install.XXXXXXXX")
BACKUP="$ROLLBACK/$(date +%Y%m%d-%H%M%S)-$(uuidgen)"
SAFETY="$BACKUP/搞词元.app"
MOVED=false
NEW_INSTALLED=false
COMMITTED=false
OLD_WIDGET_REMOVED=false
OLD_WIDGET="$TARGET/Contents/PlugIns/GaoCiYuanWidgets.appex"
SOURCE=""
restore_widget() { if [[ "$OLD_WIDGET_REMOVED" == true && -d "$OLD_WIDGET" ]]; then pluginkit -a "$OLD_WIDGET"; fi }
cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ "$COMMITTED" != true && "$MOVED" == true ]]; then
        if ! assert_stopped; then
            echo "恢复暂缓：主程序正在运行；旧程序安全保留于 $BACKUP" >&2
            result=1
        elif [[ -d "$SAFETY" ]]; then
            "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
            rm -rf "$TARGET"
            if mv "$SAFETY" "$TARGET" && verify_app "$TARGET" && "$LSREGISTER" -f -R "$TARGET" && restore_widget; then
                echo '安装未完成，已恢复原程序。' >&2
            else
                echo "恢复未完成，请保留并检查 $BACKUP" >&2; result=1
            fi
        else
            restore_widget || result=1
        fi
    elif [[ "$COMMITTED" != true && "$NEW_INSTALLED" == true ]]; then
        if assert_stopped; then
            "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
            rm -rf "$TARGET"
        else result=1; fi
    elif [[ "$COMMITTED" != true ]]; then
        restore_widget || result=1
    fi
    if [[ "$COMMITTED" == true && -d "$SAFETY" ]]; then rm -rf "$SAFETY"; fi
    rm -rf "$STAGE"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [[ "$MODE" == rollback ]]; then
    ARCHIVE=$(python3 - "$ROLLBACK" "$RECEIPT" "$TARGET" "$BUNDLE_ID" "$TEAM" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]).resolve(); receipt=pathlib.Path(sys.argv[2]).resolve()
def inside(p):
    if not p.is_relative_to(root): raise SystemExit('回滚路径不在 rollback.noindex 内')
inside(receipt)
data=json.loads(receipt.read_text())
if 'receipt' in data:
    receipt=(receipt.parent/data['receipt']).resolve(); inside(receipt)
    data=json.loads(receipt.read_text())
if (data['target'],data['bundleID'],data['team'])!=tuple(sys.argv[3:]): raise SystemExit('回滚收据身份不匹配')
archive=(receipt.parent/data['archive']).resolve(); inside(archive)
with archive.open('rb') as f: sha=hashlib.file_digest(f,'sha256').hexdigest()
if sha!=data['sha256']: raise SystemExit('回滚归档 SHA256 不匹配')
print(archive)
PY
)
    ditto -x -k "$ARCHIVE" "$STAGE"
    SOURCE="$STAGE/搞词元.app"
else
    SOURCE="$ROOT/build.noindex/搞词元.app"
    if [[ ! -d "$SOURCE" ]]; then
        VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
        (cd "$ROOT/dist"; shasum -a 256 -c "GaoCiYuan-$VERSION.zip.sha256")
        ditto -x -k "$ROOT/dist/GaoCiYuan-$VERSION.zip" "$STAGE"
        SOURCE="$STAGE/搞词元.app"
    fi
fi
verify_app "$SOURCE"
[[ ! -d "$SOURCE/Contents/PlugIns/GaoCiYuanWidgets.appex" ]] || { echo '安装包包含已移除的小组件' >&2; exit 1; }
if [[ "$MODE" == install ]]; then
    for field in CFBundleShortVersionString CFBundleVersion; do
        [[ "$(value "$SOURCE" "$field")" == "$(/usr/libexec/PlistBuddy -c "Print :$field" "$ROOT/Info.plist")" ]] || { echo '安装版本/构建与源码不一致' >&2; exit 1; }
    done
fi
if [[ -d "$TARGET" ]]; then
    verify_app "$TARGET"
    [[ "$(requirement "$SOURCE")" == "$(requirement "$TARGET")" ]] || { echo '新旧程序指定要求不一致，未替换原程序' >&2; exit 1; }
fi
# Prepare the entire replacement in noindex before moving the formal app.
mkdir -p "$STAGE/ready"
ditto "$SOURCE" "$STAGE/ready/搞词元.app"
verify_app "$STAGE/ready/搞词元.app"
assert_stopped
if [[ -d "$OLD_WIDGET" ]]; then
    [[ "$(value "$OLD_WIDGET" CFBundleIdentifier)" == "$BUNDLE_ID.widgets" ]] || { echo '旧小组件身份不匹配' >&2; exit 1; }
    OLD_WIDGET_REMOVED=true
    pluginkit -r "$OLD_WIDGET"
fi
if [[ -d "$TARGET" ]]; then
    mkdir -p "$BACKUP"
    MOVED=true
    mv "$TARGET" "$SAFETY"
fi
NEW_INSTALLED=true
mv "$STAGE/ready/搞词元.app" "$TARGET"
verify_app "$TARGET"
"$LSREGISTER" -f -R "$TARGET"
assert_stopped
if [[ "$MOVED" == true ]]; then
    ditto -c -k --keepParent "$SAFETY" "$BACKUP/application.zip"
    (cd "$BACKUP"; shasum -a 256 application.zip > application.zip.sha256; shasum -a 256 -c application.zip.sha256)
    mkdir -p "$STAGE/verify"
    ditto -x -k "$BACKUP/application.zip" "$STAGE/verify"
    verify_app "$STAGE/verify/搞词元.app"
    [[ "$(requirement "$SAFETY")" == "$(requirement "$STAGE/verify/搞词元.app")" ]] || { echo '回滚归档指定要求不匹配' >&2; exit 1; }
    python3 - "$SAFETY" "$STAGE/verify/搞词元.app" "$BACKUP" "$TARGET" "$TEAM" "$(requirement "$SAFETY")" <<'PY'
import datetime,hashlib,json,os,pathlib,plistlib,stat,sys
original,restored,backup=map(pathlib.Path,sys.argv[1:4])
def manifest(root):
    items=[]
    for p in sorted(root.rglob('*')):
        mode=p.lstat().st_mode; rel=p.relative_to(root).as_posix()
        if p.is_symlink(): items.append([rel,'link',os.readlink(p)])
        elif p.is_file():
            with p.open('rb') as f: sha=hashlib.file_digest(f,'sha256').hexdigest()
            items.append([rel,'file',stat.S_IMODE(mode),sha])
        elif p.is_dir(): items.append([rel,'directory'])
        else: raise SystemExit('回滚程序包含无法核验的文件')
    return items
left=manifest(original)
if left!=manifest(restored): raise SystemExit('回滚归档内容与原程序不一致，保留原程序')
with (original/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
with (backup/'application.zip').open('rb') as f: sha=hashlib.file_digest(f,'sha256').hexdigest()
receipt={'format':1,'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'target':sys.argv[4],
    'bundleID':info['CFBundleIdentifier'],'team':sys.argv[5],'version':info['CFBundleShortVersionString'],
    'build':info['CFBundleVersion'],'designatedRequirement':sys.argv[6],'archive':'application.zip','sha256':sha,
    'manifestSHA256':hashlib.sha256(json.dumps(left,ensure_ascii=False,separators=(',',':')).encode()).hexdigest(),
    'restoreCommand':'scripts/install.sh --rollback '+str(backup/'receipt.json')}
(backup/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
pointer=backup.parent/'latest.json'; temporary=backup.parent/'.latest.json.tmp'
temporary.write_text(json.dumps({'receipt':str((backup/'receipt.json').relative_to(backup.parent))})+'\n')
os.replace(temporary,pointer)
PY
    "$LSREGISTER" -u "$SAFETY" >/dev/null 2>&1 || true
    echo "回滚收据：$BACKUP/receipt.json"
fi
assert_stopped
COMMITTED=true
if [[ "$MODE" == install && "$SOURCE" == "$ROOT/build.noindex/搞词元.app" ]]; then rm -rf "$SOURCE"; fi
echo "Installed $TARGET；未启动程序。请继续核验 Spotlight 与 LaunchServices 唯一入口。"
