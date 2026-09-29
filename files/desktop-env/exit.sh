# desktop-env/exit.sh —— 退出清理 (避免 exit 卡住; 来自历史 .bashrc)
# 只在交互 shell 生效, 且不影响 claude wrapper 的子进程
kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -9 "$pid" 2>/dev/null
}
exit() {
  echo "正在清理桌面进程."
  [ -f /tmp/xfce.pid ] && { kill_tree "$(cat /tmp/xfce.pid)"; rm -f /tmp/xfce.pid; }
  pkill -9 -x Xtigervnc 2>/dev/null
  kill -9 $(pgrep -f "termux.x11") 2>/dev/null
  builtin exit "$@"
}
