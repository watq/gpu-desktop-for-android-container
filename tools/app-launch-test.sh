#!/bin/bash
# 真实启动实测: 逐个 .desktop 启动, 看进程能否存活 N 秒
# 判据: 启动后存活 = 能打开; 秒退/崩溃 = 打不开
# 跳过清单: 会话/关机/锁屏类(会真的把桌面关掉)、xfce自带视频(用户说不修)
set -u
WAIT=${WAIT:-6}
OUT=/tmp/app_launch_report.txt
: > "$OUT"

SKIP='xfce4-session|logout|shutdown|reboot|lock|screensaver|xflock|exit|parole|xfburn|display-im6|mpv-video|Thunar-bulk'

export DISPLAY=${DISPLAY:-:2}

echo "==== 应用启动实测 $(date) DISPLAY=$DISPLAY ====" | tee -a "$OUT"

for f in /usr/share/applications/*.desktop; do
  [ -f "$f" ] || continue
  grep -q '^NoDisplay=true' "$f" 2>/dev/null && continue
  name=$(basename "$f" .desktop)
  echo "$name" | grep -qE "$SKIP" && { echo "SKIP  $name (跳过: 会话/关机/已知不修)" >> "$OUT"; continue; }

  ex=$(grep -m1 '^Exec=' "$f" | sed 's/^Exec=//' | sed -E 's/%[UufFdDnNickvm]//g')
  cmd=$(echo "$ex" | awk '{print $1}')
  command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ] || { echo "MISS  $name ($cmd 不存在)" >> "$OUT"; continue; }

  # 启动并观察
  setsid bash -c "$ex" >/tmp/launch-$name.log 2>&1 &
  pid=$!
  sleep "$WAIT"
  if kill -0 "$pid" 2>/dev/null; then
    echo "OK    $name" >> "$OUT"
    pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null
  else
    # 进程没了: 可能秒退(失败), 也可能 fork 后父进程正常退出
    child=$(pgrep -f "^$cmd" 2>/dev/null | head -1)
    if [ -n "$child" ]; then
      echo "OK    $name (fork型)" >> "$OUT"
      kill -9 "$child" 2>/dev/null
    else
      err=$(grep -viE '^\s*$|Gtk-WARNING|Gdk-WARNING|libEGL|MESA-LOADER|dbind|inotify' /tmp/launch-$name.log 2>/dev/null | head -2 | tr '\n' ' ')
      echo "FAIL  $name  ← ${err:0:120}" >> "$OUT"
    fi
  fi
  sleep 0.5
done

echo >> "$OUT"
echo "==== 汇总 ====" >> "$OUT"
printf "  能打开 : %s\n" "$(grep -c '^OK' "$OUT")" >> "$OUT"
printf "  打不开 : %s\n" "$(grep -c '^FAIL' "$OUT")" >> "$OUT"
printf "  缺文件 : %s\n" "$(grep -c '^MISS' "$OUT")" >> "$OUT"
printf "  跳过   : %s\n" "$(grep -c '^SKIP' "$OUT")" >> "$OUT"
echo "报告: $OUT"
