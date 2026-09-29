#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# /root/.local/lib/spark-shim/relink.sh —— 入口软链自愈 (2026-09-24)
#
# 为什么需要: spark-store 包的 postinst 在【每次】configure(安装/升级/dpkg-reconfigure)时无条件跑
#     ln -s -f /opt/durapps/spark-store/bin/aptss     /usr/bin/aptss
#     ln -s -f /opt/durapps/spark-store/bin/ssinstall /usr/bin/ssinstall
#     ln -s -f /opt/durapps/spark-store/bin/ssinstall /usr/local/bin/ssinstall
#   (prerm 则 unlink 这些路径)。所以【入口路径上的东西必然被包冲掉】, 我们的包装本体必须住在
#   /root/.local/lib/spark-shim(用户级、不归 dpkg 管), 入口只放软链, 被冲掉后由本脚本重新指回来。
#   触发时机: 包装脚本(aptss / ssinstall)开头调一次 + 会改包的子命令跑完再调一次
#   —— 星火升级自己时 postinst 刚把入口改回真身, 收尾这次就把它改回包装。
#
# ★安全线(宁可不修, 绝不误伤):
#   · 本体不存在/不可执行 → 直接退出, 不动任何入口(避免把入口指成坏链, 那会让星火 127)。
#   · 入口已经指向本体 → 什么都不做(幂等, 可反复调)。
#   · 入口是【普通文件】→ 一律跳过, 绝不删、绝不覆盖(账本铁律7: 不删非本轮新建的文件)。
#     带 spark-shim 标记的普通文件 = 本机制自己的转发壳, 本来就能用, 更不用动;
#     不带标记的 = 别人/用户的东西, 只在 stderr 说一句让人知道。
#     (只有"软链、坏链、不存在"这三种情况才会 ln -sfn 重指。)
#   · 一律用 `ln -sfn`(不是 `> 文件`): 它替换软链本身、绝不跟着软链把内容写进真身。
#     ⚠ 这条是硬要求 —— 若用重定向写入一个指向真身的软链路径, 会把 spark-store 包的真身脚本冲掉。
#   · 静默: 正常情况不输出(它在每次 aptss 调用时都会跑, 出声会污染星火 GUI 的进度文本)。
#     只有"跳过一个非本机制的普通文件入口"这种需要人知道的情况才往 stderr 说一句。
# 调试: RELINK_VERBOSE=1 ./relink.sh   → 打印每个入口的处置
# 回退(取消全部接管): 先删本文件(否则下次调用又会自愈), 再
#   ln -sfn /opt/durapps/spark-store/bin/aptss     /usr/bin/aptss
#   ln -sfn /opt/durapps/spark-store/bin/aptss     /usr/local/bin/aptss
#   ln -sfn /opt/durapps/spark-store/bin/ssinstall /usr/bin/ssinstall
#   ln -sfn /opt/durapps/spark-store/bin/ssinstall /usr/local/bin/ssinstall
# ══════════════════════════════════════════════════════════════════════
set -u
SHIM=/root/.local/lib/spark-shim
V="${RELINK_VERBOSE:-0}"

# 入口路径 → 本体 (注意 /bin 即 /usr/bin 的软链, 无需单列 /bin/aptss)
link_one() {
  local body="$1" entry="$2" cur
  [ -x "$body" ] || return 0                       # 本体没了: 不动入口
  if [ -L "$entry" ]; then
    cur=$(readlink -f "$entry" 2>/dev/null)
    [ "$cur" = "$body" ] && { [ "$V" = 1 ] && echo "  已就位 $entry"; return 0; }
  elif [ -e "$entry" ]; then
    # 普通文件: 一律不动(不删不覆盖)。带标记的是本机制自己的转发壳, 本来就能用。
    if grep -q 'spark-shim' "$entry" 2>/dev/null; then
      [ "$V" = 1 ] && echo "  跳过 $entry (本机制的普通文件转发壳, 无需改)"
    else
      echo "[relink] 跳过 $entry (是普通文件且非本机制所有, 不覆盖)" >&2
    fi
    return 0
  fi
  ln -sfn "$body" "$entry" 2>/dev/null && { [ "$V" = 1 ] && echo "  已重指 $entry -> $body"; return 0; }
  echo "[relink] 无法重指 $entry -> $body" >&2
  return 0
}

link_one "$SHIM/aptss"     /usr/bin/aptss
link_one "$SHIM/aptss"     /usr/local/bin/aptss
link_one "$SHIM/ssinstall" /usr/bin/ssinstall
link_one "$SHIM/ssinstall" /usr/local/bin/ssinstall
exit 0
