#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# /root/.local/lib/spark-shim/clean-orphan-desktops.sh —— 清理孤儿用户级 .desktop
#   2026-09-24 初版 / 2026-09-25 修漏报(见下"修订记录")
#
# 要解决的现象(账本 E-AL 实锤): 星火/apt 卸载应用后, XFCE 应用菜单里条目还在。
#   光 `xfce4-panel -r` 没用 —— 残留的不是面板缓存, 是 electron-autopatch 生成在
#   【用户级】~/.local/share/applications 的 override .desktop。dpkg 只删得掉系统级那份
#   (/usr/share/applications/xxx.desktop), 用户级这份没有任何包管理器认领, 于是永久留在菜单里。
#
# ── 修订记录 2026-09-25: 修「孤儿漏报」──────────────────────────────────
#   实例: netease-cloud-music 于 2026-09-24 11:59:05 被 `apt remove`(dpkg 状态 not-installed),
#   但残留 ~/.local/share/applications/electron-netease-cloud-music.desktop 没被列出来。
#   ★漏报根因 = 老版判据④(旧文件 57~61 行)一条路走到黑:
#       "同名 .desktop 在任何系统级目录里都不存在" 才算孤儿。
#     而这个包的 /usr/share/applications/electron-netease-cloud-music.desktop 【还在】
#     (该包把整棵树装进 /opt, 系统级 .desktop 由包自己铺设; 包被 remove 后 dpkg 记录没了,
#      文件却留在盘上 → dpkg -S 查无主)。于是 sysfound=1 → continue → 永远轮不到打印。
#     ※ 不是"Exec 只看第一个字段"的老坑: 老版第 64 行取的是 awk '{print $2}'(第二字段),
#       而且那只是给人看的提示, 根本没参与判定。真凶就是判据④太窄。
#   ★修法: 判据④拆成三条【任一成立即为孤儿】的信号(R1/R2/R3), 见下。
#
# ★★孤儿判据 ——
#   先过三道【门】(缺一不考虑, 这三道是防误删的护栏):
#     ① 文件在【用户级】目录 $HOME/.local/share/applications 下(系统级文件一律不碰);
#     ② 文件内含一行 `X-Electron-Autopatch=1`
#        → 这是 /usr/local/bin/electron-autopatch 自己写的标记(见该脚本 MARK 变量与 --clean 分支),
#          它也用同一判据识别"自己生成的"; 用户手写的 override 没有这行 → 绝不误删;
#     ③ Exec 行确实走 /usr/local/bin/electron-wrap (再次确认是 autopatch 的产物)。
#   过门之后, 满足【任意一条】即判为孤儿:
#     R1 同名 .desktop 在【任何】系统级目录里都已不存在(见 SYS_DIRS)
#        → autopatch 只为系统级条目生成 override, 系统级同名消失 == 源包已卸载。
#     R2 Exec 解析出的【真实目标】不存在。真实目标 = 跳过 electron-wrap / env / sudo /
#        sh -c 等包装、剥掉 %U %u %F %f 占位符与引号之后的那个可执行文件或应用目录;
#        若它是 /usr/local/bin 下的 #! 壳脚本, 再跟一层 `exec /绝对路径`。
#        覆盖三种缺失: 绝对路径文件/目录不存在、相对路径不存在、裸命令不在 PATH。
#     R3 同名系统级 .desktop 还在, 但它和真实目标【都】不归任何【已安装】dpkg 包所有
#        → 典型的"包已 remove、文件没删干净"的残留(netease 就是这一型)。
#        要求两者同时无主, 是为了不误伤"用户手工放的系统级条目 + 包管理装的二进制"这种正常组合。
#   ※ 老版注释里"不用二进制存在性当判据"的顾虑依然成立(wrap 的第二个 token 可能是
#     /opt/apps/com.electron/... 这种公共 Electron 运行时), 所以 R2 只是【之一】, 不是唯一;
#     且 R2 解析的是 wrap 后面那个【应用自身】的路径, 不是 wrap 本身。
#
# 用法:
#   clean-orphan-desktops.sh                 # = --list, 只打印将删哪些, 不动任何文件(默认)
#   clean-orphan-desktops.sh --audit         # 只读体检: 列出用户级目录【全部】.desktop 的判定明细
#   clean-orphan-desktops.sh --delete        # 真删(★账本铁律7: 删除前必须先问过用户)
#   clean-orphan-desktops.sh --delete --dry-run   # 走 --delete 的代码路径但一个字节都不删(自测用)
#   环境变量 APTSS_ORPHAN_DRYRUN=1 等价于 --dry-run
# 退出码: 0 = 正常(无论找到几个孤儿); 只有参数错误才 2。调用方(aptss 包装)不看它的退出码。
# ══════════════════════════════════════════════════════════════════════
set -u
USER_DIR="${HOME:-/root}/.local/share/applications"
SYS_DIRS=(
  /usr/share/applications
  /usr/local/share/applications
  /var/lib/flatpak/exports/share/applications
  /var/lib/snapd/desktop/applications
)
MARK=X-Electron-Autopatch
WRAP=/usr/local/bin/electron-wrap

mode=list
dryrun="${APTSS_ORPHAN_DRYRUN:-0}"
for a in "$@"; do
  case "$a" in
    --list)    mode=list ;;
    --audit)   mode=audit ;;
    --delete)  mode=delete ;;
    --dry-run) dryrun=1 ;;
    -h|--help) sed -n '2,51p' "$0"; exit 0 ;;
    *) echo "用法: $(basename "$0") [--list|--audit|--delete [--dry-run]]" >&2; exit 2 ;;
  esac
done

[ -d "$USER_DIR" ] || exit 0

# ── 把 Exec= 的值切成 token: 认单/双引号与反斜杠转义, 不做任何展开(绝不 eval) ──
_tokenize() {
  local s="$1"                       # ★分两句写: local 的各个赋值是先整体做词展开再赋值,
  local n=${#s} i=0 c q='' cur='' started=0   #   写成一句的话 ${#s} 取的是外层作用域的 s(set -u 下直接报未绑定)
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=''; else cur+=$c; fi
    elif [ "$q" = '"' ]; then
      if   [ "$c" = '"' ]; then q=''
      elif [ "$c" = '\' ]; then i=$((i+1)); cur+=${s:i:1}
      else cur+=$c; fi
    else
      case "$c" in
        "'"|'"')  q=$c; started=1 ;;
        ' '|"	") if [ -n "$cur" ] || [ "$started" = 1 ]; then printf '%s\n' "$cur"; cur=''; started=0; fi ;;
        '\')      i=$((i+1)); cur+=${s:i:1} ;;
        *)        cur+=$c ;;
      esac
    fi
    i=$((i+1))
  done
  [ -n "$cur" ] || [ "$started" = 1 ] && printf '%s\n' "$cur"
  return 0
}

# ── 剥掉 desktop 占位符 %U %u %F %f %i %c %k %d %D %n %N %v %m; %% 是转义的字面 % ──
_strip_fieldcodes() {
  local s="$1"
  s=${s//%%/$'\001'}
  s=$(printf '%s' "$s" | sed -E 's/%[a-zA-Z]//g')
  printf '%s' "${s//$'\001'/%}"
}

# ── 从 Exec= 的值解析出【真实目标】(跳过包装层); 解析不出则输出空 ──
resolve_exec_target() {
  local depth="${2:-0}" line t b i j n
  [ "$depth" -gt 2 ] && return 0
  line=$(_strip_fieldcodes "$1")
  local -a toks=()
  while IFS= read -r t; do [ -n "$t" ] && toks+=("$t"); done < <(_tokenize "$line")
  n=${#toks[@]}
  [ "$n" -gt 0 ] || return 0
  i=0
  while [ "$i" -lt "$n" ]; do
    t=${toks[$i]}
    b=${t##*/}
    case "$t" in
      [A-Za-z_]*=*) i=$((i+1)); continue ;;      # env 的 VAR=value 赋值
    esac
    case "$b" in
      env|sudo|pkexec|doas|nohup|setsid|eatmydata|stdbuf|catchsegv|dbus-run-session|systemd-run|flatpak-spawn)
        i=$((i+1)); continue ;;                  # 纯前缀型包装, 跳过
      sh|bash|dash|zsh|ksh)                      # shell -c "真命令" → 递归解析引号里那串
        j=$((i+1))
        while [ "$j" -lt "$n" ]; do
          if [ "${toks[$j]}" = "-c" ]; then
            [ $((j+1)) -lt "$n" ] && resolve_exec_target "${toks[$((j+1))]}" $((depth+1))
            return 0
          fi
          case "${toks[$j]}" in -*) j=$((j+1)) ;; *) break ;; esac
        done
        [ "$j" -lt "$n" ] && printf '%s\n' "${toks[$j]}"
        return 0 ;;
      electron-wrap|electron-wrap.sh)            # 取参数型包装: 后面第一个非选项才是真身
        j=$((i+1))
        while [ "$j" -lt "$n" ]; do
          case "${toks[$j]}" in -*) j=$((j+1)) ;; *) break ;; esac
        done
        [ "$j" -lt "$n" ] && printf '%s\n' "${toks[$j]}"
        return 0 ;;
    esac
    printf '%s\n' "$t"; return 0                 # 普通命令: 就是它
  done
  return 0
}

# ── /usr/local/bin 一类的 #! 壳脚本: 只跟一层, 且只认写死的 `exec /绝对路径` ──
_follow_shim() {
  local bin="$1" real
  [ -f "$bin" ] || { printf '%s\n' "$bin"; return 0; }
  head -c2 "$bin" 2>/dev/null | grep -q '#!' || { printf '%s\n' "$bin"; return 0; }
  real=$(grep -m1 -oE '^[[:space:]]*exec[[:space:]]+"?/[^"[:space:]]+' "$bin" 2>/dev/null \
         | sed -E 's/^[[:space:]]*exec[[:space:]]+"?//')
  if [ -n "$real" ]; then printf '%s\n' "$real"; else printf '%s\n' "$bin"; fi
  return 0
}

# ── 目标存在性: 回显 "ok|说明" / "missing|说明" / "unknown|说明" ──
_target_state() {
  local t="$1" p
  [ -n "$t" ] || { printf 'unknown|Exec 解析不出目标\n'; return 0; }
  case "$t" in
    /*)  if [ -e "$t" ]; then printf 'ok|%s\n' "$t"; else printf 'missing|绝对路径不存在: %s\n' "$t"; fi ;;
    */*) if [ -e "$t" ]; then printf 'ok|%s\n' "$t"; else printf 'missing|相对路径不存在: %s\n' "$t"; fi ;;
    *)   p=$(command -v -- "$t" 2>/dev/null)
         if [ -n "$p" ]; then printf 'ok|%s\n' "$p"; else printf 'missing|裸命令不在 PATH: %s\n' "$t"; fi ;;
  esac
  return 0
}

# ── 某路径归哪个【已安装】dpkg 包; 无主/查不了则输出空 ──
#    ★ merged-usr: command -v 可能给出 /bin/xxx, 而 dpkg 记的是 /usr/bin/xxx, 直接查会假装"无主"
#      → 查不到就再用 readlink -f 归一化后查一次, 避免把有主的东西误判成残留。
_dpkg_owner() {
  local p="$1" out rp
  [ -n "$p" ] || return 0
  command -v dpkg-query >/dev/null 2>&1 || return 0
  out=$(dpkg-query -S "$p" 2>/dev/null | head -n1)
  if [ -z "$out" ]; then
    rp=$(readlink -f -- "$p" 2>/dev/null)
    [ -n "$rp" ] && [ "$rp" != "$p" ] && out=$(dpkg-query -S "$rp" 2>/dev/null | head -n1)
  fi
  [ -n "$out" ] && printf '%s\n' "${out%%:*}"
  return 0
}

# ── 对单个用户级 .desktop 做判定; 结果写进这几个全局量 ──
#    R_gate  : pass / no-mark / no-wrap
#    R_orph  : 1/0      R_why: 人话原因      R_tgt: 真实目标      R_state: ok/missing/unknown
#    R_sys   : 系统级同名文件路径(空=没有)
analyze() {
  local f="$1" base execline st d
  base=$(basename "$f")
  R_gate=pass; R_orph=0; R_why=''; R_tgt=''; R_state=''; R_sys=''

  grep -qE "^${MARK}=1[[:space:]]*$" "$f" 2>/dev/null || R_gate=no-mark
  execline=$(grep -m1 '^Exec=' "$f" 2>/dev/null | sed 's/^Exec=//')
  if [ "$R_gate" = pass ]; then
    case "$execline" in *"$WRAP"*) : ;; *) R_gate=no-wrap ;; esac
  fi

  R_tgt=$(resolve_exec_target "$execline")
  [ -n "$R_tgt" ] && R_tgt=$(_follow_shim "$R_tgt")
  st=$(_target_state "$R_tgt")
  R_state=${st%%|*}; R_desc=${st#*|}

  for d in "${SYS_DIRS[@]}"; do
    [ -e "$d/$base" ] && { R_sys="$d/$base"; break; }
  done

  [ "$R_gate" = pass ] || return 0

  if [ -z "$R_sys" ]; then
    R_orph=1; R_why="R1 系统级同名条目已消失 → 源包已卸载"
  elif [ "$R_state" = missing ]; then
    R_orph=1; R_why="R2 Exec 真实目标缺失($R_desc)"
  else
    local osys otgt
    osys=$(_dpkg_owner "$R_sys"); otgt=$(_dpkg_owner "$R_tgt")
    if [ -z "$osys" ] && [ -z "$otgt" ]; then
      R_orph=1
      R_why="R3 系统级条目($R_sys)与真实目标($R_tgt)均不归任何已安装包所有 → 卸载残留"
    else
      R_why="有效: 系统级条目在(${osys:-无主}) / 目标在(${otgt:-无主})"
    fi
  fi
  return 0
}

# ══════════════ --audit: 只读体检, 覆盖目录下全部 .desktop ══════════════
if [ "$mode" = audit ]; then
  echo "[aptss-orphan][audit] 目录: $USER_DIR (只读, 不会改动任何文件)"
  printf '%-56s %-8s %-9s %s\n' 文件 门禁 目标 判定
  na=0
  for f in "$USER_DIR"/*.desktop; do
    [ -f "$f" ] || continue
    na=$((na+1))
    analyze "$f"
    if [ "$R_gate" != pass ]; then
      case "$R_gate" in
        no-mark) g="非本工具" ;;
        no-wrap) g="未走wrap" ;;
        *)       g="$R_gate" ;;
      esac
      printf '%-56s %-8s %-9s %s\n' "$(basename "$f")" "$g" "$R_state" "不在删除范围; 目标=${R_tgt:-<无>} ($R_desc)"
    else
      printf '%-56s %-8s %-9s %s\n' "$(basename "$f")" "过门" "$R_state" \
        "$([ "$R_orph" = 1 ] && echo "★孤儿 $R_why" || echo "$R_why")"
    fi
  done
  echo "[aptss-orphan][audit] 共体检 $na 个 .desktop"
  exit 0
fi

# ══════════════ --list / --delete ══════════════
found=0 removed=0
for f in "$USER_DIR"/*.desktop; do
  [ -f "$f" ] || continue                                    # 只处理普通文件, 不跟软链目录
  analyze "$f"
  [ "$R_gate" = pass ] || continue                           # 门①②③
  [ "$R_orph" = 1 ] || continue
  base=$(basename "$f")
  found=$((found+1))
  if [ "$mode" = delete ] && [ "$dryrun" != 1 ]; then
    if rm -f -- "$f"; then
      removed=$((removed+1))
      echo "[aptss-orphan][已删] $base  ($R_why)"
    else
      echo "[aptss-orphan][删除失败] $base" >&2
    fi
  elif [ "$mode" = delete ]; then
    echo "[aptss-orphan][dry-run·未删] $base  ($R_why)"
  else
    echo "[aptss-orphan][将删·未执行] $base  ($R_why)"
  fi
done

# 顺带提醒: 不是本工具生成、因而【不在删除范围】, 但目标确实已经没了的用户级条目
hint=0
for f in "$USER_DIR"/*.desktop; do
  [ -f "$f" ] || continue
  analyze "$f"
  [ "$R_gate" = pass ] && continue
  [ "$R_state" = missing ] || continue
  hint=$((hint+1))
  echo "[aptss-orphan][提示·不删] $(basename "$f")  非本工具生成, 但 $R_desc —— 需要人工确认"
done

if [ "$found" -eq 0 ]; then
  echo "[aptss-orphan] 没有孤儿用户级 .desktop"
elif [ "$mode" = delete ] && [ "$dryrun" != 1 ]; then
  echo "[aptss-orphan] 共删除 $removed / $found 个"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$USER_DIR" >/dev/null 2>&1
elif [ "$mode" = delete ]; then
  echo "[aptss-orphan] dry-run: 共 $found 个会被删, 本次一个都没动"
else
  echo "[aptss-orphan] 共 $found 个孤儿(默认不删)。确认后执行: $0 --delete"
fi
exit 0
