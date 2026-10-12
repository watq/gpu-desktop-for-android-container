#!/bin/bash
# VLC 顶层薄包装: :1(VNC)与:2(Termux:X11)默认使用xcb_x11输出。
# E-DL实测GL输出有重复帧; 两屏xcb_x11均通过视频验收。当前现场仍需按用户复现重新验收。
# ~/.local/bin/vlc 与 /usr/local/bin/vlc 都 -> 本文件; 内层保留noroot、插件、音频、语言环境处理。
# VLC_VOUT_AUTO=0关闭自动选择; 显式--vout/-V/--no-video优先，--后全是媒体参数。
# ★2026-10-03 归位: 内层本体原来是 /usr/local/bin/vlc(真文件), 已 mv 到
#   /root/.local/lib/vlc-shim/vlc-core.sh, /usr/local/bin/vlc 改成指向【本文件】的软链。
#   ★★INNER 绝不能再写 /usr/local/bin/vlc —— 那现在就是本文件, 会无限递归。
set -u
INNER=/root/.local/lib/vlc-shim/vlc-core.sh
if [ ! -x "$INNER" ]; then
    printf 'vlc-wrap: 找不到 %s\n' "$INNER" >&2
    exit 127
fi

VOUT_ARGS=()
if [ "${VLC_VOUT_AUTO:-1}" = 1 ]; then
    explicit_vout=0
    for arg in "$@"; do
        case "$arg" in
            --) break ;;
            --vout|--vout=*|--no-video|-V|-V?*) explicit_vout=1; break ;;
        esac
    done
    if [ "$explicit_vout" = 0 ]; then
        case "${DISPLAY:-}" in
            :1|:1.*|:2|:2.*) VOUT_ARGS=(--vout=xcb_x11) ;;
        esac
    fi
fi

exec "$INNER" "${VOUT_ARGS[@]}" "$@"
