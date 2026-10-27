#!/usr/bin/env bash
# 02-rootfs-setup.sh —— 【proot Ubuntu 内】新机一键重建 第 2 步
# 幂等: 可重复执行; 每步都先备份再改。
# 用法: bash /root/deploy/rootfs/02-rootfs-setup.sh [--skip-gpu] [--skip-apps] [--force-rebuild]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BK=/root/工具箱/backup
TS=$(date +%Y%m%d_%H%M%S)
SKIP_GPU=0; SKIP_APPS=0
FORCE_REBUILD="${FORCE_REBUILD:-0}"
for a in "$@"; do case "$a" in
  --skip-gpu) SKIP_GPU=1;;
  --skip-apps) SKIP_APPS=1;;
  --force-rebuild) FORCE_REBUILD=1;;
esac; done

mkdir -p "$BK" /root/工具箱/sh /root/账本
say() { echo; echo "==> $*"; }
bk()  { [ -f "$1" ] && cp -p "$1" "$BK/$(basename "$1").$TS" && echo "   备份: $1"; }


# ★★2026-09-29 加通用护栏 safe_install(): 本脚本是【换新机恢复盘】, 不是日常同步工具。
#   在【已有内容的活机器上】跑它, 等于用仓库旧快照把现盘的新版整份盖掉。
#   实撞两次: 2026-09-28 10:11 一次性打掉 8 个文件(三份账本 + relay-switch/relay-watch/
#   regression-test + /etc/profile.d/00-clean-tmp.sh + /usr/local/bin/spark-store 旧壳复活)。
#   射程逐行核过(行号为 2026-09-29 当时的): 行 62/77/89 覆盖
#   /etc/profile.d/{10-gpu,20-runtime,30-display}.sh ·
#   行 118 覆盖 startvnc/startvncpc/stopvnc · 行 122 覆盖 .vnc/xstartup ·
#   ★行 128 `install "$REPO"/tools/*.sh → /root/工具箱/sh/` = 整个 sh 目录都在射程内。
#     【★★此行已作废, 行号与写法都错, 见下面 2026-10-05 更正。保留原文只为让更正有对照。】
#   ※ 2026-10-03: 写 /etc/profile.d 那三段已【整段删除】(见下文 [2/6] 之后那段说明),
#     所以射程里 profile.d 那三项已不复存在; 其余各项仍然有效。
#   ★★2026-10-05 更正上面那行"★行 128": 行号与写法都已过期, 别照着找 ——
#     · 行 128 现在是【缺包计数】那一行, 跟 工具箱/sh 一点关系都没有。
#       行号是被 2026-10-03 的 commit 4689c4a(删掉 [3/9][4/9][5/9] 三段)挤走的。
#     · 真身在 [4/6] 段 —— ★这里【故意不写行号】, 用可搜索锚点代替:
#         grep -n 'say "\[4/6\]' 本文件          → 段首
#         grep -n 'for _t in "\$REPO"/tools' 本文件 → 那个循环本体
#         循环内容: for _t in "$REPO"/tools/*.sh "$REPO"/tools/*.py; do safe_install ... done
#       (不写行号的理由见本段末尾的方法论: 我写这段更正时加了 15 行注释,
#        当场就把自己刚写下的"行 246/248"挤成了 261/263 —— 行号这种引用天生会烂。)
#     · 写法也变了两处: ① 不是裸 install 而是走 safe_install(有护栏);
#                       ② 范围已从 *.sh 扩到 *.sh + *.py(所以 redact_transcript.py 等也在射程内)。
#     ⇒ 结论没变(整个 sh 目录都在射程内), 变的是"怎么在射程内":
#       活机器上现盘更新【会跳过并提示, 不会被覆盖】; 真正会丢现役修复的只有两种场合 ——
#       (i) 换新机重建(现盘根本不存在 → 直接装仓库那份) (ii) FORCE_OVERWRITE=1。
#     ⇒ 所以"仓库副本比现役旧"的正确读法是【下一轮重建会降级】, 不是【现在就会被覆盖】。
#   ★方法论(2026-10-05 用户定): "某文件某行会做某事"这类论断, 写进永久账本之前必须
#     【打开那一行看过】—— 行号会随改动漂移, 转述会失真, 账本里的错误机制会误导后续所有排障。
#     本条就是实例: 上面"行 128"那句被原样转述进 已验证事实.txt:2184, 又被我转述出去,
#     直到有人去核源码才拦下来。
#   判据 = 【现盘 mtime 是否比仓库那份新】。新机上现盘不存在 → 装; 活机器上现盘更新 → 跳过并提示。
#   FORCE_OVERWRITE=1 可强制覆盖(换机重建时用)。
safe_install() {   # $1=源(仓库内)  $2=目标  [$3=mode, 默认 700]
  local src="$1" dst="$2" mode="${3:-700}" tmp
  if [ -L "$src" ] || [ -L "$dst" ]; then
    echo "   ! 拒绝通过软链恢复: $src -> $dst" >&2
    return 1
  fi
  [ -f "$src" ] || return 0
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    echo "   ! 目标不是普通文件: $dst" >&2
    return 1
  fi
  if [ "${FORCE_OVERWRITE:-0}" != 1 ] && [ -f "$dst" ]; then
    # 相同内容优先于mtime判断，避免重复恢复制造无意义备份。
    if cmp -s "$src" "$dst"; then
      echo "   = $(basename "$dst") 内容一致, 跳过"
      return 0
    fi
    if [ "$dst" -nt "$src" ]; then
      echo "   · 跳过 $(basename "$dst") —— 现盘比仓库新且内容不同, 绝不覆盖"
      echo "       要对比: diff \"$dst\" \"$src\""
      return 0
    fi
  fi
  # install只写同目录临时文件；编写或备份失败时不触碰旧目标。
  tmp="$(mktemp "${dst}.restore.XXXXXXXX")" || return 1
  if ! install -m "$mode" -- "$src" "$tmp"; then
    rm -f -- "$tmp"
    echo "   ! 恢复写入失败，旧文件保留: $dst" >&2
    return 1
  fi
  if [ -f "$dst" ] && ! bk "$dst"; then
    rm -f -- "$tmp"
    echo "   ! 备份失败，旧文件保留: $dst" >&2
    return 1
  fi
  if ! mv -fT -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    echo "   ! 发布恢复文件失败: $dst" >&2
    return 1
  fi
  echo "   + $(basename "$dst") (精确快照已还原)"
}

# 不生成强制GPU参数或简化配置：使用已采集的精确用户配置和菜单入口。
restore_mpv_user_files() {
  local repo="$1" user_root="$2" config desktop
  config="$repo/files/config/mpv.conf"
  desktop="$repo/files/local-share-applications/mpv.desktop"
  [ -f "$desktop" ] || desktop="$repo/files/desktop/mpv.desktop"
  if [ ! -f "$config" ] || [ ! -f "$desktop" ]; then
    echo "   ! 缺mpv配置或菜单快照；没有写入硬编码默认值" >&2
    return 1
  fi
  mkdir -p "$user_root/.config/mpv" "$user_root/.local/share/applications" || return 1
  safe_install "$config" "$user_root/.config/mpv/mpv.conf" 644 || return 1
  safe_install "$desktop" "$user_root/.local/share/applications/mpv.desktop" 644 || return 1
}

# 同理: 用 cat > 写死内容的那几个 /etc/profile.d —— 现盘存在且被改过就别盖
# ★2026-10-03 起【当前无调用点】: 它唯一服务的 [3/9][4/9][5/9] 三段已整段删除(原因见下)。
#   保留函数本体不删, 是因为将来若再有"用 cat > 写死内容到固定路径"的段落, 这是现成的正确写法;
#   但要知道它有个结构性短板: 第一行 `[ -e "$dst" ] || return 0` 意味着
#   【目标不存在时它一律放行】—— 对"本来就不该存在的文件"毫无防护力。
#   用它之前先确认: 目标文件在正常机器上【应该存在】, 否则这个护栏就是空的。
safe_write_guard() {  # $1=目标文件 → 0=可以写, 1=应跳过
  local dst="$1"
  [ -e "$dst" ] || return 0
  [ "${FORCE_OVERWRITE:-0}" = 1 ] && { bk "$dst"; return 0; }
  echo "   · 跳过 $(basename "$dst") —— 现盘已存在(可能被改过), 绝不覆盖; 要强制用 FORCE_OVERWRITE=1"
  return 1
}

# ★★2026-09-30 加【总闸】: 上面两个护栏是逐文件的, 管不到 [1/9] 装包 与 [2/9] 解 Mesa。
#   [2/9] 的 `tar -zxf "$PKG" -C /` 是【整棵树覆盖 /usr/lib 等系统目录】, 外加 apt-mark hold
#   与写 /etc/apt/preferences.d/99-mesa-lock —— 在【已经建好的活机器上】跑, 等于拿仓库里钉死的
#   旧版 Mesa($MESA_VER) 盖掉现役驱动, 而且 tar 覆盖没有 cmp/mtime 那种逐文件退让余地。
#   [1/9] 的 apt-get install 则是无条件的, 在活机器上会多跑一遍 update+install。
#
#   ★判据不能用"/etc/profile.d/10-gpu.sh 是否存在":
#     2026-09-30 实测本机 /etc/profile.d/ 下【根本没有】10-gpu.sh —— 本项目早就把 GPU/runtime/
#     display 环境收敛进 ~/.config/desktop-env/*.sh(由 .bashrc / startvnc / startx11 source)。
#     照那个判据写, 护栏会在这台已配好的机器上【判假不触发】, 等于白加。
#   ⇒ 改用【现役驱动自证】: vulkaninfo 能报出 Adreno + turnip/freedreno ⇒ 容器版 Mesa 已在岗;
#     再要求 GPU 环境变量确有落点(两种形态任一: /etc/profile.d/10-gpu.sh 或 desktop-env/gpu.sh)。
#   ⇒ 新机(全空)必定为假, 照常执行: vulkan-tools 还没装(命令不存在) / freedreno ICD 文件不存在 /
#     vulkaninfo 只报 llvmpipe —— 任何一条不满足就返回 1。
#   解闸: FORCE_OVERWRITE=1 或 --force-rebuild(换机重建 / 要升 Mesa 版本时用)。

force_on() { [ "${FORCE_OVERWRITE:-0}" = 1 ] || [ "$FORCE_REBUILD" = 1 ]; }

container_mesa_live() {   # 0=现役已是容器版 Mesa  1=不是/测不出
  command -v vulkaninfo >/dev/null 2>&1 || return 1
  [ -f /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json ] || return 1
  local vi
  vi=$(env -u DISPLAY VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
         timeout 60 vulkaninfo --summary 2>/dev/null) || return 1
  printf '%s' "$vi" | grep -qi 'Adreno'                        || return 1
  printf '%s' "$vi" | grep -qiE 'turnip|freedreno|MESA_TURNIP' || return 1
  return 0
}

gpu_env_present() {  # GPU 环境变量有落点? 老形态 profile.d 与本项目现形态 desktop-env, 任一即可
  [ -f /etc/profile.d/10-gpu.sh ] || [ -f /root/.config/desktop-env/gpu.sh ]
}

already_built() { container_mesa_live && gpu_env_present; }

# [1/9] 专用: 判据和 GPU 段【分开】—— 装包缺不缺与驱动在不在岗是两回事。
# 列表必须与下面 apt-get install 那行【逐个对齐】: 只要缺一个就照常装(新机全缺 ⇒ 必跑)。
# ★例外 fonts-noto-cjk: 2026-09-30 实测本机【没装】这个包, 中文是靠 fonts-wqy-microhei +
#   fonts-droid-fallback 撑的(fc-list :lang=zh 有 3 条, 中文显示正常)。装它只是为了"有中文字体",
#   按包名死判会让 [1/9] 在这台机器上永远跳不掉、每次白跑一遍 apt。
#   ⇒ 这一个改判【能力】: 系统已有任意中文字体就算满足。其余包仍按包名严格判。
BASE_PKGS="xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common dbus-x11
locales curl wget python3 vulkan-tools mesa-utils pulseaudio-utils vlc mpv"
cjk_font_ok() {   # 0=系统已有中文字体
  command -v fc-list >/dev/null 2>&1 || return 1
  local n; n=$(fc-list :lang=zh 2>/dev/null | wc -l); n=${n:-0}
  [ "$n" -gt 0 ]
}
base_pkgs_missing() {   # 0=有缺(该装)  1=全齐(可跳)
  local p miss=0 st
  for p in $BASE_PKGS; do
    st=$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null); st=${st:-notinstalled}
    [ "$st" = installed ] || { echo "     缺包: $p"; miss=$((miss+1)); }
  done
  if ! cjk_font_ok; then echo "     缺中文字体(fonts-noto-cjk 或等效)"; miss=$((miss+1)); fi
  [ "$miss" -gt 0 ]
}

say "[1/6] 基础包"
export DEBIAN_FRONTEND=noninteractive
if ! base_pkgs_missing && ! force_on; then
  echo "   · 跳过 —— $(echo $BASE_PKGS | wc -w) 个基础包已【全部装齐】, 不再跑 apt-get update/install"
  echo "     (要强制重装: FORCE_OVERWRITE=1 或 --force-rebuild)"
else
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common dbus-x11 \
    fonts-noto-cjk locales curl wget python3 vulkan-tools mesa-utils \
    pulseaudio-utils vlc mpv 2>&1 | tail -3
  locale-gen zh_CN.UTF-8 >/dev/null 2>&1
fi

say "[2/6] GPU: Android 容器版 Mesa (带 KGSL 后端)"
if [ "$SKIP_GPU" = "1" ]; then
  echo "   已跳过(--skip-gpu)"
elif already_built && ! force_on; then
  echo "   · 跳过 GPU 段 —— 这台机器【已经建好了】, 不拿旧快照盖现役驱动:"
  echo "       现役: $(env -u DISPLAY VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
                timeout 60 vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | sed 's/^[[:space:]]*//')"
  echo "       env : $( [ -f /etc/profile.d/10-gpu.sh ] && echo /etc/profile.d/10-gpu.sh \
                || echo /root/.config/desktop-env/gpu.sh )"
  echo "     本段会做的事(全部跳过): tar -zxf mesa …-C /  ·  apt-mark hold  ·  写 /etc/apt/preferences.d/99-mesa-lock"
  echo "     要换机重建 / 升 Mesa 版本: FORCE_OVERWRITE=1 或 --force-rebuild"
  SKIP_GPU=1
else
  GPU_MODEL=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || echo "未知")
  echo "   本机 GPU: $GPU_MODEL"
  MESA_VER="${MESA_VER:-27.0.0-devel-20261025}"
  MESA_TAG="${MESA_TAG:-mesa-$MESA_VER}"
  PKG="mesa-for-android-container_${MESA_VER}_ubuntu_noble_arm64.tar.gz"
  URL="https://github.com/lfdevs/mesa-for-android-container/releases/download/$MESA_TAG/$PKG"
  mkdir -p /root/工具箱/mesa-aac && cd /root/工具箱/mesa-aac
  if [ ! -f "$PKG" ]; then echo "   下载 $PKG"; curl -fL --retry 2 -o "$PKG" "$URL" || { echo "   ✘ 下载失败, 跳过 GPU"; SKIP_GPU=1; }; fi
  if [ "$SKIP_GPU" != "1" ] && [ -s "$PKG" ]; then
    # Verify the exact tested Noble release before any extraction or backup mutation.
    MESA_EXPECTED_SHA256="${MESA_SHA256:-}"
    if [ -z "$MESA_EXPECTED_SHA256" ] && [ "$MESA_VER" = 27.0.0-devel-20261025 ] && [ "$MESA_TAG" = mesa-27.0.0-devel-20261025 ]; then
      MESA_EXPECTED_SHA256=0d3928ac6dd102c864311167c0585ce5632b2e4e456985d94b8ab9fdea2339f8
    fi
    case "$MESA_EXPECTED_SHA256" in
      ''|*[!0-9a-fA-F]*) echo '   ✘ 指定版本缺少有效MESA_SHA256，停止GPU恢复' >&2; exit 1 ;;
    esac
    [ "${#MESA_EXPECTED_SHA256}" -eq 64 ] || { echo '   ✘ MESA_SHA256长度无效' >&2; exit 1; }
    printf '%s  %s\n' "$MESA_EXPECTED_SHA256" "$PKG" | sha256sum --check --status || { echo '   ✘ Mesa下载包校验失败，停止GPU恢复' >&2; exit 1; }
    tar -tzf "$PKG" > "$BK/mesa-aac-filelist.txt"
    # 记录将被覆盖的原文件, 打成回退包
    rm -rf stage && mkdir stage && tar -xzf "$PKG" -C stage
    (cd stage && find . \( -type f -o -type l \) | sed 's|^\.||' | while read -r t; do [ -e "$t" ] && echo "$t"; done) > "$BK/mesa-overwrite-list.txt"
    tar -czf "$BK/mesa-ubuntu-original-$TS.tar.gz" -P -T "$BK/mesa-overwrite-list.txt" 2>/dev/null
    dpkg -l | awk '/libegl-mesa0|libgl1-mesa-dri|libglx-mesa0|mesa-libgallium|mesa-vulkan-drivers|libgbm1/{print $2"="$3}' > "$BK/mesa-apt-versions.txt"
    tar -zxf "$PKG" -C / && ldconfig
    apt-mark hold libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers >/dev/null
    # apt pin 双保险
    cat > /etc/apt/preferences.d/99-mesa-lock <<'EOF'
# 锁定 Mesa: 防止 apt upgrade 覆盖掉 Android 容器版(带 KGSL 后端)驱动
# 解锁前请先读 /root/deploy/docs/GPU.md
Package: libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers libglapi-mesa
Pin: release *
Pin-Priority: -1
EOF
    echo "   已安装 + apt-mark hold + apt pin"
    echo "   验证:"
    env -u DISPLAY VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
      vulkaninfo --summary 2>&1 | grep -iE 'deviceName|driverID|apiVersion' | sed 's/^/     /'
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# ★★2026-10-03 【整段删除】原 [3/9][4/9][5/9] —— 它们写 /etc/profile.d/{10-gpu,20-runtime,30-display}.sh
#
# 为什么删(用户 2026-10-03 拍板):
#   这三段的护栏 safe_write_guard 第一行是 `[ -e "$dst" ] || return 0` ——
#   而本项目早已把 GPU/runtime/display 环境【收敛进 ~/.config/desktop-env/*.sh】,
#   /etc/profile.d/ 下那三个文件【根本不存在】⇒ 护栏判"目标不存在, 放行"⇒ 三段全部直接写。
#   ★这是"看着有护栏、实际是空的", 比没有护栏更危险 —— 它给人虚假的安全感。
#   真跑一次就会凭空造出 10-gpu.sh, 里面带【全局】export MESA_LOADER_DRIVER_OVERRIDE=kgsl,
#   而 ~/.config/desktop-env/gpu.sh:13-16 明写这个绝不能全局设:
#   全局设了会让 --legacy / --soft 的 Xvnc 起不来(即账本 N16 那个崩溃)。
#   等于凭空造出【第二套环境来源】与 desktop-env 那套打架。
#
# 删掉后这些东西从哪来(2026-10-03 逐项实测核对过, 零损失):
#   原 [3/9] 10-gpu.sh
#     MESA_LOADER_DRIVER_OVERRIDE → desktop-env/display.sh (★按显示分档, 不全局)
#     LIBGL_ALWAYS_SOFTWARE       → desktop-env/display.sh
#     EGL_PLATFORM                → desktop-env/display.sh
#     VK_ICD_FILENAMES            → desktop-env/gpu.sh
#     MESA_VK_WSI_PRESENT_MODE    → desktop-env/gpu.sh
#     vblank_mode=0               → desktop-env/gpu.sh:17
#     TU_DEBUG=noconform          → startvnc:93 / startvncs:105 / startx11:108
#                                   (★同样是按显示在桌面启动时设, 这才是它该在的地方)
#   原 [4/9] 20-runtime.sh
#     XDG_RUNTIME_DIR / PULSE_SERVER / QT_QPA_PLATFORM /
#     QT_AUTO_SCREEN_SCALE_FACTOR / TMPDIR / LANG → 全部在 desktop-env/apps.sh
#   原 [5/9] 30-display.sh
#     use1() / use2()        → desktop-env/display.sh
#     kill_tree() / exit()   → desktop-env/exit.sh
#     ※ 顺带甩掉两个坏写法: 原 exit() 里的 `pkill -9 -x Xtigervnc` 与
#       `kill -9 $(pgrep -f "termux.x11")` —— pgrep/pkill -f 会匹配到调用者自己的命令行,
#       本项目已明令禁止(账本 E-DV: 管道右侧子 shell 的 cmdline 与父进程逐字相同)。
#
# 新机上的装载链(确认闭合):
#   本脚本 [5/6] 的 desktop-env 循环 → 把 files/desktop-env/*.sh|*.py 装进 /root/.config/desktop-env/
#   apps/03-apps-setup.sh:356       → 把 files/root-bashrc 装成 /root/.bashrc
#   /root/.bashrc:104-109           → for _f in gpu apps display exit; do . ~/.config/desktop-env/$_f.sh; done
#   startvnc / startvncs / startx11 → 各自 source desktop-env 并按显示补 TU_DEBUG 等
#
# ⇒ 若将来真要恢复 /etc/profile.d 那条路, 先读 desktop-env/gpu.sh 顶部那段
#   "为什么 MESA_LOADER_DRIVER_OVERRIDE 不能全局设" 再动手。
# ══════════════════════════════════════════════════════════════════════════════

say "[3/6] VNC 脚本与 xstartup"
for f in startvnc startvncpc stopvnc; do
  [ -f "$REPO/files/vnc/$f" ] || continue
  safe_install "$REPO/files/vnc/$f" "/usr/local/bin/$f"
done
mkdir -p /root/.vnc
bk /root/.vnc/xstartup
safe_install "$REPO/files/vnc/xstartup" /root/.vnc/xstartup
# xstartup 里的 PULSE_SERVER 同步成正确写法
sed -i 's|^export PULSE_SERVER=.*|export PULSE_SERVER=tcp:127.0.0.1:4713|' /root/.vnc/xstartup
echo "   /root/.vnc/xstartup (PULSE_SERVER 已修正)"

say "[4/6] 工具箱脚本 + 三份账本"
# ★整个 sh 目录都在射程内 —— 逐个走 safe_install, 别整目录 install
for _t in "$REPO"/tools/*.sh "$REPO"/tools/*.py; do
  [ -f "$_t" ] || continue
  safe_install "$_t" "/root/工具箱/sh/$(basename "$_t")"
done
# ★2026-09-30 补: ~/.config/desktop-env/ 下的双屏 xfconf 同步器。
#   它【不在 /root/工具箱/sh/】, 上面那个 for 循环够不着 —— 换新机会整份丢。
#   目标路径必须是 /root/.config/desktop-env/xfsync.py: xfsync-watch.sh 是按这个绝对路径拉它的。
mkdir -p /root/.config/desktop-env
for _d in "$REPO"/files/desktop-env/*.sh "$REPO"/files/desktop-env/*.py; do
  [ -f "$_d" ] || continue
  safe_install "$_d" "/root/.config/desktop-env/$(basename "$_d")"
done
# ★★2026-09-28 加护栏: 原来这里是无条件 `cp -p "$REPO"/ledger/*.txt /root/账本/` ——
#   在【已有账本的活机器上】跑这个脚本, 等于用仓库里的旧快照把现盘正账整份盖掉。
#   实撞(2026-09-28 10:11): 三份账本被回滚到 09-24 版 ——
#     已验证事实 3658 行 → 2042 行(E-AA 之后 62 条全没)、指引 451→321、清单 1014→829。
#   靠 git HEAD 里那份 3658 行的提交救回来的。本脚本是"换新机恢复盘", 不是"日常同步工具":
#   新机上 /root/账本 是空的, 该拷; 活机器上现盘一定比仓库新, 绝不能拷。
#   ⇒ 判据 = 【现盘那份行数是否 >= 仓库那份】。只有现盘不存在或明显更旧才还原;
#     更新或相当一律跳过, 并提示人工用 ledger-append.sh / git 对比。
for lf in "$REPO"/ledger/*.txt; do
  [ -f "$lf" ] || continue
  bn=$(basename "$lf"); dst="/root/账本/$bn"
  rn=$(wc -l < "$lf" 2>/dev/null); rn=${rn:-0}
  if [ ! -e "$dst" ]; then
    cp -p "$lf" "$dst"; echo "   + $bn ($rn 行, 新机首次)"
  else
    dn=$(wc -l < "$dst" 2>/dev/null); dn=${dn:-0}
    if [ "$dn" -ge "$rn" ]; then
      echo "   · 跳过 $bn —— 现盘 $dn 行 >= 仓库 $rn 行(现盘更新, 绝不覆盖)"
    else
      echo "   ⚠ $bn 现盘 $dn 行 < 仓库 $rn 行 —— 【不自动覆盖】, 差异请人工确认:"
      echo "       diff <(cat '$dst') <(cat '$lf')   #  确认后再手动 cp"
      echo "       ※ 账本只应用 ledger-append.sh 追加; 整份写回是丢数据的根源"
    fi
  fi
done
echo "   /root/工具箱/sh/ : $(ls /root/工具箱/sh | wc -l) 个"
echo "   /root/账本/      : $(ls /root/账本 | wc -l) 份"

say "[5/6] 应用层修复"
if [ "$SKIP_APPS" = "1" ]; then echo "   已跳过(--skip-apps)"; else
  # VLC: 绕开 root 限制(geteuid → getppid), 改前备份
  if [ -f /usr/bin/vlc ] && ! /usr/bin/vlc --version >/dev/null 2>&1; then
    bk /usr/bin/vlc
    python3 - <<'PY'
p="/usr/bin/vlc"
d=open(p,"rb").read()
n=d.count(b"geteuid")
d=d.replace(b"geteuid",b"getppid")
open(p,"wb").write(d)
print("   VLC 补丁: 替换 geteuid→getppid %d 处" % n)
PY
    /usr/lib/aarch64-linux-gnu/vlc/vlc-cache-gen /usr/lib/aarch64-linux-gnu/vlc/plugins 2>/dev/null && echo "   VLC 插件缓存已重建"
  fi
  # desktop 启动器: 带全套环境
  mkdir -p /usr/share/applications
  cat > /usr/share/applications/vlc.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=VLC 媒体播放器
Icon=vlc
Categories=AudioVideo;Player;
Exec=env XDG_RUNTIME_DIR=/tmp/runtime-root VLC_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/vlc/plugins /usr/bin/vlc --started-from-file %U
EOF
  restore_mpv_user_files "$REPO" /root || exit 1
  update-desktop-database /usr/share/applications 2>/dev/null
  echo "   desktop 启动器与 mpv.conf 已就位"
fi

say "[6/6] 自检"
printf '   GPU     : '; env -u DISPLAY vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | sed 's/^[[:space:]]*//' || echo "未识别(看 docs/GPU.md)"
printf '   VNC     : '; command -v vncserver >/dev/null && echo "已装 $(Xvnc -version 2>&1|head -1)" || echo "缺失"
printf '   音频    : '; (timeout 5 pactl info >/dev/null 2>&1 && echo "4713 通") || echo "不通(Termux 侧要先起 pulseaudio)"
printf '   mpv/vlc : '; echo "mpv=$(command -v mpv >/dev/null && echo ok || echo 无) vlc=$(/usr/bin/vlc --version >/dev/null 2>&1 && echo ok || echo '拒绝root')"
echo
echo "完成。重新登录 shell 让 /etc/profile.d 生效, 然后 startvnc 起桌面。"
echo "中转站: 把 token 放进 ~/.config/gpt_claude_ai/ 后跑 /root/工具箱/sh/relay-switch.sh list"
