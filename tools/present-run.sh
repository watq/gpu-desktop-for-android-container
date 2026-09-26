#!/bin/bash
# /root/工具箱/sh/present-run.sh —— 通用「安全上屏」启动器
#   2026-09-26 建(视频闪烁/黑块修复子代理)。由 /root/.local/bin/present-run 符号链拉起。
#
# 作用: 先套 present-policy.sh 的绕法③(MESA_LOADER_DRIVER_OVERRIDE=zink, 必要时 MESA_VK_WSI_DEBUG=sw),
#   再 exec 后面的命令。给【只会用 OpenGL、又没有输出后端开关】的程序用 —— 那条路(GL/EGL+kgsl 原生 DRI3)
#   在本机会让 X 服务端读到没画完的 dmabuf, 表现为 20~30% 的帧整窗全黑(闪烁/黑块)。
#   zink 把 GL 翻到 Vulkan/Turnip, present 改走有 xshmfence 围栏的 Vulkan WSI → 实测 0 闪烁。
#   详细根因与实测数据见 /root/.config/desktop-env/present-policy.sh 头部。
#
# 用法:  present-run <命令> [参数...]
#        也可直接写进 .desktop 的 Exec=  (例: Exec=present-run kylin-video-new %U)
# 关掉:  PRESENT_POLICY=0 present-run <命令>   → 等于直接跑该命令
set -u
POLICY=/root/.config/desktop-env/present-policy.sh
[ -r "$POLICY" ] && { . "$POLICY"; present_policy_gl_safe; }
[ $# -ge 1 ] || { echo "用法: present-run <命令> [参数...]" >&2; exit 2; }
exec "$@"
