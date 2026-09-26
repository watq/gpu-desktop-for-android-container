#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# measure-lib.sh —— 测量纪律工具库 (2026-09-26)
#
# 对应账本「目前进度指引.txt」铁律 32-35。存在的理由:
#   本项目账本里多处结论互相打对台(最典型: E-BQ 判"xwd 全黑帧=抓帧伪影" vs
#   wip/ledger-播放器画面.md 判"GPU 上屏整窗黑帧=真实"), 根子不在谁粗心, 在【测量方法】:
#   没有归一化、没有验证器、分块跑、判据分不清"功能坏了"和"工具测不了"。
#   这个库把那四件事做成可直接调用的函数, 以后测性能/测画面都 source 它。
#
# 方法论来源: github.com/zalexdev/linux-um-arm64 的 harness(它那套比它测的东西还严谨)。
#   UML 本身对本机无用(无 GPU 透传、单核、syscall 比 proot 慢 12 倍), 但纪律可以搬。
#
# 用法:
#   source /root/工具箱/sh/measure-lib.sh
#   m_display_px :1                     # → 该 display 的像素数
#   m_norm 42.5 :1                      # → 把"每帧/每秒"数值换算成每百万像素成本
#   m_compute_sample                    # → 跑一次 compute 验证器, 打印微秒数
#   m_validate_init / m_validate_add <us> / m_validate_verdict
#                                       # → 收集各条件的 compute 采样, 最后裁决整张表是否可信
#   m_interleave "A B C" 5 my_run_fn    # → 交错跑(A B C A B C ...) 5 轮, 而不是分块跑
#   m_median 1 2 3 4                    # → 中位数(不是均值)
#   m_self_check_hint                   # → 打印"判据是否分得清两种失败"的自检清单
# ══════════════════════════════════════════════════════════════════════════════
set -u

# ── 铁律 33: compute 验证器的阈值 ──
M_VALIDATE_CROSS_PCT="${M_VALIDATE_CROSS_PCT:-5}"    # 跨条件差异上限 %
M_VALIDATE_JITTER_PCT="${M_VALIDATE_JITTER_PCT:-8}"  # 组内抖动上限 %
M_COMPUTE_ITERS="${M_COMPUTE_ITERS:-200000}"         # compute 负载规模

# ─────────────────────── 铁律 32: 归一化到像素 ───────────────────────
m_display_px() {   # $1=display(:1/:2/...) → 打印像素总数; 拿不到打印空并返回 1
  local d="${1:-$DISPLAY}" dim w h
  dim=$(env "DISPLAY=$d" timeout 10 xdpyinfo 2>/dev/null | sed -n 's/^  dimensions: *\([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -1)
  [ -n "$dim" ] || return 1
  w=${dim% *}; h=${dim#* }
  echo $(( w * h ))
}

m_norm() {  # $1=测得的值(每帧/每秒) $2=display → 打印"每百万像素"的等效值
  # 为什么必须做: 实测 :1 = 2504x1152 = 288 万像素, :2 = 1280x1024 = 131 万像素, 差 2.2 倍。
  # 直接拿两端的 fps 比大小 = 拿"搬 288 万像素"和"搬 131 万像素"比谁快, 结论必然带系统性偏差。
  local v="$1" d="$2" px
  px=$(m_display_px "$d") || { echo "m_norm: 取不到 $d 的几何" >&2; return 1; }
  awk -v v="$v" -v px="$px" 'BEGIN{ printf "%.4f\n", v / (px/1000000.0) }'
}

m_geom_warn() {  # 两个 display 做对比前调一次, 把倍数差摆在眼前
  local a="$1" b="$2" pa pb
  pa=$(m_display_px "$a") && pb=$(m_display_px "$b") || return 0
  awk -v a="$a" -v b="$b" -v pa="$pa" -v pb="$pb" 'BEGIN{
    r = (pa>pb) ? pa/pb : pb/pa
    printf "  [铁律32] %s=%d 像素, %s=%d 像素, 相差 %.2f 倍 —— 跨端比较必须按像素归一化(用 m_norm)\n", a, pa, b, pb, r
  }'
}

# ────────────── 铁律 33: compute 验证器(纯用户态, 不进内核) ──────────────
m_compute_sample() {
  # 纯算术循环, 不做任何 syscall。同一台机器上相同指令流耗时必须一致;
  # 不一致 = 机器动了(降频/发热/别的子代理抢核) → 这一轮所有性能数字都脏。
  python3 - "$M_COMPUTE_ITERS" <<'PY'
import sys, time
n = int(sys.argv[1])
t0 = time.perf_counter_ns()
x = 1.0000001
acc = 0.0
for _ in range(n):
    acc = acc * x + 1.0e-9      # 纯浮点, 无 I/O 无 syscall
t1 = time.perf_counter_ns()
print((t1 - t0) // 1000)        # 微秒
PY
}

M_VAL_FILE=""
m_validate_init() {
  M_VAL_FILE="${1:-${TMPDIR:-/root/工具箱/wip}/.mvalidate.$$}"
  : > "$M_VAL_FILE"
}
m_validate_add() {   # $1=条件名 $2=compute 采样(微秒)
  [ -n "$M_VAL_FILE" ] || { echo "m_validate_add: 先调 m_validate_init" >&2; return 1; }
  printf '%s\t%s\n' "$1" "$2" >> "$M_VAL_FILE"
}
m_validate_verdict() {
  # 返回 0 = 这张表可信; 返回 1 = 【整张表作废, 调用方必须什么都不打印】
  [ -s "${M_VAL_FILE:-/nonexistent}" ] || { echo "  [铁律33] 没有 compute 采样 → 无法判定, 视为不可信" >&2; return 1; }
  python3 - "$M_VAL_FILE" "$M_VALIDATE_CROSS_PCT" "$M_VALIDATE_JITTER_PCT" <<'PY'
import sys, collections, statistics
path, cross_lim, jit_lim = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
g = collections.defaultdict(list)
for ln in open(path, encoding="utf-8"):
    p = ln.rstrip("\n").split("\t")
    if len(p) == 2:
        try: g[p[0]].append(float(p[1]))
        except ValueError: pass
if not g:
    print("  [铁律33] 采样为空 → 不可信"); sys.exit(1)
bad = False
meds = {}
for k, v in g.items():
    med = statistics.median(v)
    meds[k] = med
    if len(v) > 1:
        jit = 100.0 * (max(v) - min(v)) / med if med else 0.0
        if jit > jit_lim:
            print("  [铁律33] 条件 %s 组内抖动 %.1f%% > %.0f%% —— 机器在这一组里就动了" % (k, jit, jit_lim))
            bad = True
if len(meds) > 1:
    lo, hi = min(meds.values()), max(meds.values())
    cross = 100.0 * (hi - lo) / lo if lo else 0.0
    if cross > cross_lim:
        worst = max(meds, key=meds.get); best = min(meds, key=meds.get)
        print("  [铁律33] 跨条件 compute 差异 %.1f%% > %.0f%% (最慢 %s vs 最快 %s)" % (cross, cross_lim, worst, best))
        print("           相同指令流不可能有差异 ⇒ 机器动了(降频/发热/抢核), 这一轮的性能数字全部不可比")
        bad = True
if bad:
    print("  ⇒ 【整张表作废】请减少同时运行的条件/子代理后重跑, 不要发布这轮数字")
    sys.exit(1)
print("  [铁律33] ✔ compute 验证器通过 (跨条件 ≤%.0f%%, 组内 ≤%.0f%%) —— 这轮数字可比" % (cross_lim, jit_lim))
PY
}

# ─────────────── 铁律 34: 交错跑 + 中位数 ───────────────
m_interleave() {
  # $1="条件1 条件2 ..." $2=轮数 $3=回调函数名(收到 条件名 与 轮次)
  # 为什么不能分块跑: A 连跑 10 次再 B 连跑 10 次, 温度漂移/降频整个压在后半段,
  # 差异里混进了"第几个跑的"这个变量。交错跑让漂移平摊到所有条件。
  local conds="$1" rounds="$2" fn="$3" r c
  for r in $(seq 1 "$rounds"); do
    for c in $conds; do "$fn" "$c" "$r"; done
  done
}

m_median() {   # 中位数, 不是均值 —— 均值会被一次降频尖峰拽走
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{
    if (NR==0) { print ""; exit }
    print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2
  }'
}

# ─────────────── 铁律 35: 判据自检 ───────────────
m_self_check_hint() {
  cat <<'EOF'
  [铁律35] 写任何判据前先自问这一条:
    ★【如果被测功能其实是好的, 这个测试会不会以同样的方式失败?】
      会 → 你测的是工具而不是功能, 判据必须换掉。
    本项目实撞过的反例:
      · pgrep -x claude   —— claude 在不在跑都返回 0(comm 是 claude-real、exe 是版本号路径)
                             ⇒ 守卫形同不存在。改判 /proc/<pid>/exe 真实路径。
      · glxinfo 判 GPU    —— 不可靠。改判 /proc/<pid>/fd 里有没有 kgsl-3d0(硬证据)。
      · xdpyinfo 探活门   —— 好桌面也会被判失败 ⇒ 已从 startx11 移除。
    外部同构反例: busybox 的 ip 不认 veth 链路类型, CONFIG_VETH 开没开都以同样方式失败。
EOF
}

# ─────────────── 铁律 36: 长驻服务的 stdin 不能是普通文件 ───────────────
m_check_stdin_sanity() {
  # epoll_ctl 对普通文件返回 EPERM(本机实测) → 谁把长驻服务的 stdin 接到普通文件上,
  # 就会得到"进程起来了但一动不动", 且完全看不出所以然。
  local p e t bad=0
  for p in /proc/[0-9]*; do
    e=$(basename "$(readlink "$p/exe" 2>/dev/null)" 2>/dev/null) || continue
    case "$e" in Xtigervnc-dri3|Xtigervnc|Xvnc|termux-x11|xfce4-session|xfsettingsd|xfwm4|picom) ;; *) continue ;; esac
    t=$(readlink "$p/fd/0" 2>/dev/null) || continue
    case "$t" in
      /dev/null|socket:*|pipe:*|anon_inode:*) ;;
      *) printf '  [铁律36] ✘ %-18s (pid %s) 的 stdin 是普通文件: %s —— epoll 会 EPERM\n' "$e" "${p#/proc/}" "$t"; bad=1 ;;
    esac
  done
  [ "$bad" = 0 ] && echo "  [铁律36] ✔ 长驻服务 stdin 全部是 /dev/null / socket / pipe"
  return "$bad"
}

m_lib_selftest() {
  echo "── measure-lib 自检 ──"
  m_geom_warn :1 :2
  m_check_stdin_sanity
  local a b
  a=$(m_compute_sample); b=$(m_compute_sample)
  m_validate_init
  m_validate_add selftest "$a"; m_validate_add selftest "$b"
  m_validate_verdict || echo "  (自检时机器在动, 这本身就是验证器在起作用)"
  echo "  m_median 3 1 4 1 5 → $(m_median 3 1 4 1 5)"
  echo "  假设 :1 上测得 30fps → 每百万像素 $(m_norm 30 :1) fps"
  echo "  假设 :2 上测得 30fps → 每百万像素 $(m_norm 30 :2) fps   ← 同样 30fps, 实际工作量差 2.2 倍"
}

case "${1:-}" in
  selftest) m_lib_selftest ;;
  hint)     m_self_check_hint ;;
esac
