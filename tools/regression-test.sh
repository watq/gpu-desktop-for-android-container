#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# regression-test.sh —— 应用全面回归测试 (2026-09-24)
#
# 回答四个问题, 全部在【:1(VNC) 和 :2(Termux:X11) 两套显示】上分别验:
#   ① 能不能打开      —— 启动后是否存活 + 是否真有窗口(不是只有进程)
#   ② 有没有走 GPU    —— 进程是否真的打开了 /dev/kgsl-3d0 (fd 级证据, 不看日志)
#   ③ 汉化到不到位    —— .desktop 有无 Name[zh_CN] + 有无 zh_CN .mo/.qm
#   ④ 防不防更新覆盖  —— 入口是否走用户级 override 或 /usr/local/bin 包装
#
# 用法:
#   regression-test.sh              全量(两个 display 都测)
#   regression-test.sh :1           只测 :1
#   regression-test.sh :1 vlc       只测 :1 上的 vlc
#   regression-test.sh --static     只做静态检查(汉化/override/GPU分类), 不启动任何应用(快)
#   regression-test.sh --list       列出会测哪些应用
#
# 设计要点:
#   · 每个应用启动 ${WAIT}s 后判定, 然后【按 PID 精确杀】—— 不用 pkill -f 模式匹配,
#     因为那会匹配到本脚本自己的命令行(本项目反复踩过 exit 144 自杀)。
#   · 用 setsid 起, 记下 PID, 判定完 kill 整个进程组。
#   · 窗口判定: :1 有窗管用 wmctrl; :2 可能没窗管 → 回退 xwininfo 扫根窗口子窗口。
#   · GPU 判定: 读 /proc/<pid>/fd 找 kgsl-3d0 —— 这是唯一可靠证据, 比 glxinfo 更硬。
#   · 结果同时写 /tmp/regression/ 下, 方便事后翻。
# ════════════════════════════════════════════════════════════════════════════
set -u
OUT=/tmp/regression
WAIT=${WAIT:-12}          # 每个应用等几秒再判定
mkdir -p "$OUT"

# ── 应用清单: 名字|启动命令|是否期望用GPU(y=该用/n=不该用/-=无所谓) ──
# 期望值依据: 渲染密集(浏览器/播放器/Electron/Flutter)该吃 GPU; 纯文本工具不该。
APPS="
firefox|firefox|y
vlc|vlc|y
mpv|mpv --idle=yes --force-window=yes|y
spark-store|spark-store|y
linglong-store|linglong-store|y
lx-music|lx-music-desktop|y
thunar|thunar|n
mousepad|mousepad|n
xfce4-terminal|xfce4-terminal|n
xfce4-taskmanager|xfce4-taskmanager|n
ristretto|ristretto|n
xarchiver|xarchiver|n
pavucontrol|pavucontrol|n
xfce4-appfinder|xfce4-appfinder|n
"

c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_warn=$'\033[33m'; c_off=$'\033[0m'
ok(){ printf '%s%s%s' "$c_ok" "$1" "$c_off"; }
bad(){ printf '%s%s%s' "$c_bad" "$1" "$c_off"; }
warn(){ printf '%s%s%s' "$c_warn" "$1" "$c_off"; }

# 找某应用的 .desktop: 允许 org.xfce. 这类反向域名前缀(否则 org.xfce.mousepad.desktop 找不到, 误报"无中文名");
#   精确名优先(否则 thunar 会先命中 thunar-bulk-rename.desktop), 找不到再退到模糊名(如 firefox → firefox-esr)
pick_desktop() {   # $1=目录 $2=应用名
  local all; all=$(ls "$1"/*.desktop 2>/dev/null)
  echo "$all" | grep -iE "/([a-z0-9_-]+\.)*$2\.desktop$" | head -1 | grep . \
    || echo "$all" | grep -iE "/([a-z0-9_-]+\.)*$2[^/]*\.desktop$" | head -1
}

# ── 静态检查: 汉化 + 防更新覆盖 ──
static_check() {   # $1=应用名
  local app="$1" dfile sysd userd zh_name mo ovr wrap
  # 找 .desktop(优先用户级)
  userd=$(pick_desktop /root/.local/share/applications "$app")
  sysd=$(pick_desktop /usr/share/applications "$app")
  dfile="${userd:-$sysd}"
  # 汉化1: .desktop 有无中文名
  if [ -n "$dfile" ] && grep -q '^Name\[zh_CN\]=' "$dfile" 2>/dev/null; then zh_name=$(ok "有"); else zh_name=$(warn "无"); fi
  # 汉化2: 有无 zh_CN 翻译文件(.mo 或 Qt .qm)
  if ls /usr/share/locale/zh_CN/LC_MESSAGES/ 2>/dev/null | grep -qiE "^${app}(\.|-|_)" \
     || find /usr/share /opt -maxdepth 4 -name "*${app}*zh_CN*.qm" -print -quit 2>/dev/null | grep -q .; then
    mo=$(ok "有")
  else mo=$(warn "无"); fi
  # 防更新覆盖: 有用户级 override 或 命令解析到 /usr/local/bin
  wrap=$(command -v "$app" 2>/dev/null)
  # ★判定口径: 只有【被定制过】的应用才需要防更新覆盖。
  #   原版 dpkg 应用(XFCE 全家桶等)从没改过, 包更新也不会丢东西 → 标"原版"而非"会被覆盖"。
  #   判据: 该应用是否有我们加的用户级 override 或 /usr/local/bin 包装。
  if [ -n "$userd" ]; then ovr=$(ok "用户级desktop")
  elif [ -n "$wrap" ] && [ "${wrap#/usr/local/bin/}" != "$wrap" ]; then ovr=$(ok "usr/local包装")
  else ovr="原版(未定制)"; fi
  printf '%s|%s|%s' "$zh_name" "$mo" "$ovr"
}

# ── 动态检查: 启动 + 窗口 + GPU ──
run_check() {   # $1=display $2=应用名 $3=启动命令
  local disp="$1" app="$2" cmd="$3" pid rc win gpu shot fdcount
  [ -e "/tmp/.X11-unix/X${disp#:}" ] || { echo "SKIP|SKIP|SKIP"; return; }

  setsid env DISPLAY="$disp" $cmd >"$OUT/${app}${disp}.log" 2>&1 &
  pid=$!
  sleep "$WAIT"

  # 存活?(进程组里还有活的就算)
  if kill -0 "$pid" 2>/dev/null; then rc=$(ok "存活"); else
    # 有些应用会 fork 后父进程退出 → 再按名字找一次
    if pgrep -x "${app%% *}" >/dev/null 2>&1; then rc=$(ok "存活(fork)"); else rc=$(bad "已退出"); fi
  fi

  # 窗口?
  win=$(bad "无")
  if command -v wmctrl >/dev/null 2>&1 && timeout 8 env DISPLAY="$disp" wmctrl -lx 2>/dev/null \
       | grep -qiE "${app%% *}|${app%%-*}"; then
    win=$(ok "有")
  elif command -v xwininfo >/dev/null 2>&1; then
    # :2 可能没窗管 → 数根窗口的子窗口(>1 说明有应用窗口映射上来)
    if timeout 8 env DISPLAY="$disp" xwininfo -root -children 2>/dev/null \
         | grep -icE '^ +0x' | awk '{if($1>1) exit 0; else exit 1}'; then win=$(ok "有(xwininfo)"); fi
  fi

  # GPU? 读 fd 找 kgsl —— 最硬的证据
  gpu=$(warn "否")
  for p in $(pgrep -f "${app%% *}" 2>/dev/null | head -8); do
    [ "$p" = "$$" ] && continue
    if ls -l "/proc/$p/fd" 2>/dev/null | grep -q 'kgsl-3d0'; then gpu=$(ok "是(kgsl)"); break; fi
  done

  # 清理: 按进程组精确杀, 不用模式匹配(防自杀)
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
  sleep 1
  kill -9 -- "-$pid" 2>/dev/null || true

  printf '%s|%s|%s' "$rc" "$win" "$gpu"
}

# ── 调度 ──
case "${1:-}" in
  --list) echo "$APPS" | grep -v '^$' | awk -F'|' '{printf "  %-18s cmd=%-40s 期望GPU=%s\n",$1,$2,$3}'; exit 0 ;;
esac

STATIC_ONLY=0
[ "${1:-}" = "--static" ] && { STATIC_ONLY=1; shift; }
DISPLAYS="${1:-:1 :2}"
ONLY_APP="${2:-}"
[ "$DISPLAYS" = ":1" ] || [ "$DISPLAYS" = ":2" ] || DISPLAYS=":1 :2"

echo "════════════════════════════════════════════════════════════════════════"
echo " 应用回归测试   显示=[$DISPLAYS]   每app等待=${WAIT}s   $(date '+%m-%d %H:%M')"
echo "════════════════════════════════════════════════════════════════════════"

printf '\n【静态检查】汉化 与 防更新覆盖\n'
printf '  %-16s %-10s %-10s %-22s %s\n' 应用 中文名 翻译文件 防更新覆盖 期望GPU
printf '  %s\n' "────────────────────────────────────────────────────────────────────"
echo "$APPS" | grep -v '^$' | while IFS='|' read -r app cmd wantgpu; do
  [ -n "$ONLY_APP" ] && [ "$app" != "$ONLY_APP" ] && continue
  IFS='|' read -r zh mo ovr <<< "$(static_check "$app")"
  printf '  %-16s %-19s %-19s %-31s %s\n' "$app" "$zh" "$mo" "$ovr" "$wantgpu"
done

[ "$STATIC_ONLY" = 1 ] && { echo; echo "(--static: 未启动任何应用)"; exit 0; }

for d in $DISPLAYS; do
  printf '\n【动态检查 %s】能否打开 / 有无窗口 / 是否吃 GPU\n' "$d"
  if [ ! -e "/tmp/.X11-unix/X${d#:}" ]; then echo "  ✘ $d socket 不存在, 跳过整组"; continue; fi
  printf '  %-16s %-12s %-12s %-12s %s\n' 应用 启动 窗口 GPU 判定
  printf '  %s\n' "────────────────────────────────────────────────────────────────────"
  echo "$APPS" | grep -v '^$' | while IFS='|' read -r app cmd wantgpu; do
    [ -n "$ONLY_APP" ] && [ "$app" != "$ONLY_APP" ] && continue
    command -v "${cmd%% *}" >/dev/null 2>&1 || { printf '  %-16s %s\n' "$app" "$(warn '未安装, 跳过')"; continue; }
    IFS='|' read -r rc win gpu <<< "$(run_check "$d" "$app" "$cmd")"
    # 判定: GPU 期望与实际是否相符
    verdict=""
    case "$wantgpu" in
      y) echo "$gpu" | grep -q 是 && verdict=$(ok "符合") || verdict=$(warn "期望走GPU但没走") ;;
      n) echo "$gpu" | grep -q 是 && verdict=$(warn "意外占用GPU") || verdict=$(ok "符合") ;;
      *) verdict="-" ;;
    esac
    printf '  %-16s %-21s %-21s %-21s %s\n' "$app" "$rc" "$win" "$gpu" "$verdict"
  done
done

echo
echo "详细日志: $OUT/<应用><display>.log"
