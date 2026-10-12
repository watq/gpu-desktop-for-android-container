# desktop-env/gpu.sh —— GPU 环境 (Adreno 830 + 容器版 Mesa 26.3, KGSL)
# Vulkan(Turnip)到处可用 → 全局设 VK_ICD 即可。
# ★2026-09-30 更正过期注释: 这里原来写的是 "当前是 TigerVNC 1.13.1(无 -rendernode) → DRI3 未生效
#   → GL 暂时软件(llvmpipe)"。已不成立, 实测现状:
#   · :1(VNC) 跑的是自编 /usr/local/bin/Xtigervnc-dri3 —— `Xvnc TigerVNC 1.16.2 - built Mar 26 2026`。
#     startvnc 只在选中 DRI3 版那一支才 export MESA_LOADER_DRIVER_OVERRIDE=kgsl(startvnc:88-90);
#     --legacy 走系统原版 1.13.1 时照旧 unset kgsl 走软件, --soft 也一样。
#   · :2(Termux:X11) 由 startx11 按 display 单独 export kgsl(startx11:101-111)。
#   · 实测 `DISPLAY=:1 MESA_LOADER_DRIVER_OVERRIDE=kgsl glxinfo -B`:
#       OpenGL renderer string: Adreno (TM) 830v1 / Accelerated: yes / direct rendering: Yes
#     ⇒ 硬件直出, 不是 llvmpipe。
#   · 已跑的桌面 /proc/<xfwm4>/environ 里确实带 MESA_LOADER_DRIVER_OVERRIDE=kgsl(:1 与 :2 都有)。
# 但本文件【依旧不全局 export kgsl】—— 这一条不是过期, 是有意保留:
#   gpu.sh 被 startvnc / startx11 / .bashrc 共同 source, 而 --legacy / --soft 两条分支需要"没有 kgsl";
#   全局设上会让原版 Xvnc 那条路 "MESA-LOADER: failed to retrieve device information" 崩掉(N16)。
#   所以 kgsl 由各启动脚本按 display 分别开: startvnc:88-90 / startx11:101-111 / display.sh:48-50。
#   不设 override 时默认回落 zink→Turnip, 实测同样 direct rendering: Yes(仍是硬件), 只是多一层翻译。
[ "${GPU_OFF:-0}" = 1 ] && { export LIBGL_ALWAYS_SOFTWARE=1; return 0; }
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
export MESA_VK_WSI_PRESENT_MODE=mailbox
# ★2026-09-24 实测修正: 原为 vblank_mode=3(always sync) —— 那会把【native EGL 路径】
#   锁死在屏幕刷新率上。glmark2-es2 实测: vblank_mode=3 → 119 分(33 个子项全锁 120FPS/8.31ms),
#   改成 0 → **1750 分**。zink 走 kopper/WSI 由 MESA_VK_WSI_PRESENT_MODE 管, 不受 vblank_mode
#   影响 —— 所以带着 vblank_mode=3 做 zink vs kgsl 的 A/B 是无效对比(会得出 zink 反而更快的假象)。
#   ※ 若出现画面撕裂, 可改回 1(应用请求时同步); 不要再用 3。
export vblank_mode=0
# ★下面这行【保持注释状态】, 别取消注释 —— 理由见文件开头 2026-09-30 那段:
#   1.16.2 + DRI3 已经到位, 但全局开 kgsl 会打死 --legacy(1.13.1)/--soft 两条回退路。
#   kgsl 由 startvnc / startx11 / display.sh 按 display 分别开, 那才是正确落点。
# export MESA_LOADER_DRIVER_OVERRIDE=kgsl
