#!/data/data/com.termux/files/usr/bin/bash
# 01-termux-bootstrap.sh —— 【Termux 宿主侧】新机一键重建 第 1 步
# 作用: 装 Termux 依赖 → 装 proot-distro Ubuntu 24.04 → 放好 start.sh → 进 rootfs 跑第 2 步
# 用法(在新手机的 Termux 里):
#   pkg install git -y && git clone <你的私有仓库> ~/deploy && bash ~/deploy/termux/01-termux-bootstrap.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RFSML="$HOME/Ubuntu"

echo "==> [1/6] Termux 基础包"
pkg update -y
pkg install -y proot proot-distro pulseaudio x11-repo termux-api wget curl git tar

echo "==> [2/6] Termux:X11 (可选, 失败不中断)"
pkg install -y termux-x11-nightly || echo "  跳过 termux-x11-nightly(仓库可能没有, 后面手动装 apk)"

echo "==> [3/6] 安装 Ubuntu 24.04 rootfs"
if [ -d "$RFSML" ] && [ -n "$(ls -A "$RFSML" 2>/dev/null)" ]; then
  echo "  $RFSML 已存在, 跳过安装(想重装请自己先删)"
else
  proot-distro install ubuntu
  # proot-distro 默认装到 $PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu
  SRC="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
  [ -d "$SRC" ] || { echo "找不到 proot-distro 安装目录: $SRC"; exit 1; }
  mkdir -p "$RFSML"
  echo "  搬到 $RFSML (本项目所有脚本都按这个路径写死)"
  cp -a "$SRC/." "$RFSML/"
fi

echo "==> [4/6] 放置 start.sh"
[ -f "$HOME/start.sh" ] && cp -p "$HOME/start.sh" "$HOME/start.sh.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$REPO_DIR/files/start.sh" "$HOME/start.sh"
chmod +x "$HOME/start.sh"
# 新机必须启用挂载(MayB), 否则 proot 内看不到 /sdcard 与 Termux 目录
sed -i 's|^#\(export MayB=\)|\1|' "$HOME/start.sh"
echo "  已启用 MayB 挂载行"

echo "==> [5/6] 存储权限 + 密钥目录"
termux-setup-storage || echo "  termux-setup-storage 需要手动授权, 之后再跑一次"
mkdir -p "$HOME/.config/gpt_claude_ai"
chmod 700 "$HOME/.config/gpt_claude_ai"
cat > "$HOME/.config/gpt_claude_ai/README-放key在这里.txt" <<'EOF'
把中转站 token 按下面的文件名放进本目录, 每个文件一行纯 token, 然后 chmod 600:
#   <站点名>-key   你自己的 API 中转站凭据(本仓不含任何凭据与站点信息)
  agent1-key     同上, 第二个账号
#   <站点名>-key   你自己的 API 中转站凭据(本仓不含任何凭据与站点信息)
  just-key       api.justwoker.icu (可选)
  github-key     GitHub PAT, 仅用于同步本仓库 (可选)
这些文件【绝对不要】提交到 git 仓库。
EOF

echo "==> [6/6] 把仓库复制进 rootfs, 并提示下一步"
mkdir -p "$RFSML/root/deploy"
cp -a "$REPO_DIR/." "$RFSML/root/deploy/"

cat <<EOF

────────────────────────────────────────────────
Termux 侧完成。接下来:

1) 启动进入 Ubuntu:
     bash ~/start.sh

2) 在 Ubuntu 里跑第 2 步:
     bash /root/deploy/rootfs/02-rootfs-setup.sh

3) 把中转站 token 放到:
     ~/.config/gpt_claude_ai/   (文件名见该目录下的 README)

注意: GPU 驱动包是按 Adreno 8xx 选的。新机如果不是 Adreno 8xx,
      先看 /root/deploy/docs/GPU.md 再决定装哪个版本。
────────────────────────────────────────────────
EOF
