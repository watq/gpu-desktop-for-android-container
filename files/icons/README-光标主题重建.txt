# 高分屏光标主题由 tools/make-hidpi-cursor.py 重建, 不存二进制光标文件:
#   make-hidpi-cursor.py vintage vintage-hidpi 24,32,48,64,96,128
# 然后 xfconf-query -c xsettings -p /Gtk/CursorThemeName -s vintage-hidpi

# ★2026-09-26 补一条最容易漏的: ~/.icons/default/index.theme 会把【回落链的根】钉死。
#   它通常是 Inherits=<某个只到 48px 的主题>, 于是任何主题里缺的光标名都掉到这里拿小图,
#   或直接找不到而退回 X 核心字体光标(固定小号)。表现就是"换了 hidpi 主题还是有光标不变大"。
#   解法: 把它也改成 Inherits=<你的 hidpi 主题>。
#   补完之后连 Adwaita 请求 96 都能给到 96x96 八种光标 —— 不必给每个主题都生成 hidpi 版。
