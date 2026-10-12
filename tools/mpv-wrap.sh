#!/bin/bash
# 用户级 mpv 默认输出；MPV_VO_AUTO=0 关闭。只适用于本机已知 :1/:2。
# ~/.local/bin/mpv -> 本文件；固定执行包内二进制，避免 PATH 递归。
# 显式输出/配置、无视频、查询及编码任务原样透传；不修改全局 GPU 环境。
set -u
REAL=/usr/bin/mpv
[ -x "$REAL" ] || { echo "mpv-wrap: 找不到 $REAL" >&2; exit 127; }
[ ! "$REAL" -ef "${BASH_SOURCE[0]}" ] || { echo 'mpv-wrap: 实际入口指向包装脚本，拒绝递归' >&2; exit 126; }

auto=1
[ "${MPV_VO_AUTO:-1}" = 1 ] || auto=0
[ "$#" -gt 0 ] || auto=0
# 不猜测远程/未知 DISPLAY，也不把 Wayland 或无 DISPLAY 当成 Termux:X11。
screen=''
if [[ ${DISPLAY:-} =~ ^:([12])(\.[0-9]+)?$ ]]; then
    screen=${BASH_REMATCH[1]}
else
    auto=0
fi
query_value=0
for arg in "$@"; do
    if [ "$query_value" -eq 1 ]; then
        [ "$arg" != help ] || auto=0
        query_value=0
    fi
    # mpv 仍接受 -vo null 等单横线兼容语法；只规范分类副本，不改原 argv。
    case "$arg" in
        --) break ;;
        --*) ;;
        -?*) arg="-$arg" ;;
        *) continue ;;
    esac
    case "$arg" in
        --vo|--vo=*|--vo-*|--profile|--profile=*|--profile-*|--gpu-*|--vulkan-*|--opengl-*)
            auto=0 ;;
        --no-config|--no-config=*|--config|--config=*|--config-dir|--config-dir=*|--include|--include=*|--use-filedir-conf|--use-filedir-conf=*)
            auto=0 ;;
        --no-video|--no-video=*|--vid|--video|--vid=no|--video=no|--frames=0)
            auto=0 ;;
        --h|--help|--help=*|--version|--list-options|--list-properties|--list-protocols|--input-cmdlist|--input-keylist|--show-profile|--show-profile=*)
            auto=0 ;;
        --ao=help|--ad=help|--vd=help|--hwdec=help|--audio-device=help|--af=help|--vf=help|--demuxer=help|--demuxer-lavf-format=help)
            auto=0 ;;
        --ao|--ad|--vd|--hwdec|--audio-device|--af|--vf|--demuxer|--demuxer-lavf-format)
            query_value=1 ;;
        -o|-o=*|--o|--o=*|--of|--of=*|--ofopts|--ofopts=*|--ovc|--ovc=*|--ovcopts|--ovcopts=*|--oac|--oac=*|--oacopts|--oacopts=*|--stream-dump|--stream-dump=*)
            auto=0 ;;
    esac
done

# 仅自动分支查询真实二进制能力。失败或未知版本保持原调用，不猜版本号。
# --no-config 的 help 查询不打开媒体/图形；限制耗时且不污染调用者 locale。
_mpv_auto_supported() {
    local listing name detail found=0
    command -v timeout >/dev/null 2>&1 || return 1
    listing=$(LC_ALL=C timeout 2 "$REAL" --no-config --vo=help 2>/dev/null) || return 1
    while read -r name detail; do
        [ "$name" != gpu-next ] || found=1
    done <<< "$listing"
    [ "$found" -eq 1 ] || return 1
    listing=$(LC_ALL=C timeout 2 "$REAL" --no-config --gpu-context=help 2>/dev/null) || return 1
    while read -r name detail; do
        if [ "$name" = x11vk ] && [[ $detail == '(vulkan)'* ]]; then return 0; fi
    done <<< "$listing"
    return 1
}

EXTRA=()
if [ "$auto" -eq 1 ] && _mpv_auto_supported; then
    EXTRA=(--vo=gpu-next --gpu-api=vulkan --gpu-context=x11vk)
    # 用户已设置（包括显式空值）的 MESA 选项优先；只给本次子进程补默认。
    if [ "$screen" = 1 ] && [ "${MESA_VK_WSI_DEBUG+x}" != x ]; then
        export MESA_VK_WSI_DEBUG=sw
    fi
fi
exec "$REAL" "${EXTRA[@]}" "$@"
