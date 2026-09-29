#!/bin/bash
# /root/工具箱/sh/mpv-wrap.sh —— mpv 用户级包装(按显示器自动选最省 CPU 输出)
#   放这里(工具箱/sh, 会被 backup-to-github 收), 由 /root/.local/bin/mpv 符号链拉起
#   (/root/.local/bin 在 PATH 最前, shell 和 xfce 菜单[Exec=mpv]都命中)。不改 dpkg /usr/bin/mpv。
# 机制(E-CO):
#   :2(Termux:X11) present 零拷贝 → 用 ~/.config/mpv/mpv.conf 默认档
#     (vo=gpu-next + gpu-api=vulkan + x11vk, 实测 ~42%, :2 上最省)。
#   :1(VNC/Xtigervnc-dri3) present 走 sw-WSI 回读 → Vulkan(gpu-next) 40.6% 反而贵,
#     实测 --vo=gpu(OpenGL) 27.3% 最省(E-CL) → :1 自动套 mpv.conf 里已有的 [gl-compat] 档。
# 关闭: MPV_VO_AUTO=0; 或自己命令行带 --vo=/--profile=(检测到就不覆盖)。
set -u
REAL=/usr/bin/mpv
[ -x "$REAL" ] || { echo "mpv-wrap: 找不到 $REAL" >&2; exit 127; }

EXTRA=()
if [ "${MPV_VO_AUTO:-1}" = 1 ]; then
    case " $* " in
        *" --vo"*|*" --profile"*) : ;;                 # 用户已指定输出/档 → 不动
        *) case "${DISPLAY:-}" in
               :1|:1.*) EXTRA=(--profile=gl-compat) ;;  # VNC: OpenGL 路径最省
           esac ;;
    esac
fi

exec "$REAL" "${EXTRA[@]}" "$@"
