# ══════════════════════════════════════════════════════════════════════════════
# /root/.config/desktop-env/present-policy.sh
#   「上屏(present)路径」策略 —— 按 display 分流, 规避 GL(EGL/x11egl)+kgsl 的 DRI3 黑帧
#   2026-09-26 建(视频闪烁/黑块修复子代理)。用户级、可逆、不改 dpkg 文件。
#
# ▌要解决的现象
#   视频播放时 20%~30% 的帧【整窗全黑】, 偶尔"画到一半"(大块黑) → 肉眼是强烈闪烁/黑块。
#   :1(TigerVNC) 与 :2(Termux:X11) 都有。
#
# ▌根因(2026-09-26 实测定位, 活体时钟判据)
#   只有【OpenGL / EGL(x11egl) 走 kgsl 原生 DRI3 呈现】这一条路会黑。
#   DRI3 的模型是: 客户端 GPU 画进 dmabuf, X 服务端 (Xvnc-dri3 / Xlorie) 把它 mmap 后拷进帧缓冲。
#   拷之前必须等客户端 GPU 画完 —— 这个"等"靠 X SyncFence(xshmfence) 实现。
#   · Vulkan WSI 会为每张 swapchain image 建 xshmfence → 有围栏 → 干净。
#   · Mesa 的 GL/EGL kgsl 路径【一次都不建 fence】(账本 E-BC 的 xcb trace 实测) → 无围栏
#     → 服务端在 GPU 还在画的时候就把 dmabuf 拷走了。
#     mpv/麒麟这类渲染器每帧先 glClear 成黑再画, 所以拷到的中间态就是【整帧全黑】; 拷到画了一半
#     就是【大块黑】。撕裂/拼帧则为 0 —— 因为黑的是"还没画", 不是"新旧两帧混在一起"。
#   ★根治要改服务端/Mesa(给 GL 路径补围栏, 或服务端在拷前 glFinish 等价的同步);
#     本文件是【用户级绕法】: 让上屏走有围栏的那条路。
#
# ▌三种绕法(都实测 0 闪烁), 按开销从省到贵:
#   ① 应用自己有"纯 X 输出"开关     → VLC --vout=xcb_x11 (最省)
#   ② 应用自己有"Vulkan 输出"开关   → mpv --vo=gpu-next --gpu-api=vulkan --gpu-context=x11vk
#   ③ 应用只有 GL(没开关)           → MESA_LOADER_DRIVER_OVERRIDE=zink
#      (GL→Vulkan→Turnip, present 于是走带围栏的 Vulkan WSI; 只需 1 个环境变量, 应用无关)
#
# ▌:1 的额外约束
#   :1 的 Xtigervnc-dri3(9/23 版) 没注册 fd-fence 后端 → Vulkan 原生 present 直接失败(E-AA/E-BC)。
#   所以在 VNC 上用 Vulkan/zink 必须带 MESA_VK_WSI_DEBUG=sw(改走 MIT-SHM 呈现)。
#   startvnc 已经为 :1 会话设了这个变量, 本文件再兜一次, 保证从任意 shell 起也对。
#   :2(Termux:X11/Xlorie) 有 fd-fence 后端, Vulkan 原生 DRI3 就是干净的, 不要设 sw(会变慢)。
#
# ▌API(source 本文件不改变当前环境, 只定义函数)
#   present_policy_disp             回显归一化 display(":1.0" → ":1")
#   present_policy_server           回显 "vnc" / "x11"(按 X vendor string 判, 可用 PRESENT_SERVER 覆盖)
#   present_policy_env              设该 display 上"Vulkan 可用"的最小环境(VNC 上 = WSI sw)
#   present_policy_gl_safe          ★绕法③: 把 GL 切到 zink(给没有 vo 开关的 GL 应用)
#   present_policy_args <mpv|vlc>   回显该应用应追加的命令行参数(空格分隔, 可能为空)
#
# ▌关总开关: PRESENT_POLICY=0   (所有函数变空操作, 回到系统默认行为)
#
# ▌实测数据(素材 1080p h264 23.976fps; 每组 ≥120 张抓样; "闪烁事件" = 整帧黑+大块黑+小块黑+大块白)
#   显示 应用/路径                              闪烁事件  画面速率  应用CPU  Xserver
#   :1   mpv vo=gpu/opengl/x11egl (kgsl)         29/120   24.4      28%     16%   ← 修前(旧包装选的就是这条)
#   :1   mpv vo=gpu-next/vulkan/x11vk + WSI sw    0/120   22.5      24%     18%   ← ★选它
#   :1   mpv vo=gpu/opengl + zink + WSI sw        0/120   24.0      39%     23%
#   :1   mpv vo=x11(纯软件)                       0/120   24.0      41%      6%
#   :1   VLC --vout=gl                            0/120   23.9      55%     13%
#   :1   VLC --vout=xcb_x11                       0/120   24.0      22%     17%   ← ★选它
#   :2   mpv vo=gpu/opengl/x11egl (kgsl)         33/120   (黑)      18%      —    ← 修前
#   :2   mpv vo=gpu-next/vulkan/x11vk             0/120   23.9      16%      —    ← ★选它
#   :2   mpv vo=gpu/opengl + zink                 0/120   23.9      21%      —
#   :2   VLC --vout=gl                            0/120   24.0      78%      —    (但 15/120 帧原地不动)
#   :2   VLC --vout=xcb_x11                       0/120   23.9      35%      —    ← ★选它
#   :1/:2 深度影院(玲珑) 窗口/全屏                0/150   24.0   15~28%   0~26%  (本来就走 Vulkan, 无需改)
#
# ▌★修后验收(2026-09-26 晚, 真 :1 与真 :2, 每组连续抓样 320 张, 活体时钟 320/320 有效)
#   组             显示 实测路径(读 /proc/<pid>/{environ,maps,fd})        抽样 闪烁 速率  冻帧 CPU
#   mpv(包装)      :1  Vulkan x11vk + WSI=sw, kgsl-fd 1                   320  ★0  24.0  0   —
#   mpv(包装)      :2  Vulkan x11vk 原生DRI3(WSI=∅), libvulkan_freedreno  320  ★0  23.9  0   25%
#   VLC(包装)      :1  xcb_x11, kgsl-fd 0, 只映射 libavcodec              320  ★0  24.0  0   19%
#   VLC(包装)      :2  xcb_x11, kgsl-fd 0, 只映射 libavcodec              320  ★0  23.9  0   43%
#   深度影院 全屏  :1  Vulkan + WSI=sw, kgsl-fd 1 (2504x1152)             320  ★0  23.9  0   31%
#   深度影院 全屏  :2  Vulkan 原生 DRI3, kgsl-fd 1 (1280x1024)            320  ★0  24.0  0   19%
#   麒麟影院 全屏  :2  zink(本文件绕法③), kgsl-fd 1                       320  ★0   —    —   18%
#      └ 同条件修前(PRESENT_POLICY=0 → kgsl GL): ★整帧黑 74/320 + 撕裂 10 + 码倒退 19
#   麒麟影院       :1  ★未通过: 有 CPU(30%)有 Vulkan 但【一帧都不上屏】(320 张逐字节全同, 唯一色 89)
#                      → 属另一个 bug, 不是闪烁; 见 wip/video.20260926/ledger.txt S23。:1 上暂不推荐用麒麟。
#
# ▌★VLC 的"区块刷新"其实是重复帧, 不是黑块(修前实测, :1 GL 路径 320 张):
#   72/320 帧【帧号原地不动】+ 14 次相邻抓图逐字节相同, CPU 64%(xcb_x11 是 19%)。换 xcb_x11 后全部归零。
#
# ▌CPU% 的可比性警告: 本机 7 核上同时跑多个子代理, 单线程负载会被调度器挪到中小核(cpu4/5 约
#   1.8~2.2GHz)而非大核(cpu6/7 约 3.5~3.8GHz), 同一段纯算术基准实测会差 2.2 倍。
#   → 上面的 CPU% 只能比【数量级】(如 64% vs 19%), 不能比 5% 级差异。闪烁事件数是整数计数, 不受影响。
# ▌:2 的 Xserver CPU 量不到(表里留空): :2 的 X server 在宿主 Android App 里, proot 内没有它的
#   /proc 项 —— 这是"工具表达不了", 不是":2 服务端更省"。
# ══════════════════════════════════════════════════════════════════════════════

present_policy_disp() {
    local d=${DISPLAY:-}
    printf '%s' "${d%%.*}"
}

present_policy_server() {
    if [ -n "${PRESENT_SERVER:-}" ]; then printf '%s' "$PRESENT_SERVER"; return 0; fi
    if [ -n "${_PP_SERVER:-}" ]; then printf '%s' "$_PP_SERVER"; return 0; fi
    _PP_SERVER=''
    # 判据①(首选): X 扩展列表里有 TIGERVNC/VNC 就是 VNC。
    #   ★不能看 vendor string —— TigerVNC 与 Termux:X11 都报 "The X.Org Foundation"(2026-09-26 实测,
    #     :1 release 12101012 / :2 12101099, 只有扩展名能区分: :1 有 TIGERVNC, :2 没有)。
    if command -v xdpyinfo >/dev/null 2>&1; then
        case "$(xdpyinfo 2>/dev/null)" in
            *TIGERVNC*|*VNC-EXTENSION*) _PP_SERVER=vnc ;;
            '' ) : ;;
            *  ) _PP_SERVER=x11 ;;
        esac
    fi
    # 判据②(兜底, 纯 /proc 不连 X): 该 display 的服务端进程 exe 是不是 Xvnc/Xtigervnc
    if [ -z "$_PP_SERVER" ]; then
        local n p e c
        n=$(present_policy_disp); n=${n#:}
        _PP_SERVER=x11
        for p in /proc/[0-9]*; do
            e=$(readlink "$p/exe" 2>/dev/null) || continue
            case "$e" in
                */Xtigervnc*|*/Xvnc)
                    c=$( { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null)
                    case " $c " in *" :$n "*) _PP_SERVER=vnc; break ;; esac ;;
            esac
        done
    fi
    printf '%s' "$_PP_SERVER"
}

present_policy_env() {
    [ "${PRESENT_POLICY:-1}" = 0 ] && return 0
    # VNC(Xtigervnc-dri3) 上 Vulkan 原生 present 会失败 → 必须走 MIT-SHM 呈现
    if [ "$(present_policy_server)" = vnc ]; then
        export MESA_VK_WSI_DEBUG=sw
    fi
    return 0
}

present_policy_gl_safe() {
    [ "${PRESENT_POLICY:-1}" = 0 ] && return 0
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export LIBGL_ALWAYS_SOFTWARE=0
    present_policy_env
    return 0
}

present_policy_args() {
    [ "${PRESENT_POLICY:-1}" = 0 ] && return 0
    case "$1" in
        mpv) printf '%s' '--vo=gpu-next --gpu-api=vulkan --gpu-context=x11vk' ;;
        vlc) printf '%s' '--vout=xcb_x11' ;;
        *)   : ;;
    esac
    return 0
}
