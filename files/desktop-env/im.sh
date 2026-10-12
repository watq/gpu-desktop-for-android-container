#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# desktop-env/im.sh —— 中文输入法(ibus + libpinyin)环境 (2026-09-24)
#
# 背景: 本机 locale 全是 zh_CN.UTF-8、XFCE/VLC/星火 界面也都是中文, 但【GUI 里打不出中文】——
#   QT_IM_MODULE / GTK_IM_MODULE / XMODIFIERS 全为空, 且只装了 ibus 框架、没有任何输入引擎。
#
# 选 ibus 而不是 fcitx5 的原因: ibus 框架(ibus / ibus-gtk / ibus-gtk3 / ibus-gtk4)本机【已装好】,
#   只缺引擎, 装 ibus-libpinyin 仅新增 6 个包; 而 fcitx5 全家桶要新装 75 个包。
#   (/etc/default/im-config 里默认规则指向 fcitx5, 但 fcitx5 根本没装, 那条规则是空的。)
#
# 由 startx11(:2) / .vnc/xstartup(:1) 在起桌面前 source, 两套显示各自生效、互不干扰。
# 切换输入法: 默认 Ctrl+Space。首次用可能要先跑 ibus-setup 添加"智能拼音"。
# ══════════════════════════════════════════════════════════════════════

export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
# Qt5/Qt6 有些应用只认这个
export QT4_IM_MODULE=ibus
export CLUTTER_IM_MODULE=ibus

# 按真实可执行文件、DISPLAY 和会话总线判重；其他桌面的 ibus 不算本会话实例。
im_start() {
  local p exe entry dp bus target=${DISPLAY:-}
  [ -n "$target" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 1
  target=${target%.0}
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    [ "${exe##*/}" = ibus-daemon ] || continue
    dp= bus=
    while IFS= read -r -d '' entry; do
      case "$entry" in
        DISPLAY=*) dp=${entry#DISPLAY=} ;;
        DBUS_SESSION_BUS_ADDRESS=*) bus=${entry#DBUS_SESSION_BUS_ADDRESS=} ;;
      esac
    done 2>/dev/null < "$p/environ"
    [ "${dp%.0}" = "$target" ] && [ "$bus" = "$DBUS_SESSION_BUS_ADDRESS" ] && return 0
  done
  # 不使用 -r，避免替换已占用当前 XIM selection 的其他会话。
  ibus-daemon -dx >/tmp/ibus-daemon-${target//[^a-zA-Z0-9]/_}.log 2>&1 &
  sleep 1
}
