#!/data/data/com.termux/files/usr/bin/bash
# Termux 清理脚本 —— 在【Termux 侧】运行。默认只预览(dry-run)，加 --apply 才真删。
# 永不触碰: ~/Ubuntu (proot 根) / ~/.config/gpt_claude_ai (密钥) / ~/storage / start.sh
set -u
APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1;;
  *) printf '用法: %s [--apply]\n' "$0" >&2; exit 2;;
esac
[ "$#" -le 1 ] || { printf '用法: %s [--apply]\n' "$0" >&2; exit 2; }
H=/data/data/com.termux/files/home
U=/data/data/com.termux/files/usr
PROTECT="$H/Ubuntu $H/.config/gpt_claude_ai $H/storage $H/start.sh"
total=0; errors=0
sz() { du -skc -- "$@" 2>/dev/null | awk 'END{print $1+0}'; }
act() { # act <说明> <路径...>; 数组保留空格、换行和通配符，绝不再拆路径。
  local d="$1"; shift; [ $# -eq 0 ] && return 0
  local k; k=$(sz "$@"); [ "$k" -eq 0 ] && return 0
  printf '%-34s %6d MB  (%d 项)\n' "$d" $((k/1024)) $#
  total=$((total+k))
  if [ "$APPLY" -eq 1 ] && ! rm -rf -- "$@"; then
    printf '清理失败: %s\n' "$d" >&2
    errors=1
  fi
}
echo "== Termux 清理 $( [ $APPLY -eq 1 ] && echo '[执行]' || echo '[预览, 加 --apply 执行]' ) =="
echo "保护: $PROTECT"; echo

# find 结果必须 NUL 分隔；$(find/ls ...) 会把带空格等字符的文件名拆成其他删除目标。
# 1. apt/pkg 缓存
shopt -s nullglob
candidates=("$U"/var/cache/apt/archives/*.deb)
act "apt 包缓存 (*.deb)" "${candidates[@]}"
if [ "$APPLY" -eq 1 ]; then apt-get clean >/dev/null 2>&1 || errors=1; fi
# 2. 临时目录 (跳过 proot-*/codex-* 运行时文件、battery.json 与 pulse/x11 socket; 年龄不能证明会话已退出)
mapfile -d '' -t candidates < <(find "$U/tmp" -mindepth 1 -maxdepth 1 ! -name 'proot-*' ! -name 'codex-*' ! -name battery.json ! -name 'pulse-*' ! -name '.X11-unix' ! -name '.X*' -mtime +1 -print0 2>/dev/null)
act "usr/tmp 临时文件" "${candidates[@]}"
# 3. 用户缓存 (pip 已含在 ~/.cache 内，不重复统计和清理)
candidates=("$H"/.cache/*)
act "~/.cache" "${candidates[@]}"
act "npm 缓存" "$H/.npm/_cacache"
# 4. 备份/临时脚本残留 (仅 home 顶层, 按名字匹配)
mapfile -d '' -t candidates < <(find "$H" -maxdepth 1 -type f \( -name '*.bak*' -o -name '*~' -o -name '*.tmp' -o -name '*.orig' \) -print0 2>/dev/null)
act "home 顶层 *.bak/*~/*.tmp" "${candidates[@]}"
# 5. 日志
mapfile -d '' -t candidates < <(find "$H" -maxdepth 2 -type f -name '*.log' -mtime +7 -not -path "$H/Ubuntu/*" -print0 2>/dev/null)
act "旧日志 (*.log >7天)" "${candidates[@]}"
# 6. 崩溃转储
mapfile -d '' -t candidates < <(find "$H" -maxdepth 2 -type f -name 'core*' -size +1M -not -path "$H/Ubuntu/*" -print0 2>/dev/null)
act "core dump" "${candidates[@]}"
# 7. 孤儿依赖
if [ "$APPLY" -eq 1 ]; then
  if apt-get -y autoremove >/dev/null 2>&1; then echo "apt autoremove 已执行"; else errors=1; fi
else
  echo "apt autoremove: 待执行 ($(apt-get -s autoremove 2>/dev/null | grep -c '^Remv') 个包)"
fi

echo; printf '合计可释放 ≈ %d MB\n' $((total/1024))
echo "磁盘: $(df -h "$H" | awk 'NR==2{print $4" 可用 / "$2}')"
if [ "$APPLY" -eq 0 ]; then echo "(预览模式, 未删除任何文件)"; fi
if [ "$errors" -ne 0 ]; then echo '部分清理失败，请查看上方输出。' >&2; fi
exit "$errors"
