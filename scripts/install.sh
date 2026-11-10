#!/bin/zsh
set -euo pipefail
umask 077
ROOT=${0:A:h:h}
TARGET="/Applications/搞词元.app"
BUNDLE_ID=com.gaoseries.GaoCiYuan
TEAM=5G96498KGJ
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ $# -ne 0 ]]; then
    echo '用法：scripts/install.sh（直接安装；不创建备份或回滚副本）' >&2
    exit 1
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
[[ ! -L "$ROOT/.install.noindex" && ! -L "$ROOT/build.noindex" ]] || { echo '暂存容器不能为符号链接' >&2; exit 1; }
mkdir -p "$ROOT/.install.noindex"
STAGE=$(mktemp -d "$ROOT/.install.noindex/install.XXXXXXXX")
cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    rm -rf "$STAGE"
    if [[ "$result" -ne 0 ]]; then
        echo '安装未完成；已停止，未创建备份，也未自动恢复。请检查上述错误。' >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

SOURCE="$ROOT/build.noindex/搞词元.app"
if [[ ! -d "$SOURCE" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
    (cd "$ROOT/dist"; shasum -a 256 -c "GaoCiYuan-$VERSION.zip.sha256")
    ditto -x -k "$ROOT/dist/GaoCiYuan-$VERSION.zip" "$STAGE"
    SOURCE="$STAGE/搞词元.app"
fi
verify_app "$SOURCE"
[[ ! -d "$SOURCE/Contents/PlugIns/GaoCiYuanWidgets.appex" ]] || { echo '安装包包含已移除的小组件' >&2; exit 1; }
for field in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(value "$SOURCE" "$field")" == "$(/usr/libexec/PlistBuddy -c "Print :$field" "$ROOT/Info.plist")" ]] || { echo '安装版本/构建与源码不一致' >&2; exit 1; }
done
if [[ -d "$TARGET" ]]; then
    verify_app "$TARGET"
    [[ "$(requirement "$SOURCE")" == "$(requirement "$TARGET")" ]] || { echo '新旧程序指定要求不一致，未替换原程序' >&2; exit 1; }
fi

# 完整候选先在不索引目录核验；所有前置检查通过后才替换正式入口。
mkdir -p "$STAGE/ready"
ditto "$SOURCE" "$STAGE/ready/搞词元.app"
verify_app "$STAGE/ready/搞词元.app"
assert_stopped
OLD_WIDGET="$TARGET/Contents/PlugIns/GaoCiYuanWidgets.appex"
if [[ -d "$OLD_WIDGET" ]]; then
    [[ "$(value "$OLD_WIDGET" CFBundleIdentifier)" == "$BUNDLE_ID.widgets" ]] || { echo '旧小组件身份不匹配' >&2; exit 1; }
    pluginkit -r "$OLD_WIDGET"
fi
if [[ -d "$TARGET" ]]; then rm -rf "$TARGET"; fi
mv "$STAGE/ready/搞词元.app" "$TARGET"
verify_app "$TARGET"
"$LSREGISTER" -f -R "$TARGET"
assert_stopped
if [[ "$SOURCE" == "$ROOT/build.noindex/搞词元.app" ]]; then rm -rf "$SOURCE"; fi
echo "Installed $TARGET；未启动程序，未创建备份。请继续核验 Spotlight 与 LaunchServices 唯一入口。"
