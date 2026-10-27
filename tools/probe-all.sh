#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# probe-all.sh —— 本地并发诊断(不消耗 API, 结果汇总一次看完)
# 用法: probe-all.sh            跑全部探针
#       probe-all.sh <名字>     只跑某一个(名字见下面 PROBES)
#       probe-all.sh --list     列出所有探针
#
# 设计要点:
#   · 每个探针是独立函数, 输出写到 /tmp/probe-out/<名字>.txt, 最后统一汇总
#   · 全部只读, 不改任何文件, 不装任何东西
#   · 并发跑(& + wait), 但有并发上限避免把手机拖死
#   · ★所有 pkill/pgrep 一律用方括号写法, 防止匹配到自己 shell(踩过 exit 144)
#   · ★不做全盘 find(会卡死 proot), 一律 bounded(-maxdepth)
# ════════════════════════════════════════════════════════════════════════════
set -u
OUT="${PROBE_OUTDIR:-/tmp/probe-out}"
MAXJOBS=6

PROBES="gl_paths vk_present displays apps_entry overlay_shims locale_l10n spark_store linglong services vnc_state electron_hooks aria2 disk_pkg"

# ── 小工具 ──
sec() { printf '\n--- %s ---\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
# 按 DISPLAY 取某进程的环境变量(本机 ps 不可用, 只能走 /proc)
env_of_display() {   # $1=display, $2=进程名关键字
  local p c dp
  for p in /proc/[0-9]*; do
    c=$( { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
    case "$c" in *"$2"*) ;; *) continue ;; esac
    dp=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
    [ "$dp" = "$1" ] && { tr '\0' '\n' < "$p/environ" 2>/dev/null; return; }
  done
}

# vblank_mode 与 gpu.sh / startvnc 保持一致用 0: 3 会把 kgsl 原生路径锁在刷新率上(glmark2-es2 119 vs 1750, 见 gpu.sh 注释)
GPU_ENV="MESA_LOADER_DRIVER_OVERRIDE=kgsl VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json EGL_PLATFORM=x11 TU_DEBUG=noconform vblank_mode=0"

# ════════ 探针定义 ════════

probe_gl_paths() {
  echo "目的: 确认 :1 / :2 上 GL 两条路(kgsl 原生 vs zink 默认)各自表现"
  for d in :1 :2; do
    [ -e "/tmp/.X11-unix/X${d#:}" ] || { echo "  [$d] socket 不存在, 跳过"; continue; }
    sec "$d  kgsl 原生"
    timeout 25 env DISPLAY=$d $GPU_ENV glxinfo -B 2>&1 \
      | grep -iE 'renderer string|Accelerated|direct rendering|^MESA.*error' | sed 's/^/    /'
    sec "$d  默认(不设 override, 通常= zink)"
    timeout 25 env DISPLAY=$d VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json glxinfo -B 2>&1 \
      | grep -iE 'renderer string|Accelerated|direct rendering|^MESA.*error' | head -6 | sed 's/^/    /'
    sec "$d  glxgears 5s (退出码 124=成功跑满)"
    timeout 5 env DISPLAY=$d $GPU_ENV glxgears >/dev/null 2>&1
    echo "    退出码 $?"
  done
}

probe_vk_present() {
  echo "目的: Vulkan 驱动层 vs X11 present 分开验(账本判定红线: 能枚举 ≠ 能 present)"
  sec "驱动枚举(env -u DISPLAY, 不建 surface)"
  timeout 25 env -u DISPLAY VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
    vulkaninfo --summary 2>&1 | grep -iE 'deviceName|driverID|apiVersion|driverName|Failed' | head -6 | sed 's/^/    /'
  for d in :1 :2; do
    [ -e "/tmp/.X11-unix/X${d#:}" ] || continue
    sec "$d  vkcube 5s (124=成功, 134=SIGABRT)"
    if have vkcube; then
      timeout 5 env DISPLAY=$d $GPU_ENV vkcube >/tmp/probe-vkcube-$d.log 2>&1
      echo "    退出码 $?"
      grep -iE 'error|swapchain|failed' /tmp/probe-vkcube-$d.log 2>/dev/null | head -4 | sed 's/^/      /'
    else echo "    vkcube 未安装"; fi
  done
}

probe_displays() {
  echo "目的: 两套 display 的存活与会话状态"
  sec "X socket"
  ls -la /tmp/.X11-unix/ 2>/dev/null | sed 's/^/    /'
  for d in :1 :2; do
    sec "$d 上的会话/窗管/合成器"
    for p in /proc/[0-9]*; do
      c=$( { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
      [ -n "$c" ] || continue
      dp=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
      [ "$dp" = "$d" ] || continue
      case "$c" in
        *xfce4-session*|*xfwm4*|*xfdesktop*|*xfce4-panel*|*picom*|*Xtigervnc*|*plank*)
          printf '    pid=%-7s %s\n' "${p#/proc/}" "$(echo "$c" | cut -c1-60)" ;;
      esac
    done
    sec "$d 窗口列表"
    have wmctrl && timeout 10 env DISPLAY=$d wmctrl -lx 2>&1 | head -12 | sed 's/^/    /' || echo "    (无 wmctrl)"
  done
  sec "picom 配置后端"
  grep -m1 '^backend' /root/.config/picom.conf 2>/dev/null | sed 's/^/    /'
}

probe_apps_entry() {
  echo "目的: 关键应用入口指向哪 + 用户级 override 现状"
  sec "用户级 override (/root/.local/share/applications)"
  for f in /root/.local/share/applications/*.desktop; do
    [ -f "$f" ] || continue
    printf '    %-45s %s\n' "$(basename "$f")" "$(grep -m1 '^Exec=' "$f" | sed 's/^Exec=//' | cut -c1-70)"
  done
  sec "几个关键命令解析到哪"
  for c in vlc firefox mpv spark-store linglong-store lx-music-desktop electron-wrap; do
    printf '    %-20s -> %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo '(无)')"
  done
  sec "Firefox 三个二进制是否存在"
  for b in /opt/firefox/firefox-bin /opt/apps/firefox-spark/files/firefox/firefox-bin /usr/lib/firefox-esr/firefox-esr; do
    printf '    %s : %s\n' "$([ -x "$b" ] && echo 有 || echo 缺)" "$b"
  done
  sec "VLC 现状"
  printf '    /usr/bin/vlc: %s\n' "$([ -x /usr/bin/vlc ] && echo 有 || echo 缺)"
  timeout 10 /usr/bin/vlc --version 2>&1 | head -3 | sed 's/^/      /'
}

# ── U11: 覆盖式垫片断言（只读，不改 PATH、不执行被测命令） ──
# 后两个参数是允许的入口目录；生产调用固定用户 bin 与兼容 bin。
# 除入口目录外还核对最终本体，防止“位置对但软链被包更新指回裸程序”。
check_overlay_entry() {
  local name="$1" body="$2" user_bin="$3" compat_bin="$4" entry actual
  entry=$(command -v "$name" 2>/dev/null) || entry=""
  if [ -z "$entry" ]; then
    printf '[FAIL] %s: 当前 PATH 找不到命令\n' "$name"
    return 1
  fi
  if [ "$entry" != "$user_bin/$name" ] && [ "$entry" != "$compat_bin/$name" ]; then
    printf '[FAIL] %s: 解析到 %s，绕过用户垫片\n' "$name" "$entry"
    return 1
  fi
  actual=$(/usr/bin/readlink -f -- "$entry" 2>/dev/null) || actual=""
  if [ ! -x "$entry" ] || [ "$actual" != "$body" ]; then
    printf '[FAIL] %s: %s -> %s；预期 %s\n' "$name" "$entry" "${actual:-<断链>}" "$body"
    return 1
  fi
  printf '[OK] %s: %s -> %s\n' "$name" "$entry" "$actual"
}

# ★2026-10-06 扩面(U11 第二棒): 原来只列了 SHIM_OF 里"双落点"的 6 项, 但用一次【真的 PATH 全扫】
#   (wip/localbin2.20261003/scan-overlay-shims*.sh: 遍历 PATH 各目录, 找同名命令出现 >=2 次
#   且 readlink -f 本体不同者) 查出【12 项】是覆盖式, 而且漏掉的那 6 项恰恰是【只有一个落点】的
#   —— 它们比 pkexec 更脆: pkexec 在 /root/.local/bin 和 /usr/local/bin 各有一份, 坏一个还有另一个;
#   单落点的那些, /root/.local/bin 一旦掉出 PATH 就【直接静默退回系统原程序】, 毫无冗余。
#   所以断言必须覆盖单落点组, 否则防的是最不容易坏的那个。
#   不列入的只有 Xtigervnc(/usr/local/bin 的真文件遮 /usr/bin/Xtigervnc) —— 那是 VNC 自编版本
#   的有意覆盖, 不是用户级垫片, 不归本断言管。
#   aptss / ssinstall / spark-store / apm 也不在此列: 它们的系统入口【本身就指同一个垫片】,
#   不靠 PATH 顺序取胜, 属 relink.sh 自愈范围(见 ~/.local/lib/spark-shim/relink.sh)。
OVERLAY_DUAL="pkexec deepin-music firefox linglong-store lx-music-desktop vlc"
OVERLAY_SOLO="deepin-movie kylin-video-new mpv xfconf-query thunar Thunar"
overlay_body_of() {   # 名字 -> 期望本体
  case "$1" in
    pkexec)           printf '%s' /root/.local/lib/pkexec-shim/pkexec ;;
    deepin-music)     printf '%s' /root/.local/lib/deepin-music-shim/deepin-music-wrap.sh ;;
    firefox)          printf '%s' /root/.local/lib/firefox-shim/firefox-wrap.sh ;;
    linglong-store)   printf '%s' /root/.local/lib/linglong-shim/linglong-wrap.sh ;;
    lx-music-desktop) printf '%s' /root/.local/lib/lx-music-shim/lx-music-wrap.sh ;;
    vlc)              printf '%s' /root/工具箱/sh/vlc-wrap.sh ;;
    deepin-movie)     printf '%s' /root/.local/lib/desktop-shim/deepin-movie-wrap.sh ;;
    kylin-video-new)  printf '%s' /root/工具箱/sh/kylin-video-wrap.sh ;;
    mpv)              printf '%s' /root/工具箱/sh/mpv-wrap.sh ;;
    xfconf-query)     printf '%s' /root/工具箱/sh/xfconf-safe.sh ;;
    thunar|Thunar)    printf '%s' /root/.local/lib/thunar-shim/thunar ;;
    *)                printf '' ;;
  esac
}

probe_overlay_shims() {
  printf '目的: 检查当前 PATH 是否仍命中覆盖式垫片及正确本体\n'
  local name body failed=0 total=0
  sec "PATH 顺序(覆盖式垫片的命门; /root/.local/bin 必须在 /usr/bin 之前)"
  printf '    %s\n' "$PATH"
  case ":$PATH:" in
    *:/root/.local/bin:*) : ;;
    *) printf '[FAIL] PATH 里根本没有 /root/.local/bin —— 所有用户级垫片都已失效\n'; failed=$((failed+1)) ;;
  esac

  sec "双落点组(/root/.local/bin + /usr/local/bin 各一份, 坏一个还有冗余)"
  for name in $OVERLAY_DUAL; do
    total=$((total+1)); body=$(overlay_body_of "$name")
    check_overlay_entry "$name" "$body" /root/.local/bin /usr/local/bin || failed=$((failed+1))
  done

  sec "单落点组(只有 /root/.local/bin 一份, ★无冗余, 最脆)"
  for name in $OVERLAY_SOLO; do
    total=$((total+1)); body=$(overlay_body_of "$name")
    check_overlay_entry "$name" "$body" /root/.local/bin /usr/local/bin || failed=$((failed+1))
  done

  printf '\n覆盖式垫片: %s 项，失败 %s 项\n' "$total" "$failed"
  if [ "$failed" -ne 0 ]; then
    printf '★ 覆盖式垫片靠 PATH 顺序取胜, FAIL 多半是 PATH 被改动(谁把 /usr/bin 提前了)。\n'
    printf '  查: ~/.bashrc:105 的 export PATH, 以及 Termux 侧 /root/Termux目录/start.sh 传进来的 PATH。\n'
  fi
  [ "$failed" -eq 0 ]
}
# ── U11 结束 ──

probe_locale_l10n() {
  echo "目的: 汉化现状(locale + 各应用 zh_CN 翻译文件在不在)"
  sec "locale"
  { locale; echo "LANG=$LANG"; } 2>/dev/null | head -8 | sed 's/^/    /'
  sec "已装语言包"
  dpkg -l 2>/dev/null | awk '$1=="ii" && ($2 ~ /language-pack|locales|l10n/){print "    "$2" "$3}' | head -15
  sec "zh_CN 翻译文件数量(/usr/share/locale/zh_CN/LC_MESSAGES)"
  ls /usr/share/locale/zh_CN/LC_MESSAGES/ 2>/dev/null | wc -l | sed 's/^/    共 /'
  sec "常用应用有没有 zh_CN .mo"
  for m in xfce4-panel thunar mousepad xfce4-terminal xfdesktop xfwm4 xfce4-settings vlc firefox thunar-volman ristretto xarchiver; do
    f=$(ls /usr/share/locale/zh_CN/LC_MESSAGES/ 2>/dev/null | grep -m1 -iE "^${m}(\.|-)" )
    printf '    %-22s %s\n' "$m" "${f:-✘ 无}"
  done
}

probe_spark_store() {
  echo "目的: 星火商店可用性 + 我加的钩子是否还在"
  sec "主程序与安装器"
  # ★2026-09-28 改: 真入口已搬到 /root/.local/bin/spark-store(PATH 第 1 位), 本体是
  #   ~/.local/lib/spark-shim/spark-store-wrap.sh(4533B)。原来只探 /usr/local/bin/spark-store,
  #   而那个路径今天被一次误还原塞回了 09-24 的【旧壳】(2046B) —— 探针于是"误报通过、且测的是旧壳",
  #   比报"没装"更坏。新入口排第一位; 旧路径仍列出但标注它可能是旧壳。
  for b in /root/.local/bin/spark-store /root/.local/lib/spark-shim/spark-store-wrap.sh /usr/local/bin/spark-store /opt/spark-store/bin/spark-store /usr/bin/ssinstall /usr/bin/aptss /usr/local/bin/apm; do
    printf '    %s : %s\n' "$([ -e "$b" ] && echo 有 || echo 缺)" "$b"
  done
  sec "★spark-store 真正解析到哪(PATH 第 1 位优先)"
  printf '    command -v spark-store -> %s\n' "$(command -v spark-store 2>/dev/null || echo 无)"
  for b in /root/.local/bin/spark-store /root/.local/lib/spark-shim/spark-store-wrap.sh /usr/local/bin/spark-store; do
    [ -e "$b" ] || continue
    printf '    %-52s %6s字节  md5=%.8s%s\n' "$b" "$(stat -Lc %s "$b" 2>/dev/null)" \
      "$(md5sum < "$b" 2>/dev/null)" "$([ -L "$b" ] && echo "  → $(readlink "$b")")"
  done
  echo "    ※ /usr/local/bin/spark-store 若是 2046B 且自述 2026-09-24, 那是旧壳(见账本 E-EJ), 不是现行本体"

  sec "/usr/bin/ssinstall 是我的包装还是符号链接"
  head -4 /usr/bin/ssinstall 2>/dev/null | sed 's/^/    /'
  sec "真身未被改动核验"
  dpkg -V spark-store 2>&1 | head -6 | sed 's/^/    /'
  sec "aria2 配置(默认路径必须为空, 否则一次性下载会进 RPC 模式)"
  printf '    默认路径 ~/.aria2/aria2.conf : %s\n' "$([ -f /root/.aria2/aria2.conf ] && echo '✘ 还在(会坏事)' || echo '✔ 已移走')"
  printf '    AriaNg 专用 ariang-rpc.conf : %s\n' "$([ -f /root/.aria2/ariang-rpc.conf ] && echo 在 || echo 缺)"
  sec "最近的星火日志报错"
  grep -iE 'error|failed|失败' /tmp/spark-store.log 2>/dev/null | tail -6 | sed 's/^/    /'
}

probe_linglong() {
  echo "目的: 玲珑商店 shim 与运行前提"
  sec "shim"
  printf '    command -v linglong-store -> %s\n' "$(command -v linglong-store 2>/dev/null || echo 无)"
  grep -m1 FLUTTER_LINUX_RENDERER /usr/local/bin/linglong-store 2>/dev/null | sed 's/^/    /'
  sec "真身与框架标记"
  printf '    %s : /opt/linglong-store/linglong_store\n' "$([ -x /opt/linglong-store/linglong_store ] && echo 有 || echo 缺)"
  find /opt/linglong-store -maxdepth 3 \( -name 'libflutter_linux_gtk.so' -o -name 'flutter_assets' -o -name 'libapp.so' \) 2>/dev/null | sed 's/^/    /'
  sec "ll-cli 与 bwrap(装应用的前提)"
  printf '    ll-cli : %s\n' "$(command -v ll-cli 2>/dev/null || echo '✘ 未装')"
  printf '    linglong-bin dpkg 状态: %s\n' "$(dpkg -l linglong-bin 2>/dev/null | awk '/linglong-bin/{print $1}' | head -1)"
  echo "    bwrap 实测:"; timeout 8 bwrap --dev-bind / / true 2>&1 | head -2 | sed 's/^/      /'
  sec "桌面会话的 PATH(决定点图标会不会走 shim)"
  env_of_display :2 xfce4-session | sed -n 's/^PATH=//p' | tr ':' '\n' | grep -n . | head -8 | sed 's/^/    /'
}

probe_services() {
  echo "目的: 音频/电池/DBus 等后台链路"
  sec "音频"
  timeout 10 pactl info 2>&1 | grep -iE '服务器字串|服务器协议版本|程序库协议|拒绝|refuse|Server Name|Server Version|Connection refused' | sed 's/^/    /'
  printf '    4713 端口: %s\n' "$(timeout 5 bash -c 'echo > /dev/tcp/127.0.0.1/4713' 2>/dev/null && echo 可连 || echo '✘ 连不上')"
  timeout 10 pactl list short sinks 2>&1 | head -3 | sed 's/^/    sink: /'
  sec "电池(fake-upowerd + battery.json)"
  printf '    fake-upowerd: %s\n' "$(pgrep -f '[f]ake-upowerd\.py' >/dev/null && echo 运行中 || echo '✘ 没跑')"
  printf '    /tmp/battery.json: %s\n' "$([ -f /tmp/battery.json ] && echo "有 ($(stat -c %y /tmp/battery.json 2>/dev/null | cut -d. -f1))" || echo 缺)"
  have upower && timeout 10 upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>&1 | grep -iE 'percentage|state' | sed 's/^/    /'
  sec "DBus"
  printf '    system bus socket: %s\n' "$([ -S /run/dbus/system_bus_socket ] && echo 有 || echo 缺)"
  sec "power-stack 状态"
  [ -x /root/.local/bin/power-stack.sh ] && timeout 15 /root/.local/bin/power-stack.sh status 2>&1 | head -10 | sed 's/^/    /'
}

probe_vnc_state() {
  echo "目的: VNC 改造后的实际状态"
  sec "启动脚本用的是哪个 Xvnc"
  grep -m2 -E 'XVNC_DRI3=|XVNC_SYS=' /usr/local/bin/startvnc 2>/dev/null | sed 's/^/    /'
  sec "两个脚本的默认分辨率"
  grep -H -m1 'VNC_GEOM:=' /usr/local/bin/startvnc /usr/local/bin/startvncs 2>/dev/null | sed 's/^/    /'
  sec "当前 :1 跑的二进制与参数"
  for p in /proc/[0-9]*; do
    c=$( { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
    case "$c" in *Xtigervnc*) echo "$c" | fold -w 95 | sed 's/^/    /';; esac
  done
  sec "各版本 Xvnc 版本串"
  for b in /usr/bin/Xtigervnc /usr/local/bin/Xtigervnc /usr/local/bin/Xtigervnc-dri3; do
    [ -x "$b" ] && printf '    %-38s %s\n' "$b" "$("$b" -version 2>&1 | head -1)"
  done
  sec "Xtigervnc-dri3 是否含 lorie 补丁符号"
  printf '    lorie* 符号数: %s\n' "$(nm -D /usr/local/bin/Xtigervnc-dri3 2>/dev/null | grep -ci lorie)"
  printf '    RAW_MMAPPABLE_FD 字符串: %s\n' "$(strings /usr/local/bin/Xtigervnc-dri3 2>/dev/null | grep -c RAW_MMAPPABLE_FD)"
  sec ":1 扩展(DRI3/GLX/Present 应为3)"
  [ -e /tmp/.X11-unix/X1 ] && timeout 15 env DISPLAY=:1 xdpyinfo 2>/dev/null | grep -cE '^    (DRI3|GLX|Present)$' | sed 's/^/    命中 /'
  sec "startvnc 日志尾部"
  tail -8 /root/.vnc/startvnc.log 2>/dev/null | sed 's/^/    /'
}

probe_electron_hooks() {
  echo "目的: Electron 自动补丁三层钩子是否都在"
  sec "组件"
  for b in /usr/local/bin/electron-wrap /usr/local/bin/electron-autopatch /usr/local/bin/electron-autopatch-hook; do
    printf '    %s : %s\n' "$([ -x "$b" ] && echo 有 || echo 缺)" "$b"
  done
  sec "三层钩子"
  printf '    ① APT  : %s\n' "$([ -f /etc/apt/apt.conf.d/99electron-autopatch ] && echo 有 || echo 缺)"
  printf '    ② ssinstall 包装: %s\n' "$(head -3 /usr/bin/ssinstall 2>/dev/null | grep -qi '包装' && echo 有 || echo 缺)"
  printf '    ③ autostart: %s\n' "$([ -f /root/.config/autostart/electron-autopatch.desktop ] && echo 有 || echo 缺)"
  sec "dpkg 层那个无效配置是否已改成注释"
  grep -c '^post-invoke' /etc/dpkg/dpkg.cfg.d/99-electron-autopatch 2>/dev/null | sed 's/^/    生效的 post-invoke 行数(应为0): /'
  sec "当前已套补丁的应用"
  timeout 60 /usr/local/bin/electron-autopatch --status 2>&1 | sed 's/^/    /'
}

probe_aria2() {
  echo "目的: aria2 解耦是否稳固(星火下载的根因)"
  sec "配置文件"
  ls -l /root/.aria2/*.conf 2>/dev/null | sed 's/^/    /'
  sec "startariang 指向"
  grep -m1 '^CONF=' /usr/local/bin/startariang 2>/dev/null | sed 's/^/    /'
  sec "默认路径跑一次(不应出现 RPC 监听)"
  timeout 8 aria2c --dry-run --no-conf=false -h >/dev/null 2>&1
  timeout 10 aria2c --version 2>&1 | head -1 | sed 's/^/    /'
  printf '    6801 端口: %s\n' "$(ss -tlnp 2>/dev/null | grep -c ':6801' || echo 0)"
}

probe_disk_pkg() {
  echo "目的: 磁盘与关键包状态"
  sec "磁盘"
  df -h / 2>/dev/null | sed 's/^/    /'
  sec "磁盘Mesa库版本（含回滚保留库；不等于应用实际加载版本）"
  for so in /usr/lib/aarch64-linux-gnu/libgallium-*.so /usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so; do
    [ -f "$so" ] && printf '    %-55s %s\n' "$(basename "$so")" "$(strings -a "$so" 2>/dev/null | grep -m1 -oE 'Mesa [0-9][^ ]*')"
  done
  sec "KGSL静态线索（字符串计数不能代替GPU绘制验证）"
  printf '    libvulkan_freedreno kgsl 命中: %s\n' "$(strings /usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so 2>/dev/null | grep -ic kgsl)"
  printf '    kgsl_dri.so : %s\n' "$([ -f /usr/lib/aarch64-linux-gnu/dri/kgsl_dri.so ] && echo 有 || echo 缺)"
  sec "被 hold 的包"
  apt-mark showhold 2>/dev/null | head -10 | sed 's/^/    /'
  sec "关键设备节点"
  for n in /dev/kgsl-3d0 /dev/dma_heap/system /dev/dri/renderD128; do
    if [ -e "$n" ]; then printf '    %-26s %s\n' "$n" "$(ls -l "$n" 2>/dev/null | awk '{print $1}')"
    else printf '    %-26s 不存在\n' "$n"; fi
  done
}

# ════════ 调度 ════════
case "${1:-}" in
  --list) echo "可用探针:"; for p in $PROBES; do echo "  $p"; done; exit 0 ;;
  # 单项断言直接返回状态码；不启动 GUI，也不生成 /tmp 诊断文件。
  overlay_shims) probe_overlay_shims; exit $? ;;
  "") TARGETS="$PROBES" ;;
  *) TARGETS="$1" ;;
esac
mkdir -p "$OUT"

echo "并发诊断开始 (上限 ${MAXJOBS} 个) …"
n=0
for p in $TARGETS; do
  { echo "════════ [$p] ════════"; "probe_$p" 2>&1; } > "$OUT/$p.txt" &
  n=$((n+1))
  [ $((n % MAXJOBS)) -eq 0 ] && wait
done
wait

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    诊断汇总                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
for p in $TARGETS; do [ -f "$OUT/$p.txt" ] && cat "$OUT/$p.txt"; done
echo
echo "(单项重跑: probe-all.sh <名字>;  原始输出在 $OUT/)"
