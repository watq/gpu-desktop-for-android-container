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
