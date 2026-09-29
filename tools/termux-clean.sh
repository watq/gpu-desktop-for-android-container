#!/data/data/com.termux/files/usr/bin/bash
# Termux 清理脚本 —— 在【Termux 侧】运行。默认只预览(dry-run)，加 --apply 才真删。
# 永不触碰: ~/Ubuntu (proot 根) / ~/.config/gpt_claude_ai (密钥) / ~/storage / start.sh
set -u
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
H=/data/data/com.termux/files/home
U=/data/data/com.termux/files/usr
PROTECT="$H/Ubuntu $H/.config/gpt_claude_ai $H/storage $H/start.sh"
total=0
sz() { du -sk "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
act() { # act <说明> <路径...>
  local d="$1"; shift; [ $# -eq 0 ] && return
  local k; k=$(sz "$@"); [ "$k" -eq 0 ] && return
  printf '%-34s %6d MB  (%d 项)\n' "$d" $((k/1024)) $#
  total=$((total+k))
  [ $APPLY -eq 1 ] && rm -rf -- "$@"
}
echo "== Termux 清理 $( [ $APPLY -eq 1 ] && echo '[执行]' || echo '[预览, 加 --apply 执行]' ) =="
echo "保护: $PROTECT"; echo

# 1. apt/pkg 缓存
act "apt 包缓存 (*.deb)"     $(ls $U/var/cache/apt/archives/*.deb 2>/dev/null)
[ $APPLY -eq 1 ] && apt-get clean >/dev/null 2>&1
# 2. 临时目录 (跳过 battery.json 与 pulse/x11 socket)
act "usr/tmp 临时文件"       $(find $U/tmp -mindepth 1 -maxdepth 1 ! -name battery.json ! -name 'pulse-*' ! -name '.X11-unix' ! -name '.X*' -mtime +1 2>/dev/null)
# 3. 用户缓存
act "~/.cache"               $(ls -d $H/.cache/* 2>/dev/null)
act "pip 缓存"               $(ls -d $H/.cache/pip 2>/dev/null)
act "npm 缓存"               $(ls -d $H/.npm/_cacache 2>/dev/null)
# 4. 备份/临时脚本残留 (仅 home 顶层, 按名字匹配)
act "home 顶层 *.bak/*~/*.tmp" $(find $H -maxdepth 1 -type f \( -name '*.bak*' -o -name '*~' -o -name '*.tmp' -o -name '*.orig' \) 2>/dev/null)
# 5. 日志
act "旧日志 (*.log >7天)"    $(find $H -maxdepth 2 -type f -name '*.log' -mtime +7 -not -path "$H/Ubuntu/*" 2>/dev/null)
# 6. 崩溃转储
act "core dump"              $(find $H -maxdepth 2 -type f -name 'core*' -size +1M -not -path "$H/Ubuntu/*" 2>/dev/null)
# 7. 孤儿依赖
if [ $APPLY -eq 1 ]; then apt-get -y autoremove >/dev/null 2>&1 && echo "apt autoremove 已执行"; else echo "apt autoremove: 待执行 ($(apt-get -s autoremove 2>/dev/null | grep -c '^Remv') 个包)"; fi

echo; printf '合计可释放 ≈ %d MB\n' $((total/1024))
echo "磁盘: $(df -h $H | awk 'NR==2{print $4" 可用 / "$2}')"
[ $APPLY -eq 0 ] && echo "(预览模式, 未删除任何文件)"
