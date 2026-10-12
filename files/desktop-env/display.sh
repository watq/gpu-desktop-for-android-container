# desktop-env/display.sh —— 显示目标切换 (VNC :1 与 Termux:X11 :2 两套独立, 不合并)
# use1 → VNC(:1): GL 走软件(llvmpipe, VNC 无 DRI3); Vulkan 仍硬件(Turnip)
# use2 → Termux:X11(:2): 开 kgsl 让 GL 也走硬件(旧机此路可用; 新机待实测)
#
# ★2026-09-27 改: 原来只判 `[ -e /tmp/.X11-unix/X1 ]` = socket 文件存在。
#   但 socket 会**残留**(Xvnc 死了文件还在, startvnc 第 66 行就是专门清这种残留的),
#   于是"进容器 DISPLAY 被设成一个死的 :1"。加一道 pid 判活:
#     :1 是我们自己起的 → /root/.vnc/localhost:1.pid 里的进程还活着才算数
#     :2 的 X server 活在【宿主 Android App】里, 容器内 /proc 根本看不到 → socket 存在
#        就是唯一可用信号(与 00-clean-tmp.sh 里"X2 绝不碰"同一条理由)
#   判据全是文件 stat, 零 fork, 不扫 /proc —— 开 shell 不会变慢。
if [ -z "${DISPLAY:-}" ] || [ "$DISPLAY" = ":0" ]; then
  _d1_ok=0
  if [ -e /tmp/.X11-unix/X1 ]; then
    _d1_ok=1
    if [ -s /root/.vnc/localhost:1.pid ]; then
      read -r _d1pid < /root/.vnc/localhost:1.pid 2>/dev/null
      case "$_d1pid" in
        ''|*[!0-9]*) ;;                                  # pid 文件内容不像 pid → 不据此否决
        *) [ -d "/proc/$_d1pid" ] || _d1_ok=0 ;;         # pid 死了 → socket 是残留
      esac
    fi
  fi
  if   [ "$_d1_ok" = 1 ] && [ -e /tmp/.X11-unix/X2 ]; then
    # ★2026-09-27 加: 两个都活着 → 按【空闲时间】选用户正在用的那个, 而不是写死 :1 优先。
    #   判据 = XScreenSaverQueryInfo 的 idle 毫秒; 谁小谁是你刚在操作的屏幕。
    #   实测验证: 用户说"VNC在前台"时 :1=50s / :2=164s, 探针独立判出 :1, 与描述吻合。
    #   探针 /root/工具箱/sh/xidle(自编, 手工声明原型, 不依赖 libxss-dev)。
    #   失败/取不到 → 回退原来的 :1 优先。可用 DISPLAY_AUTO=0 关掉这段。
    _dpick=""
    if [ "${DISPLAY_AUTO:-1}" = 1 ] && [ -x /root/工具箱/sh/xidle ]; then
      _i1=$(DISPLAY=:1 /root/工具箱/sh/xidle 2>/dev/null)
      _i2=$(DISPLAY=:2 /root/工具箱/sh/xidle 2>/dev/null)
      case "$_i1$_i2" in
        ''|*-1*|*[!0-9]*) ;;                                  # 任一取不到 → 不据此决定
        *) [ "$_i2" -lt "$_i1" ] && _dpick=:2 || _dpick=:1 ;;
      esac
    fi
    export DISPLAY="${_dpick:-:1}"
    unset _dpick _i1 _i2
  elif [ "$_d1_ok" = 1 ];            then export DISPLAY=:1
  elif [ -e /tmp/.X11-unix/X2 ];     then export DISPLAY=:2
  elif [ -e /tmp/.X11-unix/X1 ];     then export DISPLAY=:1   # 都判不活: 保守回到原行为
  else export DISPLAY=:1
  fi
  unset _d1_ok _d1pid
fi
use1() { export DISPLAY=:1; unset MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER
         echo "[切换] VNC(:1): GL=软件/llvmpipe, Vulkan=硬件"; }
use2() { export DISPLAY=:2; export MESA_LOADER_DRIVER_OVERRIDE=kgsl EGL_PLATFORM=x11 LIBGL_ALWAYS_SOFTWARE=0
         echo "[切换] Termux:X11(:2): GL 尝试 kgsl 硬件"; }
