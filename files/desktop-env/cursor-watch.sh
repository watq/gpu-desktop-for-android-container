#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# desktop-env/cursor-watch.sh —— 「xfconf 光标设置变更 → 自动同步到 X 层」看守
#                                (2026-09-26, 每个 display 一个实例)
#
# 为什么需要它(全部有 2026-09-26 实测依据, 见 工具箱/wip/cursor.20260926/ledger.txt):
#   ① cursor-sync.sh 原先【只在会话启动时跑一次】(xstartup sleep 8 一次 / startx11 一次)。
#      用户在「设置→鼠标和触摸板→主题→光标大小」拖完滑块之后, 没有任何人再同步一次
#      → 根窗光标(桌面空白处/应用启动瞬间那个)保持旧尺寸, 观感就是"改了没反应"。
#   ② :1 与 :2 各有一条会话 D-Bus, 各自会被激活出一个 xfconfd, 两个 xfconfd
#      【内存态互相不可见, 却往同一份 ~/.config/xfce4/xfconf/xfce-perchannel-xml/
#      xsettings.xml 刷盘, 后刷者赢】。2026-09-26 实测: 在 A 总线设 96 → B 总线仍读 48
#      → 之后 A 的 xfconfd 把 96 刷盘, 把 B(=GUI)刚设的值盖掉。观感就是"改完又变回去"。
#      本脚本收到变更后会把值【横向推给另一个 display 的总线】, 让两个 xfconfd 的内存态
#      一致 —— 谁先刷盘写的都是同一个值, 覆盖问题消失, 同时两端观感一致。
#
# ★设计原则(用户明确要求, 与 cursor-sync.sh 一致):
#   【不架空原生 GUI】—— xfconf 永远是唯一真源。本脚本只"监听 xfconf → 往 X 层推",
#   绝不设 XCURSOR_THEME / XCURSOR_SIZE 环境变量去覆盖 GUI。
#
# 用法:
#   cursor-watch.sh start [display…]   为指定 display 起看守(缺省=所有有 xfsettingsd 的)
#   cursor-watch.sh status             看各 display 的看守状态
#   cursor-watch.sh stop  [display…]   停掉看守(按 pid 文件, 并校验 /proc/<pid> 确是本脚本)
#   cursor-watch.sh __run <display>    内部: 真正的监听循环(别手动调)
#
# 幂等: 每个 display 一个实例, pid 文件在 ~/.cache/desktop-env/(不放 /tmp, 免被清)。
# ══════════════════════════════════════════════════════════════════════════════
set -u

SELF=/root/.config/desktop-env/cursor-watch.sh
SYNC=/root/.config/desktop-env/cursor-sync.sh
CACHE=/root/.cache/desktop-env
# 横向同步的仲裁文件 + 全局锁。
# ★为什么需要仲裁(2026-09-26 实测踩过): 最初写成"每个看守把【自己这边】的值推给对面",
#   两边值一旦不一致就变成【乒乓死循环】—— 实测 :1 与 :2 的日志各刷了 198/197 条
#   "同步大小", 光标 serial 从 132 一路飙到 2378。
#   现在的规则: 谁先拿到全局锁, 就把自己的值写进 STATE 并推给对面; 对面被推醒后发现
#   "我的值 == STATE" → 判定这是别人推来的, 只同步 X 层, 【不再回推】→ 环被打断。
STATE="$CACHE/cursor-state"
GLOCK="$CACHE/cursor-watch.lock"
mkdir -p "$CACHE" 2>/dev/null

tag() { printf '%s' "${1#:}" | tr -c 'A-Za-z0-9' '_'; }
pidf() { printf '%s/cursor-watch.d%s.pid' "$CACHE" "$(tag "$1")"; }
logf() { printf '%s/cursor-watch.d%s.log' "$CACHE" "$(tag "$1")"; }

# ── 取某个 display 的会话 D-Bus 地址 ────────────────────────────────────────
# 从该 display 上跑着的 xfsettingsd 的 /proc/<pid>/environ 里借。
# 【不能】靠 dbus 的 X11 autolaunch: 2026-09-26 实测 :1 上 autolaunch selection 被
# im.sh 先起的 ibus 那条总线(/tmp/dbus-zzBrUmdeLN)抢走了, 而 XFCE 会话在另一条
# (/tmp/dbus-QbcCfoK5nf) —— 直接跑 xfconf-query 会连到错误总线并多起一个 xfconfd。
bus_of_display() {
  local d="$1" p e
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    [ "$(basename "$(readlink "$p/exe" 2>/dev/null)" 2>/dev/null)" = xfsettingsd ] || continue
    e=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null )
    [ "$(printf '%s' "$e" | sed -n 's/^DISPLAY=//p' | head -1)" = "$d" ] || continue
    printf '%s' "$(printf '%s' "$e" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)"
    return 0
  done
  return 1
}

# 打印所有"有 xfsettingsd 在跑"的 display(按 /proc/<pid>/exe 真实程序名匹配, 不按 cmdline 文本)
live_displays() {
  local p d
  for p in /proc/[0-9]*; do
    [ "$(basename "$(readlink "$p/exe" 2>/dev/null)" 2>/dev/null)" = xfsettingsd ] || continue
    d=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
    case "$d" in :[0-9]*) printf '%s\n' "${d%%.*}" ;; esac
  done | sort -u
}

# 某 display 上是否还有 xfce4-session(判断会话是否已经结束)
session_alive() {
  local p d
  for p in /proc/[0-9]*; do
    [ "$(basename "$(readlink "$p/exe" 2>/dev/null)" 2>/dev/null)" = xfce4-session ] || continue
    d=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
    [ "${d%%.*}" = "$1" ] && return 0
  done
  return 1
}

# pid 文件里的进程是否还是"本脚本的看守实例"
# ★安全: 校验 /proc/<pid>/exe 真的是 bash 且 cmdline 里含本脚本路径 + __run, 并跳过自己。
#   本项目禁 pkill -f / killall(误杀过自己的 shell 两次), 只认 pid 文件 + /proc 双校验。
watcher_alive() {
  local pf p c
  pf="$(pidf "$1")"
  [ -r "$pf" ] || return 1
  p=$(head -1 "$pf" 2>/dev/null | tr -cd '0-9')
  [ -n "$p" ] || return 1
  [ "$p" = "$$" ] && return 1
  [ -d "/proc/$p" ] || return 1
  case "$(basename "$(readlink "/proc/$p/exe" 2>/dev/null)" 2>/dev/null)" in bash|sh|dash) ;; *) return 1 ;; esac
  c=$( { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null )
  case "$c" in *cursor-watch.sh*__run*) printf '%s' "$p"; return 0 ;; esac
  return 1
}

# ── 收到变更后要做的事 ─────────────────────────────────────────────────────
do_sync() {
  local d="$1"
  [ -x "$SYNC" ] && "$SYNC" "$d"
}

# 读某 display 当前的 "主题<TAB>大小"
read_cur() {
  local d="$1" b t s
  b="$(bus_of_display "$d")" || return 1
  [ -n "$b" ] || return 1
  t=$(env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 \
        xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null)
  s=$(env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 \
        xfconf-query -c xsettings -p /Gtk/CursorThemeSize 2>/dev/null)
  [ -n "$t" ] && [ -n "$s" ] || return 1
  printf '%s\t%s' "$t" "$s"
}

# 把给定的主题/大小推给除 $1 以外的所有活 display(值不同才写)
propagate() {
  local src="$1" theme="$2" size="$3" d b ct cs
  for d in $(live_displays); do
    [ "$d" = "$src" ] && continue
    b="$(bus_of_display "$d")" || continue
    [ -n "$b" ] || continue
    ct=$(env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 \
           xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null)
    cs=$(env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 \
           xfconf-query -c xsettings -p /Gtk/CursorThemeSize 2>/dev/null)
    if [ "$ct" != "$theme" ]; then
      env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 \
        xfconf-query -c xsettings -p /Gtk/CursorThemeName -s "$theme" >/dev/null 2>&1
      echo "[cursor-watch] $src → $d 推送主题=$theme"
    fi
    if [ "$cs" != "$size" ]; then
      env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 \
        xfconf-query -c xsettings -p /Gtk/CursorThemeSize -s "$size" >/dev/null 2>&1
      echo "[cursor-watch] $src → $d 推送大小=$size"
    fi
  done
}

# 一次变更的完整处理(全局锁内串行, 靠 STATE 仲裁, 绝不回推 → 不会乒乓)
on_change() {
  local d="$1"
  (
    flock -w 30 7 || { echo "[cursor-watch] $d 拿不到全局锁, 本次只同步 X 层"; do_sync "$d"; exit 0; }
    local cur last theme size
    cur="$(read_cur "$d")" || { do_sync "$d"; exit 0; }
    last=$( { head -1 "$STATE"; } 2>/dev/null )
    do_sync "$d"                       # X 层(xrdb + 根窗光标)永远要同步
    if [ "$cur" = "$last" ]; then
      echo "[cursor-watch] $d 的值与仲裁记录一致(= 是别处推过来的), 不回推"
      exit 0
    fi
    printf '%s\n' "$cur" > "$STATE"
    theme=${cur%%$'\t'*}; size=${cur##*$'\t'}
    propagate "$d" "$theme" "$size"
  ) 7>"$GLOCK"
}

# ── 监听循环 ───────────────────────────────────────────────────────────────
run_loop() {
  local d="$1" bus miss=0 line
  echo "[cursor-watch] $(date '+%F %T') 看守启动 display=$d pid=$$"
  echo $$ > "$(pidf "$d")"
  # 起来先同步一次(会话启动那一次可能比 xfsettingsd 早, 值不一定对)
  do_sync "$d"
  # 仲裁记录缺失时用本 display 的现值打底(只写记录, 不推给别人, 免得刚起来就互推)
  if [ ! -s "$STATE" ]; then
    ( flock -w 15 7 || exit 0; [ -s "$STATE" ] || read_cur "$d" > "$STATE" ) 7>"$GLOCK"
  fi
  while :; do
    if [ ! -e "/tmp/.X11-unix/X${d#:}" ] || ! session_alive "$d"; then
      # :2 的 socket 会被 Android 冻结 Activity 时短暂消失 → 连续 6 次(约 60s)才认定会话结束
      miss=$((miss + 1))
      if [ "$miss" -ge 6 ]; then
        echo "[cursor-watch] $(date '+%F %T') $d 会话已结束, 看守退出"
        echo "exited $(date '+%F %T')" > "$(pidf "$d")"
        exit 0
      fi
      sleep 10; continue
    fi
    miss=0
    bus="$(bus_of_display "$d")" || bus=""
    if [ -z "$bus" ]; then sleep 5; continue; fi
    # xfconf-query -m 一直挂着监听该频道; xfconfd 退出/总线断开时它会返回 → 外层 while 重连。
    # ★这条连接还有个副作用红利: 它把【会话总线上的那个 xfconfd】钉住不退,
    #   于是 GUI 与本看守始终对着同一个 xfconfd 说话。
    env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$bus" xfconf-query -c xsettings -m 2>/dev/null |
    while IFS= read -r line; do
      case "$line" in *"/Gtk/CursorTheme"*) ;; *) continue ;; esac
      # 去抖/合并: 拖滑块会连发几十条, 把这一串剩下的全读掉再只同步一次
      while IFS= read -r -t 0.35 line; do :; done
      echo "[cursor-watch] $(date '+%F %T') $d 侦测到光标设置变更"
      on_change "$d"
    done
    sleep 3
  done
}

# ── 命令行 ─────────────────────────────────────────────────────────────────
cmd="${1:-status}"; shift 2>/dev/null || true
case "$cmd" in
  __run)
    run_loop "${1:?需要 display}"
    ;;
  start)
    set -- ${@:-$(live_displays)}
    [ $# -gt 0 ] || { echo "[cursor-watch] 没有任何 display 上有 xfsettingsd, 不起看守"; exit 0; }
    for d in "$@"; do
      if p=$(watcher_alive "$d"); then
        echo "[cursor-watch] $d 已有看守 (pid $p), 跳过"
        continue
      fi
      # 自成会话 + 断开所有继承的 fd(尤其别继承调用方的 flock 锁 fd, 那会把锁永久占住)
      setsid nohup "$SELF" __run "$d" >>"$(logf "$d")" 2>&1 </dev/null &
      sleep 1
      if p=$(watcher_alive "$d"); then
        echo "[cursor-watch] $d 看守已启动 (pid $p), 日志 $(logf "$d")"
      else
        echo "[cursor-watch] $d 看守启动失败, 看 $(logf "$d")"
      fi
    done
    ;;
  stop)
    set -- ${@:-$(live_displays)}
    for d in "$@"; do
      if p=$(watcher_alive "$d"); then
        # ★必须杀【整个进程组】: 看守是 `xfconf-query -m | while read` 的管道,
        #   只杀 run_loop 那个 bash 的话, 管道里的 xfconf-query 与 while-read 子 shell
        #   会被 reparent 到 init 继续跑【旧版代码】—— 2026-09-26 实测就是这样残留了
        #   两组 10:35 的老看守, 和新看守一起对着推, 造成"改了又被推回去"。
        #   start 用了 setsid, 所以 pgid == pid, `kill -- -pid` 正好覆盖整条管道。
        kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null
        sleep 1
        echo "[cursor-watch] $d 看守进程组 (pgid $p) 已停"
        echo "stopped $(date '+%F %T')" > "$(pidf "$d")"
      else
        echo "[cursor-watch] $d 没有在跑的看守"
      fi
    done
    ;;
  status)
    for d in $(live_displays); do
      if p=$(watcher_alive "$d"); then echo "  $d: 看守在跑 pid=$p"; else echo "  $d: 无看守"; fi
      b="$(bus_of_display "$d")" || b="(取不到)"
      echo "      总线 $b"
      echo -n "      xfconf: "
      if [ "$b" != "(取不到)" ]; then
        printf '主题=%s 大小=%s\n' \
          "$(env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null)" \
          "$(env "DISPLAY=$d" "DBUS_SESSION_BUS_ADDRESS=$b" timeout 15 xfconf-query -c xsettings -p /Gtk/CursorThemeSize 2>/dev/null)"
      else echo "读不到"; fi
      echo -n "      xrdb:   "; env "DISPLAY=$d" timeout 10 xrdb -query 2>/dev/null | grep -i '^Xcursor' | tr '\n' ' '; echo
    done
    ;;
  *) sed -n '28,36p' "$SELF"; exit 1 ;;
esac
exit 0
