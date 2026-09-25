# desktop-env/gpu.sh —— GPU 环境 (Adreno 830 + 容器版 Mesa 26.3, KGSL)
# Vulkan(Turnip)到处可用 → 全局设 VK_ICD 即可。
# GL 硬件加速看 DRI3:
#   · VNC(:1): DRI3 【可以搞、历史上成功过】, 但要 TigerVNC≥1.16 + 启动带 -rendernode /dev/kgsl-3d0;
#     当前是 1.13.1(无 -rendernode) → DRI3 未生效 → GL 暂时软件(llvmpipe)。上了 1.16 就能开(见 N16)。
#   · Termux:X11(:2): use2 开 kgsl。
# 现阶段不全局强设 MESA_LOADER_DRIVER_OVERRIDE=kgsl: 因为 DRI3 没配好前, VNC 下 GL 走 kgsl 会
#   "MESA-LOADER: failed to retrieve device information" 崩掉(连 llvmpipe 回落都没)。DRI3 配好后可全局开。
[ "${GPU_OFF:-0}" = 1 ] && { export LIBGL_ALWAYS_SOFTWARE=1; return 0; }
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
export MESA_VK_WSI_PRESENT_MODE=mailbox
# ★2026-09-24 实测修正: 原为 vblank_mode=3(always sync) —— 那会把【native EGL 路径】
#   锁死在屏幕刷新率上。glmark2-es2 实测: vblank_mode=3 → 119 分(33 个子项全锁 120FPS/8.31ms),
#   改成 0 → **1750 分**。zink 走 kopper/WSI 由 MESA_VK_WSI_PRESENT_MODE 管, 不受 vblank_mode
#   影响 —— 所以带着 vblank_mode=3 做 zink vs kgsl 的 A/B 是无效对比(会得出 zink 反而更快的假象)。
#   ※ 若出现画面撕裂, 可改回 1(应用请求时同步); 不要再用 3。
export vblank_mode=0
# DRI3 配好(TigerVNC 1.16 + -rendernode)后, 把下面这行取消注释即可全局硬件 GL:
# export MESA_LOADER_DRIVER_OVERRIDE=kgsl
