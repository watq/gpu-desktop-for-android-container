#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# desktop-env/cursor-sync.sh —— 把 xfconf 里的光标设置同步到 X 层 (2026-09-25)
#
# 要解决的问题(账本 E-CC/E-CI 都没查到底, 2026-09-25 用 XFIXES 实测定位):
#   ① 本机四个光标主题(vintage/Adwaita/bloom/bloom-dark)内含图【最大只有 48px】
#      → XcursorLibraryLoadImage 请求 64/96/128 一律回落 48
#      → XFCE「设置→鼠标→光标大小」滑块拖到 48 以上【毫无效果】。
#      解法: 用 make-hidpi-cursor.py 生成含 24/32/48/64/96/128 六档的放大主题, 放 ~/.icons/。
#   ② xfsettingsd 只管 XSETTINGS(GTK 应用读这个), **不写 Xcursor.* 的 xrdb 资源**;
#      而根窗光标(你在桌面空白处看到的那个)是会话启动时定死的, 改 xfconf 不会重设。
#      → 表现就是"改了大小看不出变化"。解法就是本脚本: 读 xfconf → 写 xrdb → 重设根窗光标。
#
# ★设计原则(用户明确要求): 【不架空原生 GUI 控制】——
#   本脚本【只读 xfconf】(= GUI 自己的存储)再往 X 层推, xfconf 始终是唯一真源。
#   不设 XCURSOR_THEME/XCURSOR_SIZE 环境变量去覆盖(那种做法 2026-09-25 已撤销)。
#   所以用户在 GUI 里怎么调, 重跑本脚本(或下次开会话)就怎么生效。
#
# 用法: cursor-sync.sh            用当前 $DISPLAY
#       cursor-sync.sh :1 :2      指定若干 display
#   由 startx11(:2) 与 ~/.vnc/xstartup(:1) 在会话起来后调用; 也可随时手动跑一次立即生效。
# 注意: 已经打开的窗口大多在创建时就定好了光标, 不会立刻变 —— 根窗/桌面会立刻变,
#       其余应用重开即可。这是 X 的固有行为, 不是本脚本没生效。
# ══════════════════════════════════════════════════════════════════════════════
set -u

# 取 xfconf 值。xfconf 走 D-Bus 会话总线, 而 :1/:2 各有一条独立总线 ——
# 若本 shell 没有 DBUS_SESSION_BUS_ADDRESS, 就从该 display 上跑着的 xfsettingsd 的
# /proc/<pid>/environ 里借一条(这正是 2026-09-25 排查时发现"改了没反应"的原因之一)。
bus_of_display() {
  local d="$1" p e
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    [ "$(basename "$(readlink "$p/exe" 2>/dev/null)" 2>/dev/null)" = xfsettingsd ] || continue
    e=$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null )
    [ "$(printf '%s' "$e" | sed -n 's/^DISPLAY=//p' | head -1)" = "$d" ] || continue
    printf '%s' "$(printf '%s' "$e" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)"
    return 0
  done
}

sync_one() {
  local d="$1" bus theme size src="xfconf"
  [ -e "/tmp/.X11-unix/X${d#:}" ] || { echo "[cursor-sync] $d 不在, 跳过"; return 0; }
  bus="$(bus_of_display "$d")"
  # ★必须用 env 传总线地址: `${bus:+VAR=val} cmd` 这种【展开出来的赋值前缀 bash 不认】,
  #   它会被当成命令名 → 读取静默失败 → 悄悄回落到下面的兜底值。2026-09-25 踩过这个坑:
  #   表现是"脚本说同步成功, 值却还是旧的"(兜底刚好读到 xrdb 里的旧值, 把失败掩盖了)。
  local -a E=(env "DISPLAY=$d")
  [ -n "$bus" ] && E+=("DBUS_SESSION_BUS_ADDRESS=$bus")
  theme=$("${E[@]}" timeout 15 xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null)
  size=$("${E[@]}" timeout 15 xfconf-query -c xsettings -p /Gtk/CursorThemeSize 2>/dev/null)
  # 兜底链: xfconf → xrdb 现值 → 保守默认。兜底时【明确说出来】, 别再让失败静默。
  if [ -z "$theme" ] || [ -z "$size" ]; then
    src="兜底(xfconf 读不到)"
    [ -n "$theme" ] || theme=$(env "DISPLAY=$d" timeout 10 xrdb -query 2>/dev/null | sed -n 's/^Xcursor.theme:[[:space:]]*//p')
    [ -n "$size" ]  || size=$(env "DISPLAY=$d" timeout 10 xrdb -query 2>/dev/null | sed -n 's/^Xcursor.size:[[:space:]]*//p')
    [ -n "$theme" ] || theme=Adwaita
    [ -n "$size" ]  || size=48
  fi
  case "$size" in ''|*[!0-9]*) size=48 ;; esac

  printf 'Xcursor.theme: %s\nXcursor.size: %s\nXcursor.theme_core: 1\n' "$theme" "$size" \
    | env "DISPLAY=$d" timeout 15 xrdb -merge 2>/dev/null
  # 重设根窗光标 —— 桌面空白处那个立刻变大/变小就是靠这一步
  env "DISPLAY=$d" "XCURSOR_THEME=$theme" "XCURSOR_SIZE=$size" \
    timeout 15 xsetroot -cursor_name left_ptr 2>/dev/null
  echo "[cursor-sync] $d → 主题=$theme 大小=$size  (来源: $src)"
}

if [ $# -gt 0 ]; then
  for d in "$@"; do sync_one "$d"; done
else
  sync_one "${DISPLAY:-:1}"
fi
exit 0
