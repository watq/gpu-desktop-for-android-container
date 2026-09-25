#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# desktop-env/electron-gpu.sh —— Electron/Chromium 专用 GPU 环境 (2026-09-24)
#
# 为什么 Electron 要单独一套(不能和 Firefox/VLC 共用 gpu.sh):
#   · Chromium 的 GPU 初始化【不看】环境变量里的 Mesa 设置, 它有自己的一套命令行开关,
#     且会先做设备枚举(PCI / /sys/class/drm) 再决定用不用 GPU。
#   · 本机 PCI 枚举拿不到 → 日志必现 `pcilib: Cannot open /proc/bus/pci/devices`。
#     ★2026-09-24 已攻克这一条(见 已验证事实 E-AY): /proc/bus/pci 目录其实【存在】, devices 文件是
#       EACCES(SELinux 拦)而非 ENOENT → LD_PRELOAD 劫持 open/fopen 把它重定向到一个伪造文件即可,
#       GPU 子进程会继承这个 LD_PRELOAD。实测 GPU 进程随即持有 3 个 /dev/kgsl-3d0 fd(真硬件)。
#   · 所以 Electron 仍需【命令行参数】而不是【Mesa 环境变量】来调 GPU, 两套机制必须分开管。
#
# 用法: 由 electron-wrap 在启动前 source, 然后用 $ELECTRON_GPU_FLAGS 展开到命令行。
#   . /root/.config/desktop-env/electron-gpu.sh
#   exec "$BIN" $ELECTRON_GPU_FLAGS "$@"
#
# 逃生开关:
#   ELECTRON_GPU=off   → 完全不加 GPU 参数(回到纯软件, 出问题时用)
#   ELECTRON_GPU=safe  → 默认: 伪造 PCI + 走默认 egl-angle(实测能吃到 kgsl)
#   ELECTRON_GPU=full  → safe 再加激进参数(光栅化/零拷贝等)
#   ELECTRON_FAKEPCI=0 → 单独关掉 PCI 伪造(排障用; 关掉后必然回到软件光栅)
# ══════════════════════════════════════════════════════════════════════════════

# ── 基础: proot 假 root 下 Electron 必需的两个, 与 GPU 无关但不能少 ──
#   --no-sandbox            chrome-sandbox 要 setuid root, proot 假 root 位不生效
#   --disable-dev-shm-usage 本环境 /dev/shm 被 start.sh 绑成了 /root
_EL_BASE="--no-sandbox --disable-dev-shm-usage --disable-gpu-sandbox"

# ── 按 display 分流: :1(TigerVNC+DRI3补丁) 与 :2(Termux:X11) 的呈现路径不同 ──
_d="${DISPLAY:-:1}"
case "$_d" in
  :1*)
    # VNC 侧: Xtigervnc-dri3 走 lorie DRI3-over-mmap。
    # ★实测: zink 在 :1 上会 CreateSwapchainKHR 失败(VK_ERROR_INITIALIZATION_FAILED),
    #   所以这里和其它应用一样必须走 kgsl 原生, 不能让它落到 zink。
    _EL_DISP_ENV="MESA_LOADER_DRIVER_OVERRIDE=kgsl EGL_PLATFORM=x11 LIBGL_ALWAYS_SOFTWARE=0"
    ;;
  :2*)
    # Termux:X11 侧: 原生 DRI3 + Present, 还有 AHardwareBuffer 零拷贝通道, 天花板更高。
    _EL_DISP_ENV="MESA_LOADER_DRIVER_OVERRIDE=kgsl EGL_PLATFORM=x11 LIBGL_ALWAYS_SOFTWARE=0"
    ;;
  *)
    _EL_DISP_ENV=""
    ;;
esac

# ── ★PCI 伪造(2026-09-24, E-AY): Chromium 吃到 kgsl 的【决定性开关】──
#   GPU 子进程死在 `pcilib: Cannot open /proc/bus/pci/devices`(EACCES), 连 EGL 都没初始化就 exit 1。
#   劫持后才暴露出第二层错误(--use-gl=egl 被拒), 去掉 --use-gl 才真正走到 `Using DRI3 for screen 0`。
#   实测对照(同命令同 DISPLAY): 挂 fakepci → GPU 进程 kgsl fd=3; 不挂 → 0。
#   本体在 /root/.local/lib/electron-shim(用户级, 与 spark-shim 同级; 不归 dpkg 管, apt 与应用自更新都冲不掉);
#   只劫持这一个路径, 其余原样透传。
#   ★LD_PRELOAD 用【追加】不用覆盖 —— VLC 等应用也在用 LD_PRELOAD shim, 别互相顶掉。
_EL_SHIM=/root/.local/lib/electron-shim
if [ "${ELECTRON_FAKEPCI:-1}" = 1 ] && [ -f "$_EL_SHIM/fakepci.so" ] && [ -f "$_EL_SHIM/fake-pci-devices" ]; then
  case ":${LD_PRELOAD:-}:" in
    *":$_EL_SHIM/fakepci.so:"*) : ;;                      # 已挂: 幂等
    *) export LD_PRELOAD="$_EL_SHIM/fakepci.so${LD_PRELOAD:+:$LD_PRELOAD}" ;;
  esac
  export FAKE_PCI_FILE="$_EL_SHIM/fake-pci-devices"
fi

# ── ★版本探测(2026-09-24, E-BF/E-BH): 不同 Chrome 代的要求【正好相反】, 必须按版本分流 ──
#   144 及更早: fopen /proc/bus/pci/devices 成功后【直接 open /dev/kgsl-3d0】→ fakepci 就能吃硬件。
#   148 起    : 改成【必须拿到 DRM render node fd】, 而本机 /dev/dri/renderD128 是 EACCES(SELinux 拒)
#               → 全程不碰 kgsl, 固定报 gl=none, 加 --use-gl=angle / --use-angle=gl 都无效(报错一字不差)
#               → 该代只能走软件, 且 Chrome ≥125 必须显式 --enable-unsafe-swiftshader 才允许回落 SwiftShader
#                 (否则 GPU 进程静默 exit 1, 连日志都不打)。
#   ★调用方(包装脚本)需在 source 本文件【之前】定义 BIN 或 ELECTRON_BIN 指向真实可执行文件;
#     拿不到就退回保守档, 绝不让应用起不来。
#   ★缓存: 二进制动辄 200MB, 每次启动 strings 一遍会明显拖慢; 按 路径|size|mtime 做 key 缓存,
#     二进制一换(升级/替换)key 自然失效, 无需手动清。
_EL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/electron-gpu"
_el_chrome_major() {   # $1=可执行文件 → 打印 major; 拿不到就打印空
  [ -n "${1:-}" ] && [ -r "$1" ] || return 0
  local st key f v
  st=$(stat -c '%s|%Y' "$1" 2>/dev/null) || return 0
  key=$(printf '%s|%s' "$1" "$st" | md5sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$key" ] || return 0
  f="$_EL_CACHE/$key"
  if [ -r "$f" ]; then cat "$f" 2>/dev/null; return 0; fi
  v=$(strings "$1" 2>/dev/null | grep -oE 'Chrome/[0-9]+' | sort -u | head -1 | cut -d/ -f2)
  mkdir -p "$_EL_CACHE" 2>/dev/null && printf '%s' "$v" > "$f" 2>/dev/null
  printf '%s' "$v"
}
_EL_MAJOR=$(_el_chrome_major "${ELECTRON_BIN:-${BIN:-}}")

# 自动选档(显式设的 ELECTRON_GPU 优先, 见下面的 :-)
#   ≤144 → kgsl(真硬件); ≥145 → swsafe(软件但可用); 探测不到 → safe(保守, 兼容一切)
if [ -n "$_EL_MAJOR" ] 2>/dev/null; then
  if [ "$_EL_MAJOR" -le 144 ] 2>/dev/null; then _EL_AUTO=kgsl; else _EL_AUTO=swsafe; fi
else
  _EL_AUTO=safe
fi

# ── GPU 参数分级 ──
case "${ELECTRON_GPU:-$_EL_AUTO}" in
  off)
    ELECTRON_GPU_FLAGS="$_EL_BASE --disable-gpu --disable-software-rasterizer"
    ;;
  kgsl)
    # ★真硬件档(≤144 代): 配合上面的 fakepci。实测 144 代 GPU 进程持有 /dev/kgsl-3d0 fd(2~3 个),
    #   130 代由 CDP 证实 renderer=ANGLE(Mesa, zink … Adreno 830v1 MESA_TURNIP) 且三项 feature enabled。
    #   ★【绝对不要加 --use-gl】: Chrome 144 只接受 (gl=egl-angle, angle=default), 传 egl 会被
    #     gl_factory.cc 拒掉 → Exiting GPU process → 回落 SwiftShader。
    ELECTRON_GPU_FLAGS="$_EL_BASE --ignore-gpu-blocklist"
    ;;
  swsafe)
    # ★软件可用档(≥145/148 代): 硬件拿不到(要 DRM render node, 本机 EACCES), 至少把 GPU 进程救活。
    #   --enable-unsafe-swiftshader 是 Chrome ≥125 的硬要求, 不加则 GpuInit 静默失败 → 崩 3 次 → GL 全关。
    #   加了之后: 崩溃 0, WebGL/WebGPU/Canvas 从 disabled_off 变 unavailable_software(软件可用)。
    ELECTRON_GPU_FLAGS="$_EL_BASE --ignore-gpu-blocklist --enable-unsafe-swiftshader"
    ;;
  full)
    # 实验档: 在 kgsl 基础上加激进参数。★不含 --gpu-testing-*-id(那两个在 Chrome 148 上会让应用起不来)。
    ELECTRON_GPU_FLAGS="$_EL_BASE --ignore-gpu-blocklist \
--enable-gpu-rasterization --enable-zero-copy --disable-gpu-driver-bug-workarounds"
    ;;
  safe|*)
    # ★兜底档(探测不到版本时用)。★2026-09-24 重要修正: 这里【曾经】用 --use-gl=egl,
    #   实测证明那是【有害的】 —— Chrome 120 代加上它会从
    #     impl=(gl=egl-angle,angle=opengl) / renderer=ANGLE(Mesa, zink … Adreno 830v1)  [真硬件]
    #   变成
    #     impl=(gl=egl-angle,angle=swiftshader) / renderer=SwiftShader + GPU 崩溃 3 次  [软件]
    #   80~144 各代实测【都靠"不传 --use-gl"吃到硬件】; 而 148 代用这套虽然吃不到硬件, 但窗口正常、
    #   崩溃 0 —— 所以"不传 --use-gl + --ignore-gpu-blocklist"是对所有代都安全的兜底, 严格优于 --use-gl=egl。
    ELECTRON_GPU_FLAGS="$_EL_BASE --ignore-gpu-blocklist"
    ;;
  egl)
    # 仅留作排障对照(复现"加了 --use-gl=egl 反而掉到 SwiftShader"那个现象), 日常不要用。
    ELECTRON_GPU_FLAGS="$_EL_BASE --use-gl=egl"
    ;;
esac

# 把 display 相关的 Mesa 变量导出(对 Electron 自身影响有限, 但它内部起的
# 辅助进程/子进程若走 GL 仍会读到; 且与 gpu.sh 保持口径一致便于排障)
if [ -n "$_EL_DISP_ENV" ]; then
  for _kv in $_EL_DISP_ENV; do export "${_kv?}"; done
fi
unset _d _kv _EL_DISP_ENV

export ELECTRON_GPU_FLAGS
