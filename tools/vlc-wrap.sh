#!/bin/bash
# /root/工具箱/sh/vlc-wrap.sh —— VLC 顶层薄包装(按显示器自动选输出后端)
#   放这里(工具箱/sh, 会被 backup-to-github 收), 由 /root/.local/bin/vlc 符号链拉起(PATH 最前)。
#   本层只加 --vout, 随后 exec 既有的 /usr/local/bin/vlc(noroot shim / 插件镜像 / GPU 环境那层),
#   两层互不重复, 也不动 dpkg /usr/bin/vlc。
# 机制(E-CO / E-BW / E-CK):
#   :1(VNC/Xtigervnc-dri3) present 走 sw-WSI 回读, GL 输出比纯 CPU 贵 2.4x
#     (实测 vout=gl 74% vs xcb_x11 32%) → :1 默认 xcb_x11。
#   :2(Termux:X11) present 零拷贝, GL 全尺寸 0 丢帧、全屏还反超 xcb → :2 保持默认(gl), 不强制。
# 关闭: VLC_VOUT_AUTO=0; 或自己命令行带 --vout=(检测到就不覆盖)。
# 注: xfce 的 vlc.desktop 目前 Exec=/usr/bin/vlc(绝对路径, 绕过本链)。要让菜单也走包装,
#     需把它改成 Exec=vlc —— 属另一处改动, 未擅自动。
set -u
INNER=/usr/local/bin/vlc
[ -x "$INNER" ] || { echo "vlc-wrap: 找不到 $INNER" >&2; exit 127; }

VOUT_ARGS=()
if [ "${VLC_VOUT_AUTO:-1}" = 1 ]; then
    case " $* " in
        *" --vout"*|*" --no-video"*|*" -V "*) : ;;      # 用户已指定输出 → 不动
        *) case "${DISPLAY:-}" in
               :1|:1.*) VOUT_ARGS=(--vout=xcb_x11) ;;    # VNC: 纯 CPU 输出最省
           esac ;;
    esac
fi

exec "$INNER" "${VOUT_ARGS[@]}" "$@"
