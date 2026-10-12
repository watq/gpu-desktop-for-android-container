# desktop-env/apps.sh —— 各应用运行时环境 (来自历史 .bashrc, 新机沿用)
# 语言(历史 .bashrc 显式导出 LANG/LANGUAGE)
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN.UTF-8
# runtime 目录
export XDG_RUNTIME_DIR=/tmp/runtime-root
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }
export QT_QPA_PLATFORM=xcb
export QT_AUTO_SCREEN_SCALE_FACTOR=1
export TMPDIR=/tmp
# 音频(默认端口即 4713; 实测 127.0.0.1 也能连)
export PULSE_SERVER=${PULSE_SERVER:-127.0.0.1}
# VLC
export VLC_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/vlc/plugins
# DBUS 系统总线(历史 .bashrc 带; VLC/部分桌面组件要用) —— 仅当 socket 存在才设, 避免报错
[ -S /run/dbus/system_bus_socket ] && export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket
# Electron / Bilibili (proot 下关沙箱/手柄/HID)
export ELECTRON_NO_ATTACH_CONSOLE=1
export ELECTRON_DISABLE_GAMEPAD=1
export ELECTRON_DISABLE_HID=1
export DISABLE_GAMEPAD=1
export CHROME_DISABLE_HID=1
# Firefox (proot 下关沙箱; MOZ_WEBRENDER=0 是历史排查线索, 新机 GPU 好了可试着去掉)
export MOZ_FAKE_NO_SANDBOX=1
export MOZ_DISABLE_CONTENT_SANDBOX=1
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_DISABLE_GPU_SANDBOX=1
export MOZ_DISABLE_DMABUF=1
# 注: 历史还带 MOZ_WEBRENDER=0(旧机 zink 排查线索), 新机 GPU 已好, 暂不设(要试再加)

# ── U10 (2026-10-05): 把会话 SHELL 修成 /etc/shells 里的绝对路径 ────────────────────
#   现状: Termux 侧 /root/Termux目录/start.sh:166 传进来的是 `SHELL=$SHLX` = 裸词 `bash`
#         (start.sh:107 `export SHLX=bash`; 第167行要用 `/bin/$SHLX`, 所以 SHLX 本身不能带路径)。
#   后果: 裸词 `bash` 不在 /etc/shells(那里全是 /bin/bash 这种绝对路径), 于是任何走【真】
#         /usr/bin/pkexec 的调用方一律 rc=127:
#           "The value for the SHELL variable was not found in the /etc/shells file"
#         最典型受害者 = 星火商店"更新中心"(app.asar 的 UpdateCenter 写死 dc[0]="/usr/bin/pkexec",
#         绕过了我们的 PATH 垫片, 详见 spark-store-wrap.sh 里的长注释)。这是长期静默失败。
#   修法: 只在 SHELL 不合法时才改, 合法就不动(用户自己换 zsh/fish 并写对绝对路径时不打扰)。
#   副作用评估: $SHELL 的消费者(xfce4-terminal / x-terminal-emulator / 各种 "open in shell")
#         拿到 /bin/bash 比拿到裸词 `bash` 严格更可靠(后者还得靠 PATH 才解析得到)。未发现负面。
#   ★生效时机: 本文件由 ~/.bashrc 在【登录 shell】里 source ⇒ 对【新】桌面会话生效;
#         已经在跑的 xfce4-session 不会变(它的 environ 已固化)。所以星火那条另在 wrapper 里兜了一次。
if [ -z "${SHELL:-}" ] || ! grep -qxF "${SHELL:-}" /etc/shells 2>/dev/null; then
  export SHELL=/bin/bash
fi
