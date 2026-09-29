# /etc/profile.d/00-clean-tmp.sh —— 登录时清 /tmp 死残留(2026-09-22)
# 目的: tigervnc.*/proot-*/.X*-lock 等旧文件堆积会让 VNC 反复连不上。
# ★安全原则: 只删【进程已死】的残留, 正在用的 socket/lock 一律跳过。
#   本机 ps 不可用 → 用 /proc 判活。仅交互 shell 跑一次(非登录 shell 不跑)。
# 关闭: 删本文件, 或 export CLEAN_TMP=0
case $- in *i*) ;; *) return 2>/dev/null || true;; esac   # 只在交互 shell
[ "${CLEAN_TMP:-1}" = 1 ] || return 2>/dev/null || true

_ct_pid_alive() { [ -d "/proc/$1" ]; }
# 目录最近 N 秒内动过?(mtime 宽限; stat 失败按"近期"处理=保守不删)
_ct_recent() { local m; m=$(stat -c '%Y' "$1" 2>/dev/null) || return 0; [ $(( $(date +%s) - m )) -lt "${CLEAN_TMP_PROOT_GRACE:-3600}" ]; }

_ct_clean() {
  local f pid
  # ① proot-<pid>-xxx: 仅当【pid 已死】且【超过宽限期没动过】才删。
  #   双保险: pid 判活为主(容器内可见宿主 proot pid, 2026-09-25 实测坐实:活会话 dir-pid 均可见);
  #   mtime 宽限兜底——万一某 proot 配置下宿主 pid 不可见, 也不会误删【正在用/刚退出】的会话工作目录。
  #   (proot 退出那条 "can't chmod ... No such file" 是 proot 自身 --kill-on-exit 清理竞态, 与本段无关, 改不掉。)
  for f in /tmp/proot-*; do
    [ -e "$f" ] || continue
    pid=$(printf '%s' "$f" | sed -nE 's#.*/proot-([0-9]+)-.*#\1#p')
    if [ -n "$pid" ] && _ct_pid_alive "$pid"; then continue; fi   # pid 活 → 留
    _ct_recent "$f" && continue                                   # 近期动过 → 留(宽限)
    rm -rf "$f" 2>/dev/null                                        # pid 死 且 超宽限 → 删
  done
  # ② tigervnc.* 密码目录: 没有任何 Xtigervnc 在跑时才全清(有活 VNC 就整个跳过, 免误删在用的)
  if ! { for d in /proc/[0-9]*; do tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q Xtigervnc && exit 0; done; false; }; then
    rm -rf /tmp/tigervnc.* 2>/dev/null
  fi
  # ③ .X<n>-lock 与 /tmp/.X11-unix/X<n>: 对应 display 没在跑才删(避免删掉正连着的)
  # ★2026-09-22 重大修复: 【绝不碰 X2】—— X2 是 Termux:X11(宿主侧 com.termux.x11, 跨 App),
  #   它的进程在【另一个 UID 的安卓 App】里, proot 内扫 /proc 根本看不到(SELinux/hidepid),
  #   而且进程名是小写 termux-x11, 下面那条大写 X 开头的正则也永远匹配不上 →
  #   结果每次交互登录都把好端端的 X2 socket 当"死残留"删掉 → startx11 报"没有 X2"。
  #   这就是"进容器反而没 X2 / 要反复点图标"的真凶。X2 存活与否由宿主侧管, 这里一律跳过。
  local n sock lock
  for lock in /tmp/.X*-lock; do
    [ -e "$lock" ] || continue
    n=$(printf '%s' "$lock" | sed -nE 's#.*/\.X([0-9]+)-lock#\1#p')
    [ -n "$n" ] || continue
    [ "$n" = "${X11_KEEP_DISPLAY:-2}" ] && continue   # ★跳过 Termux:X11 的 :2, 无法用/proc判活, 绝不删
    # 该 display 有 X socket 且有进程占用? 判据: 扫 /proc 找占用该 :n 的 X 服务端(容器内可见的)
    if ! { for d in /proc/[0-9]*; do tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -qiE "X(tigervnc|org|wayland)?.*:$n\b" && exit 0; done; false; }; then
      rm -f "$lock" "/tmp/.X11-unix/X$n" 2>/dev/null
    fi
  done
  # ④ 明确的孤儿: cc-daemon-* / 老 dbus-* / ssh-* 里无对应进程的(保守: 只清 7 天前的)
  find /tmp -maxdepth 1 \( -name 'cc-daemon-*' -o -name 'ssh-*' -o -name 'dbus-*' \) -mtime +0 -exec rm -rf {} + 2>/dev/null
}
_ct_clean 2>/dev/null
unset -f _ct_pid_alive _ct_recent _ct_clean 2>/dev/null
