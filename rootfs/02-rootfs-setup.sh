#!/usr/bin/env bash
# 02-rootfs-setup.sh —— 【proot Ubuntu 内】新机一键重建 第 2 步
# 幂等: 可重复执行; 每步都先备份再改。
# 用法: bash /root/deploy/rootfs/02-rootfs-setup.sh [--skip-gpu] [--skip-apps]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BK=/root/工具箱/backup
TS=$(date +%Y%m%d_%H%M%S)
SKIP_GPU=0; SKIP_APPS=0
for a in "$@"; do case "$a" in --skip-gpu) SKIP_GPU=1;; --skip-apps) SKIP_APPS=1;; esac; done

mkdir -p "$BK" /root/工具箱/sh /root/账本
say() { echo; echo "==> $*"; }
bk()  { [ -f "$1" ] && cp -p "$1" "$BK/$(basename "$1").$TS" && echo "   备份: $1"; }

say "[1/9] 基础包"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common dbus-x11 \
  fonts-noto-cjk locales curl wget python3 vulkan-tools mesa-utils \
  pulseaudio-utils vlc mpv 2>&1 | tail -3
locale-gen zh_CN.UTF-8 >/dev/null 2>&1

say "[2/9] GPU: Android 容器版 Mesa (带 KGSL 后端)"
if [ "$SKIP_GPU" = "1" ]; then
  echo "   已跳过(--skip-gpu)"
else
  GPU_MODEL=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || echo "未知")
  echo "   本机 GPU: $GPU_MODEL"
  MESA_VER="${MESA_VER:-26.3.0-devel-20260824}"
  MESA_TAG="${MESA_TAG:-mesa-$MESA_VER}"
  PKG="mesa-for-android-container_${MESA_VER}_ubuntu_noble_arm64.tar.gz"
  URL="https://github.com/lfdevs/mesa-for-android-container/releases/download/$MESA_TAG/$PKG"
  mkdir -p /root/工具箱/mesa-aac && cd /root/工具箱/mesa-aac
  if [ ! -f "$PKG" ]; then echo "   下载 $PKG"; curl -sL -o "$PKG" "$URL" || { echo "   ✘ 下载失败, 跳过 GPU"; SKIP_GPU=1; }; fi
  if [ "$SKIP_GPU" != "1" ] && [ -s "$PKG" ]; then
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

say "[3/9] GPU 环境变量 (/etc/environment.d 风格: 写进 /etc/profile.d)"
cat > /etc/profile.d/10-gpu.sh <<'EOF'
# Adreno 7xx/8xx: Freedreno 直出 GL/GLES/Vulkan, 不需要 Zink 翻译层
export MESA_LOADER_DRIVER_OVERRIDE=kgsl
export TU_DEBUG=noconform
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
export LIBGL_ALWAYS_SOFTWARE=0
export EGL_PLATFORM=x11
# 防撕裂(按需)
export MESA_VK_WSI_PRESENT_MODE=mailbox
export vblank_mode=3
EOF
chmod +x /etc/profile.d/10-gpu.sh
echo "   写入 /etc/profile.d/10-gpu.sh"

say "[4/9] runtime / 音频 / 语言"
cat > /etc/profile.d/20-runtime.sh <<'EOF'
export XDG_RUNTIME_DIR=/tmp/runtime-root
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }
export PULSE_SERVER=tcp:127.0.0.1:4713      # ← 正确写法, 少了 tcp: 和端口就连不上
export QT_QPA_PLATFORM=xcb
export QT_AUTO_SCREEN_SCALE_FACTOR=1
export TMPDIR=/tmp
export LANG=zh_CN.UTF-8
EOF
chmod +x /etc/profile.d/20-runtime.sh

say "[5/9] 显示切换 use1/use2 + 退出清理 (写进 /etc/profile.d, 不动 .bashrc)"
cat > /etc/profile.d/30-display.sh <<'EOF'
# VNC(:1) 与 Termux:X11(:2) 两套独立, 不合并。默认挑一个真实存在的。
if [ -z "${DISPLAY:-}" ] || [ "$DISPLAY" = ":0" ]; then
  if   [ -e /tmp/.X11-unix/X1 ]; then export DISPLAY=:1
  elif [ -e /tmp/.X11-unix/X2 ]; then export DISPLAY=:2
  else export DISPLAY=:1
  fi
fi
use1() { export DISPLAY=:1; echo "[切换] 当前操作目标: VNC(:1)"; }
use2() { export DISPLAY=:2; echo "[切换] 当前操作目标: Termux:X11原生(:2)"; }

kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -9 "$pid" 2>/dev/null
}
exit() {
  echo "正在清理桌面进程."
  [ -f /tmp/xfce.pid ] && { kill_tree "$(cat /tmp/xfce.pid)"; rm -f /tmp/xfce.pid; }
  pkill -9 -x Xtigervnc 2>/dev/null
  kill -9 $(pgrep -f "termux.x11") 2>/dev/null
  builtin exit "$@"
}
EOF
chmod +x /etc/profile.d/30-display.sh

say "[6/9] VNC 脚本与 xstartup"
for f in startvnc startvncpc stopvnc; do
  [ -f "$REPO/files/vnc/$f" ] || continue
  bk "/usr/local/bin/$f"; install -m 700 "$REPO/files/vnc/$f" "/usr/local/bin/$f"; echo "   /usr/local/bin/$f"
done
mkdir -p /root/.vnc
bk /root/.vnc/xstartup
install -m 700 "$REPO/files/vnc/xstartup" /root/.vnc/xstartup
# xstartup 里的 PULSE_SERVER 同步成正确写法
sed -i 's|^export PULSE_SERVER=.*|export PULSE_SERVER=tcp:127.0.0.1:4713|' /root/.vnc/xstartup
echo "   /root/.vnc/xstartup (PULSE_SERVER 已修正)"

say "[7/9] 工具箱脚本 + 三份账本"
install -m 700 "$REPO"/tools/*.sh "$REPO"/tools/*.py /root/工具箱/sh/ 2>/dev/null
cp -p "$REPO"/ledger/*.txt /root/账本/ 2>/dev/null
echo "   /root/工具箱/sh/ : $(ls /root/工具箱/sh | wc -l) 个"
echo "   /root/账本/      : $(ls /root/账本 | wc -l) 份"

say "[8/9] 应用层修复"
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
  cat > /root/.local/share/applications/mpv.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=mpv
Icon=mpv
Categories=AudioVideo;Player;
Exec=mpv --vo=gpu-next --gpu-api=vulkan --player-operation-mode=pseudo-gui -- %U
EOF
  mkdir -p /root/.config/mpv
  cat > /root/.config/mpv/mpv.conf <<'EOF'
# Adreno 8xx + 容器版 Mesa: 走 gpu-next / Vulkan(历史结论: 不要退回 legacy gpu+OpenGL)
vo=gpu-next
gpu-api=vulkan
hwdec=auto-safe
EOF
  update-desktop-database /usr/share/applications 2>/dev/null
  echo "   desktop 启动器与 mpv.conf 已就位"
fi

say "[9/9] 自检"
printf '   GPU     : '; env -u DISPLAY vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | sed 's/^[[:space:]]*//' || echo "未识别(看 docs/GPU.md)"
printf '   VNC     : '; command -v vncserver >/dev/null && echo "已装 $(Xvnc -version 2>&1|head -1)" || echo "缺失"
printf '   音频    : '; (timeout 5 pactl info >/dev/null 2>&1 && echo "4713 通") || echo "不通(Termux 侧要先起 pulseaudio)"
printf '   mpv/vlc : '; echo "mpv=$(command -v mpv >/dev/null && echo ok || echo 无) vlc=$(/usr/bin/vlc --version >/dev/null 2>&1 && echo ok || echo '拒绝root')"
echo
echo "完成。重新登录 shell 让 /etc/profile.d 生效, 然后 startvnc 起桌面。"
echo "中转站: 把 token 放进 ~/.config/gpt_claude_ai/ 后跑 /root/工具箱/sh/relay-switch.sh list"
