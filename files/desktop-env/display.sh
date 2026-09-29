# desktop-env/display.sh —— 显示目标切换 (VNC :1 与 Termux:X11 :2 两套独立, 不合并)
# use1 → VNC(:1): GL 走软件(llvmpipe, VNC 无 DRI3); Vulkan 仍硬件(Turnip)
# use2 → Termux:X11(:2): 开 kgsl 让 GL 也走硬件(旧机此路可用; 新机待实测)
if [ -z "${DISPLAY:-}" ] || [ "$DISPLAY" = ":0" ]; then
  if   [ -e /tmp/.X11-unix/X1 ]; then export DISPLAY=:1
  elif [ -e /tmp/.X11-unix/X2 ]; then export DISPLAY=:2
  else export DISPLAY=:1
  fi
fi
use1() { export DISPLAY=:1; unset MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER
         echo "[切换] VNC(:1): GL=软件/llvmpipe, Vulkan=硬件"; }
use2() { export DISPLAY=:2; export MESA_LOADER_DRIVER_OVERRIDE=kgsl EGL_PLATFORM=x11 LIBGL_ALWAYS_SOFTWARE=0
         echo "[切换] Termux:X11(:2): GL 尝试 kgsl 硬件"; }
