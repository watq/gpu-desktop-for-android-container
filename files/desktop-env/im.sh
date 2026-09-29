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

# 幂等拉起 ibus-daemon(proot 无 systemd, 只能自己起)
# ★用方括号写法防止 pgrep 匹配到调用它的 shell 自身(本项目踩过 exit 144 的坑)
im_start() {
  if pgrep -f '[i]bus-daemon' >/dev/null 2>&1; then
    return 0
  fi
  # -d 后台 -r 替换已有 -x 启动 XIM -n 指定面板
  ibus-daemon -drx >/tmp/ibus-daemon.log 2>&1 &
  sleep 1
}
