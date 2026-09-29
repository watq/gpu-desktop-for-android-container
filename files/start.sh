#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════════════════════════
# ① Termux:X11 服务端(:2) —— ★必须是全脚本【第一件事】
#   2026-09-22 重排原因(用户实测痛点): 原来它排在电池桥下面、紧挨 proot 启动, X server
#   刚起来就立刻进容器, 根本来不及建 /tmp/.X11-unix/X2 → 每次第一次启动都得手动去点
#   Termux:X11 图标。两份权威参考脚本都是【termux-x11 最先起、容器最后起】:
#     · iPupil 笔记:        kill -9 $(pgrep -f "termux.x11") ; termux-x11 :2 -dpi 96 & ; tmoe ls
#     · phoenixbyrd/Termux_XFCE: kill → termux-x11 :0 & → sleep 3 → am start → 桌面
#   ★不要动 XDG_RUNTIME_DIR: Termux 已设好正确值; 强改成 $TMPDIR 反而让 socket 建不起来
#     (用户实测: 手动裸跑这两行能起, 加了那行 export 就起不来)。与手动完全一致即可。
#   ★ disown: 摘掉 bash 作业表, 退出时不再打 "<pid> Killed termux-x11" —— 那不是错误,
#     是 proot --kill-on-exit 回收子进程的作业通知。
#   X11_ON=0 可关; dpi=96 是 iPupil 默认; X11_WAIT 可调等待秒数。
#   黑屏只有光标 → 加 -legacy-drawing; 颜色错乱 → 加 -force-bgra。 
if [ "${X11_ON:-1}" = 1 ] && command -v termux-x11 >/dev/null 2>&1; then
  # ★幂等(2026-09-22): X2 socket 已在 + termux-x11 进程还活着 → 什么都不做, 绝不杀重启。
  #   无条件 kill 会把你已点好图标、正在用的 X2 干掉, 逼你再点一次图标(与 00-clean-tmp 误删
  #   是一对孪生坑, 两个都已修)。只有 X2 真没了才 kill+重拉。
  if [ -S "$PREFIX/tmp/.X11-unix/X2" ] && pgrep -f "termux-x11" >/dev/null 2>&1; then
    echo "Termux:X11(:2) 已在运行, 跳过重启 (X2 socket 在)"
  else
    kill -9 $(pgrep -f "termux-x11") 2>/dev/null
    # ★X11_EXTRA: 画面异常时的官方补救参数(账本 X1 记载)
    #   黑屏只有鼠标光标 → -legacy-drawing   颜色错乱 → -force-bgra
    #   2026-09-23 默认开 -legacy-drawing: 本机实测 :2 桌面进程全活但画面黑屏只有光标。
    #   不想要就跑 X11_EXTRA= ./start.sh  (置空即可)
    termux-x11 :2 -dpi 96 ${X11_EXTRA--legacy-drawing} &
    disown 2>/dev/null || true
    # 轮询等 socket(机型起身速度不同), 最多 X11_WAIT 秒; ★不用 am start(用户明确不要)
    W=0; MAX=${X11_WAIT:-8}
    while [ ! -S "$PREFIX/tmp/.X11-unix/X2" ] && [ "$W" -lt "$MAX" ]; do sleep 1; W=$((W+1)); done
    if [ -S "$PREFIX/tmp/.X11-unix/X2" ]; then
      echo "Termux:X11(:2) 已就绪 (socket 已建, 可直接进 proot 跑 startx11)"
    else
      echo "Termux:X11(:2) 服务已拉起 —— ★还需在手机上点一下 Termux:X11 图标让前台接管, socket 才建立"
    fi
  fi
fi

info() {
	[ -n "$MayB" ] && echo "已挂载目录"
	# 音频: TCP 本地匿名, 不因空闲退出; 已在运行则跳过
	if ! pulseaudio --check 2>/dev/null; then
		pulseaudio --start --exit-idle-time=-1 \
			--load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" 2>/dev/null \
		|| echo "pulseaudio 启动失败(可忽略)"
	fi
	return 0
}
# ① 唤醒锁 —— 【2026-09-22 用户实测: 已关闭, 因为它拉起系统"电量详情/省电策略"弹窗】
#   ★归因(用户更正): 不是下面这句写法的问题, 是【termux-wake-lock 这个动作本身】在
#     新版 ZeroTermux/Termux 里就会触发电量详情(新版引进的行为, 老版本不会)。
#     换句话说: 直接裸跑 termux-wake-lock 也照弹, 与 timeout/command -v 包装无关。
#   且历史已记"锁不能阻止 MIUI Greezer 冻结" → 纯招弹窗无收益, 故整段注释掉。
#   (与 ~/.zshrc 里那处自动持锁同因, 两处都已关)
 command -v termux-wake-lock >/dev/null 2>&1 && timeout 8 termux-wake-lock 2>/dev/null || true
 unlock() { command -v termux-wake-unlock >/dev/null 2>&1 && timeout 8 termux-wake-unlock 2>/dev/null || true; }
 trap unlock EXIT INT TERM
# ③ 电池桥: 把 termux-battery-status 快照写入 /tmp(已绑定到 proot 的 /tmp), proot 内读 /tmp/battery.json
# 同样套 timeout: 该命令走 Termux:API socket, 无响应会挂死
BATT=/data/data/com.termux/files/usr/tmp/battery.json
command -v termux-battery-status >/dev/null 2>&1 && timeout 8 termux-battery-status > "$BATT" 2>/dev/null || true

# ③b 电池桥【轮询】—— 光写一次不够: proot 内面板(genmon)要持续看到最新电量。
#   容器内【看不到】termux-battery-status(Termux 的 usr/bin 没挂进 proot), 所以刷新
#   只能在【Termux 宿主侧】做。这个后台循环每 BATT_POLL_SEC 秒重写一次 battery.json,
#   /tmp 是绑过去的同一份文件 → proot 内 battery-genmon.sh 直接读到新值。
#   用户要的行为: 插电约 10 秒内面板显示充电图标, 拔电恢复普通图标。
#   ★ 套 timeout: termux-battery-status 走 Termux:API socket, 无响应会挂死(T1b 同款教训)。
#   ★ 写临时文件再 mv: 避免面板正好读到写了一半的 JSON。
#   BATT_POLL=0 可关闭轮询; BATT_POLL_SEC 可调周期。
if [ "${BATT_POLL:-1}" = 1 ] && command -v termux-battery-status >/dev/null 2>&1; then
  pkill -f 'termux-battery-status-poller' 2>/dev/null
  ( exec -a termux-battery-status-poller bash -c '
      while :; do
        sleep "${BATT_POLL_SEC:-10}"
        timeout 6 termux-battery-status > "'"$BATT"'.tmp" 2>/dev/null \
          && [ -s "'"$BATT"'.tmp" ] && mv "'"$BATT"'.tmp" "'"$BATT"'" \
          || rm -f "'"$BATT"'.tmp"
      done' ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "电池桥轮询已启动 (每 ${BATT_POLL_SEC:-10}s 刷新 battery.json)"
fi
unset LD_PRELOAD
export RFSML=/data/data/com.termux/files/home/Ubuntu
# 自愈: 让 Termux 侧脚本恒指向 proot 内规范版(改脚本只改 工具箱/sh 一处; 缺失/断链/指错都会重建)
for _f in relay-switch.sh; do          # 要一并带看门狗就改成:  for _f in relay-switch.sh relay-watch.sh; do
    _canon="$RFSML/root/工具箱/sh/$_f"; _link="$HOME/$_f"
    [ -e "$_canon" ] || continue       # rootfs 里没有规范版就别建空悬链
    if [ "$(readlink -f "$_link" 2>/dev/null)" != "$(readlink -f "$_canon" 2>/dev/null)" ]; then
        ln -sf "$_canon" "$_link" && echo "[start] 已修复软链 $_f → 工具箱/sh 规范版"
    fi
done
export TLANG=zh_CN.UTF-8 #语言环境{可选C,zh_CN.UTF-8}


#可以修改登录用户
export TUSER=0:0 #用户UID:GID{可选0:0是root，一般情况1000:1000是普通用户，具体查看/etc/passwd}

#export TUSER=1000:1000 #用户UID:GID{可选0:0是root，一般情况1000:1000是普通用户，具体查看/etc/passwd}



#可以修改登录shell
export SHLX=bash #登录所用SHELL{可选bash,zsh,fish,ash....}
#可以修改登录目录




#export THOME=/home/a
#登录用户主目录，可选{/root,/home/username}

export THOME=/root                                                  #登录用户主目录，可选{/root,/home/username}



##删除下行注释，可以将手机目录进行映射，这里将/sdcard映射到/mnt/sdcard，termux目录映射到/etc/termux
export MayB='-b /sdcard:/root/手机内部存储 -b /data/data/com.termux/files/home:/root/Termux目录'

# ④ Termux:X11 服务端(:2) —— 已移到脚本【最前面】, 见文件开头。
#   原因: 放在这里(紧挨 proot 启动)会导致 X server 刚起就进容器, 来不及建 socket,
#   每次都要手动去点 app。iPupil / phoenixbyrd 两份参考脚本都是"termux-x11 最先起、
#   容器最后起"。2026-09-22 已按此重排。
# ⑤ SysV IPC 仿真 —— 修 MIT-SHM(VNC/X11 客户端共享内存传图)
#   2026-09-22 实测根因: Android 内核【禁用了 SysV IPC】, 容器内 shmget() 直接返回
#   "Function not implemented"。两个 X 服务端(:1 TigerVNC / :2 Termux:X11)都宣称支持
#   MIT-SHM 扩展, 但客户端申请不到共享内存段 → 只能退回走 socket 逐像素传, 慢且吃 CPU。
#   proot 的 --sysvipc 会在用户态仿真 shmget/shmat/semget 等, 让 MIT-SHM 真正可用。
#   ★ 自动探测: 万一当前 proot 版本不认这个参数, 就自动不加 —— 绝不因此把人锁在容器外。
#   SYSVIPC=0 可强制关闭。
SYSVIPC_OPT=""
if [ "${SYSVIPC:-1}" = 1 ] && proot --help 2>&1 | grep -q -- '--sysvipc'; then
  SYSVIPC_OPT="--sysvipc"
  echo "SysV IPC 仿真已启用 (--sysvipc, 修 MIT-SHM)"
else
  [ "${SYSVIPC:-1}" = 1 ] && echo "注意: 当前 proot 不支持 --sysvipc, MIT-SHM 仍不可用(不影响启动)"
fi

command="
proot \
    --kill-on-exit \
    --link2symlink \
    $SYSVIPC_OPT \
    -i $TUSER \
    -r $RFSML \
    -b /dev \
    -b /proc \
    -b /sys \
    -b $RFSML/root/.config/relay/fake_uid_map:/proc/self/uid_map \
    -b $RFSML/root/.config/relay/fake_gid_map:/proc/self/gid_map \
    -b $RFSML/root/.local/share/fakebat:/sys/class/power_supply \
    -b /data/data/com.termux/files/usr/tmp:/tmp \
    -b /data/data/com.termux/files/home/.config/gpt_claude_ai:/root/.config/gpt_claude_ai \
    -b $RFSML$THOME:/dev/shm \
$MayB
    -w $THOME \
      /usr/bin/env \
        -i HOME=$THOME \
        PULSE_SERVER=127.0.0.1 \
        TMPDIR=/tmp \
		PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games
        TERM=$TERM \
        SHELL=$SHLX \
        LANG=$TLANG \
      /bin/$SHLX --login"
#执行命令行
info
if [ -z "$*" ]; then $command; else $command -c "$*"; fi
exit $?


