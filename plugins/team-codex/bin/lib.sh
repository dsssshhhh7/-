#!/bin/bash
# 多会话协作 · 公共函数库
# 所有 cc* 指令都 source 这个文件。
# 设计原则：脚本只做「不需要思考」的事——建目录、读写文件、查状态。
#           需要判断的事（这条算不算结论、消息该不该压着）交给会话去做。

set -o pipefail

# 不许被管道掐死在半路。
#
# 起因是真事：一条组内广播被 `cctell … | head -6` 调用，head 读够 6 行就退出，
# cctell 收到管道断开信号当场死掉 —— 死的位置正好在「消息已经投进对方信箱」之后、
# 「写进组流水」之前。结果：对方收到了并回了执，而流水里这条消息**一个字都没有**。
# 流水回答的是「怎么变成现在这样的」，静默缺一条比乱一条更难查。
#
# 屏蔽掉这个信号，写文件那几步就能跑完；输出写不出去只是写不出去，不影响落盘。
trap '' PIPE

# 固定为 UTF-8，保证 ${#字符串} 按「字数」而不是「字节数」算。
# 不设的话在某些环境下一个中文会被当成 3 个，截断长度全乱。
export LANG="${LANG:-zh_CN.UTF-8}"

# ───────────────────────── Codex 兼容层 ─────────────────────────
# Codex 会给每个任务注入稳定的线程编号。底层账本沿用 Claude 版已经跑过
# 大量实战的格式，只在这里把身份变量和数据根目录切到 Codex。
if [ -n "${CODEX_THREAD_ID:-}" ]; then
  export CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID}}"
  TEAM_RUNTIME="codex"
elif [ -n "${CODEX_SESSION_ID:-}" ]; then
  export CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID}}"
  TEAM_RUNTIME="codex"
else
  TEAM_RUNTIME="claude"
fi

# ───────────────────────── 路径 ─────────────────────────
if [ "${TEAM_RUNTIME}" = "codex" ]; then
  TEAM_ROOT="${TEAM_ROOT:-$HOME/codex-team}"
else
  TEAM_ROOT="${TEAM_ROOT:-$HOME/claude-team}"
fi
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_DIR="$TEAM_ROOT/.lock"
INDEX_FILE="$TEAM_ROOT/会话索引.md"
SESSIONS_DIR="$TEAM_ROOT/会话"
GROUPS_DIR="$TEAM_ROOT/协作组"
CLOSED_DIR="$TEAM_ROOT/已结案"

# ───────────────────────── 基础工具 ─────────────────────────

t_die() { echo "❌ $*" >&2; exit 1; }
t_warn() { echo "⚠️  $*" >&2; }
t_ok()   { echo "✅ $*"; }

# 时间：给人看的短格式 / 排序用的长格式
t_now()   { date '+%m-%d %H:%M'; }
t_stamp() { date '+%Y%m%d-%H%M%S'; }
t_epoch() { date '+%s'; }

# 去掉字符串首尾空白
t_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# 拦下正文里以「## 」开头的行。
#
# 为什么要拦：共识文件和状态文件都靠行首的「## 」切分节。正文里一旦混进这么一行，
# 文件里就会冒出第二个同名分节，之后按分节读，正文会被算到别的节去。
# 最容易踩到的场合：把一段现成的 markdown 原样粘进结论里。
#
# 为什么是拦下、不是替人改掉：共识的底线是【写进去什么，读出来还是什么】。
# 悄悄替人动内容，比拦下来让他自己改一个字危险得多。
#
# 来源：随机自测（内容随机 + 写入顺序随机）揪出来的；固定用例跑多少遍都碰不到。
t_reject_heading() {   # $1=正文  $2=文件叫什么（"共识" / "状态"）
  printf '%s' "$1" | grep -q '^## ' || return 0
  echo "❌ 这条内容里有一行以「## 」开头，不能这么写。" >&2
  echo >&2
  echo "   ${2}文件是靠行首的「## 」分节的。你这行会被当成真的分节标题，" >&2
  echo "   文件里就会出现两个同名分节，之后按分节读，正文会被算到别的节去。" >&2
  echo >&2
  echo "   是这几行：" >&2
  printf '%s' "$1" | grep -n '^## ' | sed 's/^/     第 /' >&2
  echo >&2
  echo "   改法：把行首那两个井号去掉就行（例「## 技术设计」写成「技术设计那一节」）。" >&2
  exit 1
}

# ───────────────────────── 会话身份 ─────────────────────────

# 当前会话编号。Claude Code 使用 CLAUDE_CODE_SESSION_ID；Codex 的
# CODEX_THREAD_ID / CODEX_SESSION_ID 已在上面的兼容层映射进来。
#
# ⚠️ 这个检查必须在 lib.sh 被加载的那一刻就做，不能只放在 t_sid 里 ——
#    t_sid 通常是被 $(...) 调用的，里面的 exit 只退出那个子进程，
#    主脚本拿到一个空字符串继续往下跑，最后还会报"成功"、退出码 0。
#    实测：在 Claude Code 会话外跑 ccjoin，连报 4 次错之后照样把组建出来了。
# ccdoctor 要能在会话外跑（它的活就是诊断"为什么跑不起来"），所以给它留个后门。
if [ -z "$CLAUDE_CODE_SESSION_ID" ] && [ -z "$TEAM_SKIP_SESSION_CHECK" ]; then
  echo "❌ 这套协作机制只能在 Codex 或 Claude Code 会话里运行。" >&2
  echo >&2
  echo "   当前环境拿不到任务编号（CODEX_THREAD_ID / CODEX_SESSION_ID 均为空）。" >&2
  echo "   常见原因：" >&2
  echo "     · 在普通终端里直接敲这些命令 —— 请在 Codex 任务里用" >&2
  echo "     · 通过 ssh 或脚本间接调用 —— 这些环境不会带上会话编号" >&2
  echo >&2
  echo "   正确用法：在 Codex 任务里跟它说人话（例如「加入讨论组 X」），" >&2
  echo "   由会话去执行这些命令，不需要你手敲。" >&2
  exit 78   # 78 = 配置/环境不对，跟一般的运行错误区分开
fi

t_sid() { printf '%s' "$CLAUDE_CODE_SESSION_ID"; }

# 我的会话目录
t_mydir() { printf '%s/%s' "$SESSIONS_DIR" "$(t_sid)"; }

# 我的收件箱
t_myinbox() { printf '%s/收件箱' "$(t_mydir)"; }

# ───────────────────────── 骨架自举 ─────────────────────────

# 第一次使用时整套目录不存在，这里自动建齐。
# 机器用的那些隐藏文件，名字从中文换成了英文。
#
# 为什么换：这些路径是**写进 settings.json 由 Claude Code 去执行**、或者被脚本反复拼接的，
# 属于机器可读的东西，中文名在 Windows / 非 UTF-8 环境下容易出事（状态栏的入口文件
# 当初就是因为这个特意用了英文名，但它 exec 的那个还是中文名，本来就不一致）。
# 人要读的东西（会话索引、协作组、传话台、共识、流水…）一个字都没动 —— 那是产品本身。
#
# 老装机上已经有中文名的文件，这里自动搬过去，不用人管，也不会丢东西。
# 这张表天生就得写出老名字，所以每行都带「过渡期兼容」标记 —— 体检的说法自查见到它就跳过。
# 解析时把井号后面的部分去掉。
TEAM_PATH_MIGRATIONS="
.插件检查:.plugin # 过渡期兼容
.状态栏:.statusline # 过渡期兼容
.代号不用了:.no-alias # 过渡期兼容
"
# 状态栏入口文件的内容。
#
# 这个文件是**装的时候写到磁盘上的，之后就不再更新**（settings.json 里填的是它）。
# 所以它读的任何位置一旦改名，状态栏就当场变空，而且没有任何报错 ——
# 实测踩过：机器路径改成英文名之后，它还在读老名字，老目录又被迁移清掉了，
# 于是取不到 bin、也找不到老底座，直接静默退出，整条状态栏没了。
#
# 现在的原则：**怎么都不能让状态栏变空**。三层兜底，最后一层不依赖任何指针文件。
t_statusline_shim_text() {
  cat <<'SHIMEOF'
#!/bin/bash
# team 插件 · 状态栏入口
#
# settings.json 里只填这一个路径，**不要填插件目录** ——
# 插件目录带版本号（…/team/1.0.28/bin），升一次版就变，填了下次就指空。
#
# ⚠️ 这个文件装一次就留在磁盘上。所以它必须**自己扛得住**指针失效：
#    三层兜底，最后一层直接按版本目录找最新的，不依赖任何指针文件。
CFG="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
B="$(cat "${HOME}/claude-team/.plugin/binpath" 2>/dev/null)"
[ -n "${B}" ] || B="$(cat "${HOME}/claude-team/.插件检查/bin路径" 2>/dev/null)"   # 过渡期兼容
if [ -z "${B}" ] || [ ! -x "${B}/ccstatusline" ]; then
  B="$(ls -dt "${CFG}"/plugins/cache/xbcx/team/*/bin 2>/dev/null | head -1)"
fi
if [ -n "${B}" ] && [ -x "${B}/ccstatusline" ]; then
  exec bash "${B}/ccstatusline"
fi
# 插件真的不在了 → 退回你原来的状态栏，别让它变空
for BASE in "${HOME}/claude-team/.statusline/base.sh" "${HOME}/claude-team/.状态栏/底座.sh"; do   # 过渡期兼容
  [ -x "${BASE}" ] && exec bash "${BASE}"   # 过渡期兼容：第二个是老名字
done
exit 0
SHIMEOF
}

# 入口文件已经装过、但内容是老的 → 原地重写。
# 只在「已经有这个文件」时做：没装过状态栏的人不该被凭空塞一个。
t_refresh_statusline_shim() {
  local f="${TEAM_ROOT}/statusline.sh"
  [ -f "$f" ] || return 0
  grep -q 'plugins/cache/xbcx/team/\*/bin' "$f" 2>/dev/null && return 0   # 已经是新版
  t_statusline_shim_text > "$f" 2>/dev/null && chmod +x "$f" 2>/dev/null
  return 0
}

t_migrate_paths() {
  local pair old new
  # 顶层目录
  #
  # ⚠️ 两边都存在时要**合并**，不能整个跳过。
  #    跳过的后果实测见过：老目录留在原地没人清，而**还有旧代码在往它里面写**
  #    （仓库那个引导脚本改晚了几版），于是「当前插件装在哪」出现两个互相打架的答案，
  #    一个说 1.0.58、一个说 1.0.52，而实际装的是 1.0.63。
  #    合并规则：新的一边没有的就搬过去，已经有的以新的为准（新的更近），搬完删掉空壳。
  local f base
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    pair="${pair%% #*}"                       # 去掉行尾的标记
    old="${TEAM_ROOT}/${pair%%:*}"; new="${TEAM_ROOT}/${pair##*:}"
    [ -e "$old" ] || continue
    if [ ! -e "$new" ]; then
      mv "$old" "$new" 2>/dev/null
    elif [ -d "$old" ] && [ -d "$new" ]; then
      for f in "$old"/* "$old"/.[!.]*; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ -e "$new/$base" ] || mv "$f" "$new/$base" 2>/dev/null
      done
      rm -rf "$old" 2>/dev/null
    else
      rm -f "$old" 2>/dev/null
    fi
  done <<< "$(printf '%s' "$TEAM_PATH_MIGRATIONS" | sed '/^$/d')"
  # 目录里的文件，同样一行一对、每行带标记
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    pair="${pair%% #*}"
    old="${TEAM_ROOT}/${pair%%:*}"; new="${TEAM_ROOT}/${pair##*:}"
    [ -e "$old" ] || continue
    # 新名字已经在了就把老的删掉，别让两个名字并排躺着 —— 上面目录合并时
    # 老名字的文件会被原样搬进新目录，不删的话新目录里就同时有 bin路径 和 binpath。
    if [ -e "$new" ]; then rm -rf "$old" 2>/dev/null; else mv "$old" "$new" 2>/dev/null; fi
  done <<'MIGEOF'
.plugin/bin路径:.plugin/binpath # 过渡期兼容
.plugin/上次刷新:.plugin/lastcheck # 过渡期兼容
.plugin/上次失败:.plugin/lastfail # 过渡期兼容
.plugin/回执.txt:.plugin/receipt.txt # 过渡期兼容
.plugin/副本损坏次数:.plugin/brokencount # 过渡期兼容
.statusline/底座.sh:.statusline/base.sh # 过渡期兼容
.statusline/不用了:.statusline/disabled # 过渡期兼容
.statusline/原配置备份.txt:.statusline/original-statusline.txt # 过渡期兼容
MIGEOF
  # 每个会话目录下的
  local d f
  t_refresh_statusline_shim
  for d in "$SESSIONS_DIR"/*; do
    [ -d "$d" ] || continue
    for f in "心跳:beat" "末次心跳:beat-last" "已发出:sent" "已回复:replied" \
             "已处理:done" "加工员:agent" "档位:gear" "待补回执:pending-ack"; do
      [ -e "$d/.${f%%:*}" ] && [ ! -e "$d/.${f##*:}" ] && mv "$d/.${f%%:*}" "$d/.${f##*:}" 2>/dev/null
    done
  done
  return 0
}

t_ensure_skeleton() {
  mkdir -p "$LOCK_DIR" "$SESSIONS_DIR" "$GROUPS_DIR" "$CLOSED_DIR"
  t_migrate_paths
  # 第一次用时把配置文件生成出来 —— 不生成的话没人知道有得配
  if [ ! -f "${TEAM_ROOT}/.plugin/config" ]; then
    mkdir -p "${TEAM_ROOT}/.plugin" 2>/dev/null
    cat > "${TEAM_ROOT}/.plugin/config" <<'CFGEOF' 2>/dev/null
# 这台机器自己的配置。一行一条 key=value，井号开头是注释。
# 改完立刻生效，不用重开窗口。想临时改一次可以用同名环境变量覆盖。
#
# talk_keep_days —— 传话台的历史流水保留几天（默认 7）。
#   传话台是「说完就算」的通道，不做长期沉淀；讨论组那边的共识和流水不受这个影响。
#   想留久一点就把数字调大，比如审计要求留一个月就写 30。
talk_keep_days=7

# idle_exit_seconds —— 收件程序空转多久自动下班（秒，默认 3600 也就是 1 小时）。
#   ⚠️ 下班是有代价的：没心跳 = 别人的地址簿里你是「离线」= 传话默认发不过来。
#      安静时段恰恰最常需要传话。所以这个数字调大一点、或者干脆填 0 让它常驻，
#      都是合理选择 —— 它 5 秒扫一次文件、不思考、不花词元。
#   填 0 = 永不因空转下班。窗口关掉、代号注销时它照样会走，跟这个无关。
idle_exit_seconds=3600
CFGEOF
  fi
  if [ ! -f "$INDEX_FILE" ]; then
    cat > "$INDEX_FILE" <<'EOF'
# 会话索引

日常寻址只认这张表。编号永不变，代号你随时可改。

| 会话编号 | 代号 | 系统名 | 目录 | 在哪些组 | 最后活跃 |
|---|---|---|---|---|---|
EOF
  fi
}

# 确保我自己的会话目录存在
t_ensure_mydir() {
  mkdir -p "$(t_myinbox)"
  touch "$(t_myinbox)/.done"
}

# ───────────────────────── 文件锁 ─────────────────────────
# 用 mkdir 实现，因为它在文件系统层面是原子的。
# 多个会话同时写索引/共识/传话记录时，靠这个防止互相覆盖。

LOCK_STALE_SEC=30   # 锁超过这个秒数认为是死锁（持锁进程已崩溃），强制清理

t_lock() {
  local name="$1" timeout="${2:-5}"
  local d="$LOCK_DIR/${name}.lock"
  local waited=0 max=$((timeout * 10))

  while ! mkdir "$d" 2>/dev/null; do
    # 检查是不是死锁：锁目录太老 → 持有者八成已经崩了
    # 判断这把锁是不是死锁。
    #
    # ⚠️ 不能只看 epoch 文件：拿锁分两步（先 mkdir，再写 epoch），中间有个空隙。
    #    别的进程正好在这个空隙里读，读到的是空 → 当成 0 → 算出「已存在十几亿秒」
    #    → 立刻把别人**正拿着**的锁删掉，于是两个进程同时在写。
    #    真机实测见过这条警告：「清理死锁 传话台（已存在 1787027407 秒）」——
    #    那个数就是整个纪元秒数，一眼就知道是读到空值。
    #    epoch 读不到就退回看锁目录自己的创建时间，那个在 mkdir 成功的瞬间就有了。
    local born age
    born="$(cat "$d/epoch" 2>/dev/null)"
    case "$born" in ''|*[!0-9]*) born="$(t_mtime "$d")" ;; esac
    if [ "${born:-0}" -gt 0 ]; then
      age=$(( $(t_epoch) - born ))
      if [ "$age" -gt "$LOCK_STALE_SEC" ]; then
        t_warn "清理死锁 ${name}（已存在 ${age} 秒）"
        rm -rf "$d"
        continue
      fi
    fi
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -ge "$max" ] && { t_warn "抢锁超时：$name"; return 1; }
  done

  echo "$$" > "$d/pid"
  t_epoch > "$d/epoch"
  return 0
}

t_unlock() { rm -rf "$LOCK_DIR/${1}.lock"; }

# 加锁执行一段命令，无论成败都会解锁
t_with_lock() {
  local name="$1"; shift
  t_lock "$name" || return 1
  "$@"
  local rc=$?
  t_unlock "$name"
  return $rc
}

# ───────────────────────── 会话在线状态 ─────────────────────────
# 数据来自 `claude agents --json`。这条命令有开销，同一次脚本执行内只调一次。

_AGENTS_CACHE=""
_AGENTS_WARNED=""
t_agents_json() {
  # Codex 的真实在线/忙碌状态由会话侧调用 list_threads 获取，shell 不伪造。
  # 返回空数组只是为了让沿用的 Markdown 账本函数继续工作。
  if [ "${TEAM_RUNTIME}" = "codex" ]; then
    printf '[]'
    return 0
  fi
  if [ -z "$_AGENTS_CACHE" ]; then
    # claude 命令不在查找路径里时，原来是静默返回空 —— 后果是所有人都显示
    # "已关闭"，看着像大家都下线了，其实是查不到。这种错必须说出来。
    # （实测：ssh 进去的环境 PATH 只有 4 个目录，claude 装在 /usr/local/bin 反而不在里面）
    if ! command -v claude >/dev/null 2>&1; then
      if [ -z "$_AGENTS_WARNED" ]; then
        echo "⚠️  找不到 claude 命令，无法查询谁在线 —— 下面所有人都会显示「状态未知」。" >&2
        echo "    这不代表他们真的离线。跑 ccdoctor 看怎么修。" >&2
        _AGENTS_WARNED=1
      fi
      _AGENTS_CACHE='[]'
    elif [ -f "${TEAM_ROOT}/.plugin/no-agents-json" ]; then
      # 这台机器的 claude 不认 agents --json，之前已经试过了。
      # 不再每条命令都去试一次：① 免得每次都刷一遍同样的警告；
      # ② 更要紧的是省掉白起一个 claude 进程 —— Windows 上起进程慢，
      #    每条命令都白等一次，累计起来很可观。
      # 谁在不在线本来就不看它（看心跳），它只影响「系统名 / 工作目录」这类附带信息。
      _AGENTS_CACHE='[]'
    else
      local out rc
      out="$(claude agents --json 2>&1)"; rc=$?
      if [ "$rc" -ne 0 ]; then
        if printf '%s' "$out" | grep -q "unknown option"; then
          # 是这个 claude 版本没有这个参数，不是偶发故障 —— 记下来，以后不再试。
          mkdir -p "${TEAM_ROOT}/.plugin" 2>/dev/null
          printf '%s\n' "$(printf '%s' "$out" | head -1)" > "${TEAM_ROOT}/.plugin/no-agents-json" 2>/dev/null
          if [ -z "$_AGENTS_WARNED" ]; then
            echo "ℹ️  你这个 claude 版本不支持 agents --json，「系统名 / 工作目录」这类附带信息查不到。" >&2
            echo "    不影响用：谁在不在线看的是心跳，不看它。这条只提示这一次。" >&2
            _AGENTS_WARNED=1
          fi
        elif [ -z "$_AGENTS_WARNED" ]; then
          echo "⚠️  claude agents 执行失败（退出码 ${rc}），无法查询谁在线。" >&2
          echo "    错误：$(printf '%s' "$out" | head -1)" >&2
          _AGENTS_WARNED=1
        fi
        _AGENTS_CACHE='[]'
      else
        _AGENTS_CACHE="$out"
      fi
    fi
  fi
  printf '%s' "$_AGENTS_CACHE"
}

# 某个编号当前状态：在线空闲 / 在线忙碌 / 已关闭
t_status_of() {
  local id="$1"
  if [ "${TEAM_RUNTIME}" = "codex" ]; then
    echo "可由 Codex 唤醒"
    return 0
  fi
  local st
  st="$(t_agents_json | jq -r --arg id "$id" '.[] | select(.sessionId==$id) | .status' 2>/dev/null | head -1)"
  # 查不到有两种可能，必须分开说：真的关了，还是我们压根查不了。
  # 说成"已关闭"等于替对方下了一个可能是错的结论。
  if [ -z "$st" ] && [ -n "$_AGENTS_WARNED" ]; then
    echo "状态未知"
    return
  fi
  case "$st" in
    idle)    echo "在线空闲" ;;
    busy)    echo "在线忙碌" ;;
    waiting) echo "等人回话" ;;   # 卡在等用户输入 —— 开着的，但要人点了才会继续
    "")      echo "已关闭" ;;
    *)       echo "在线($st)" ;;  # 将来新增状态时如实显示，不要一律当成已关闭
  esac
}

# 某个编号当前的系统名（mary-86 这种，会变，只作参考）
t_sysname_of() {
  if [ "${TEAM_RUNTIME}" = "codex" ]; then
    printf 'Codex'
    return 0
  fi
  t_agents_json | jq -r --arg id "$1" '.[] | select(.sessionId==$id) | .name // ""' 2>/dev/null | head -1
}

# 某个编号当前的工作目录
t_cwd_of() {
  if [ "${TEAM_RUNTIME}" = "codex" ]; then
    _index_field "$1" 4
    return 0
  fi
  t_agents_json | jq -r --arg id "$1" '.[] | select(.sessionId==$id) | .cwd // ""' 2>/dev/null | head -1
}

# ───────────────────────── 会话索引读写 ─────────────────────────
# 索引是 markdown 表格，人能直接看。程序用 awk 解析。
# 列：编号 | 代号 | 系统名 | 目录 | 在哪些组 | 最后活跃

# 取某一行的第 N 列（N 从 1 开始）
_index_field() {
  local id="$1" col="$2"
  awk -F'|' -v id="$id" -v c="$((col + 1))" '
    /^\|/ && $2 !~ /^[[:space:]]*(会话编号|-+)[[:space:]]*$/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      if ($2 == id) { gsub(/^[ \t]+|[ \t]+$/, "", $c); print $c; exit }
    }' "$INDEX_FILE" 2>/dev/null
}

# 编号 → 代号
t_alias_of() { _index_field "$1" 2; }

# 编号 → 它加入的组（逗号分隔）
t_groups_of() { _index_field "$1" 5; }

# 代号 → 编号（找不到返回空）
t_id_of() {
  local alias="$1"
  awk -F'|' -v a="$alias" '
    /^\|/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
      if ($3 == a && $2 != "会话编号" && $2 !~ /^-+$/) { print $2; exit }
    }' "$INDEX_FILE" 2>/dev/null
}

# 这个代号是否已被别人占用（查重用）
t_alias_taken_by_other() {
  local alias="$1" me="$2"
  local owner; owner="$(t_id_of "$alias")"
  [ -n "$owner" ] && [ "$owner" != "$me" ] && printf '%s' "$owner"
}

# 索引里有没有这个编号
t_index_has() { [ -n "$(t_alias_of "$1")" ]; }

# 写入或更新一行（调用方负责加锁）
t_index_upsert() {
  local id="$1" alias="$2" groups="$3"
  local sysname; sysname="$(t_sysname_of "$id")"

  # 工作目录：**写自己的时候一律用 $PWD**，不要绕道去问 claude agents。
  #
  # ⚠️ 原来只靠 t_cwd_of（走 claude agents --json）取，那条路在某些 Claude Code 版本上根本不通
  #    ——公司 Windows 上实测报「unknown option '--json'」，于是目录一列写成「-」。
  #    而目录是判定「谁跟我是同一个端」的唯一依据，它一空，同角色识别就整个失效。
  #    自己的工作目录自己最清楚，没有比 $PWD 更可靠的来源。
  local cwd=""
  if [ "$id" = "$(t_sid)" ]; then
    cwd="$PWD"
  else
    cwd="$(t_cwd_of "$id")"
  fi
  [ -z "$cwd" ] && cwd="$(_index_field "$id" 4)"
  local row="| $id | $alias | ${sysname:--} | ${cwd:--} | ${groups:--} | $(t_now) |"
  local tmp="$INDEX_FILE.tmp.$$"

  if t_index_has "$id"; then
    awk -F'|' -v id="$id" -v row="$row" '
      /^\|/ { split($0, a, "|"); gsub(/^[ \t]+|[ \t]+$/, "", a[2])
              if (a[2] == id) { print row; next } }
      { print }' "$INDEX_FILE" > "$tmp"
  else
    cp "$INDEX_FILE" "$tmp"
    echo "$row" >> "$tmp"
  fi
  mv "$tmp" "$INDEX_FILE"
}

# 从索引删掉一行。
# ⚠️ 正常流程【已经不再调它】：退出全部组、组被结案，都只清空组籍、把代号留着
#    （代号是窗口的身份，不是组籍）。留着这个函数是给人工清理用的。
t_index_remove() {
  local id="$1" tmp="$INDEX_FILE.tmp.$$"
  awk -F'|' -v id="$id" '
    /^\|/ { split($0, a, "|"); gsub(/^[ \t]+|[ \t]+$/, "", a[2])
            if (a[2] == id) next }
    { print }' "$INDEX_FILE" > "$tmp"
  mv "$tmp" "$INDEX_FILE"
}

# 列出索引里所有编号
t_index_all_ids() {
  awk -F'|' '/^\|/ { gsub(/^[ \t]+|[ \t]+$/, "", $2)
    if ($2 != "会话编号" && $2 !~ /^-+$/ && $2 != "") print $2 }' "$INDEX_FILE" 2>/dev/null
}

# ───────────────────────── 讨论组 ─────────────────────────

# 共识里有几行【真正的约定】。
# 必须排掉模板自带的东西，否则一个全空的共识也会被算成"有内容" ——
# 分节骨架里的括号说明文字长得像正文，实测因此让「共识不能为空」那道门槛形同虚设。
# 排除：空行、标题、引用块、分隔线、以及整行被中文圆括号包起来的占位说明。
t_consensus_real_lines() {
  grep -vE '^[[:space:]]*$|^#|^>|^-{3,}[[:space:]]*$|^[[:space:]]*（.*$|^[[:space:]]*否则下一个人会从同样的地方' "$1" 2>/dev/null \
    | wc -l | tr -d ' '
}

t_group_dir()     { printf '%s/%s' "$GROUPS_DIR" "$1"; }
t_group_members() { printf '%s/成员.md' "$(t_group_dir "$1")"; }
t_group_consensus(){ printf '%s/共识.md' "$(t_group_dir "$1")"; }
t_group_log()     { printf '%s/传话记录.md' "$(t_group_dir "$1")"; }

t_group_exists() { [ -d "$(t_group_dir "$1")" ]; }

# 组名合法性：会直接当文件夹名，不能含路径分隔符等
t_check_groupname() {
  local g="$1"
  [ -n "$g" ] || t_die "组名不能为空"
  case "$g" in
    */*|*\\*|*:*|.*|*..*) t_die "组名不能含 / \\ : 或以点开头：$g" ;;
  esac
  [ ${#g} -le 60 ] || t_die "组名太长（超过 60 字符）"
}

# 列出所有组
t_all_groups() {
  [ -d "$GROUPS_DIR" ] || return 0
  find "$GROUPS_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}

# 组内所有成员编号
t_members_of() {
  local f; f="$(t_group_members "$1")"
  [ -f "$f" ] || return 0
  awk -F'|' '/^\|/ { gsub(/^[ \t]+|[ \t]+$/, "", $2)
    if ($2 != "会话编号" && $2 !~ /^-+$/ && $2 != "") print $2 }' "$f"
}

t_is_member() {
  local g="$1" id="$2"
  t_members_of "$g" | grep -qxF "$id"
}

# 成员在组内负责什么
t_member_role() {
  local f; f="$(t_group_members "$1")"
  awk -F'|' -v id="$2" '/^\|/ {
    gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
    if ($2 == id) { print $3; exit } }' "$f" 2>/dev/null
}

# 建组骨架（调用方负责加锁和查重）
t_group_init() {
  local g="$1" d; d="$(t_group_dir "$g")"
  mkdir -p "$d"
  [ -f "$(t_group_members "$g")" ] || cat > "$(t_group_members "$g")" <<'EOF'
# 成员

只记会话编号。代号会变，显示时去会话索引翻译。

| 会话编号 | 在组内负责 | 加入时间 |
|---|---|---|
EOF
  [ -f "$(t_group_consensus "$g")" ] || cat > "$(t_group_consensus "$g")" <<EOF
# ${g} · 共识

> **这里只装人同意过的内容。** AI 自己得出的结论、另一个成员的附议、全组没人反对、
> 问过人但人还没回答 —— 都不算人同意，一律不许写进来。
>
> 写的是**当前有效的约定**，不是流水账。约定变了就直接改这里，不要在末尾追加"某某改了"。
> 中途加入的人只读这一份就要能追上进度。

## 分工

（谁负责哪一块）

## 需求澄清

（需求文档里含糊或写错的地方，在这里定死。不是设计需求，是把需求说准）

## 架构设计

（整体怎么搭）

## 技术设计

（各端怎么做；端与端之间的交接约定也写这里 —— 交接错一个字往往是静默失败，写清楚）

## 明确不做的

（本期范围外、已决定不做的。不写下来会被反复重新讨论，或者被某个端顺手做了）

## 验收口径

（**设计如此、不是缺陷**的那些。取舍带来的后果，测试不提前知道就会报成 bug）

## 已作废的结论

（**光删掉不够** —— 要写明这条为什么废、正确的是什么。
否则下一个人会从同样的地方重新推一遍，得出同样的错）

---

（还没有任何约定。用 ccpin 写入第一条。）
EOF
  [ -f "$(t_group_log "$g")" ] || cat > "$(t_group_log "$g")" <<'EOF'
# 传话记录

只追加，不修改。回执图例：前一个符号=已送达，后一个=已处理；✓ 达成，· 未达成。

| 时间 | 消息号 | 发件 | 收件 | 内容 | 回执 |
|---|---|---|---|---|---|
EOF
}

# 生成消息号：时分秒 + 三位随机，同组内基本不会撞
t_msgid() { printf '%s-%03d' "$(date '+%H%M%S')" "$((RANDOM % 1000))"; }

t_group_fulltext() { printf '%s/传话全文.md' "$(t_group_dir "$1")"; }

# 把消息全文另存一份 —— 收件人删掉信箱文件之后，这里是唯一的完整副本
#
# 为什么必须有：守则教人处理完消息就删信箱文件，给的理由是
# 「内容在传话记录里有完整一份，删了不丢」—— **那句话曾经是假的**。
# 传话记录为了排版把正文截到 45 字，删掉信箱文件正文就真没了。
# 实测代价：一条三段式回复被读了前两段就删，第三段永久丢失，只能请对方重发。
# **一个不成立的理由，授权了一个不可逆的动作** —— 这比谁没读全严重得多。
t_log_full() {
  local g="$1" mid="$2" from="$3" to="$4" purpose="$5" body="$6"
  local f; f="$(t_group_fulltext "$g")"
  [ -f "$f" ] || printf '# 传话全文\n\n只追加，不修改。传话记录里的正文为排版截断过，**这里是完整副本**。\n收件人处理完会删掉自己信箱里的那份，删了之后这里就是唯一的一份。\n\n' > "$f"
  {
    printf -- '---\n\n## %s ｜ %s → %s ｜ %s\n\n' "$mid" "$from" "$to" "$(t_now)"
    [ -n "$purpose" ] && printf -- '**发送目的**：%s\n\n' "$purpose"
    printf '%s\n\n' "$body"
  } >> "$f"
}

# 往传话记录追加一行（调用方负责加锁）
t_log_append() {
  local g="$1" mid="$2" from="$3" to="$4" content="$5" ack="$6"
  # 内容里的竖线会撑坏表格，换成全角
  content="${content//|/｜}"
  content="${content//$'\n'/ }"
  # 截断只是为了这张表还能读；**完整正文在「传话全文.md」里**，不是在消息文件里
  # （消息文件会被收件人删掉，见 t_log_full 上面那段说明）
  [ ${#content} -gt 45 ] && content="${content:0:45}…"
  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$(t_now)" "$mid" "$from" "$to" "$content" "${ack:--}" >> "$(t_group_log "$g")"
}

# 更新回执。pos=1 标「已送达」，pos=2 标「已处理」。
# 回执列格式形如：安卓✓✓ ios·· 鸿蒙✓·
# 调用方负责加锁。
t_ack_update() {
  local g="$1" mid="$2" who="$3" pos="$4"
  local f; f="$(t_group_log "$g")"
  [ -f "$f" ] || return 1
  local tmp="$f.tmp.$$"

  # macOS 的 awk 对多字节字符（✓ ·）按字节处理，靠不住。
  # 所以只用 awk 定位和整列替换，字符级拼装交给 bash（已实测按字数切）。

  # 1. 取出这条消息当前的回执列
  local cur
  cur="$(awk -F'|' -v mid="$mid" '/^\|/ {
      m=$3; gsub(/^[ \t]+|[ \t]+$/, "", m)
      if (m == mid) { a=$7; gsub(/^[ \t]+|[ \t]+$/, "", a); print a; exit } }' "$f")"
  [ -n "$cur" ] || return 1
  [ "$cur" = "-" ] && cur=""

  # 2. 在 bash 里改（UTF-8 安全）
  local out="" found=0 item marks a b np
  for item in $cur; do
    if [[ "$item" == "$who"* ]]; then
      marks="${item#"$who"}"
      a="${marks:0:1}"; b="${marks:1:1}"
      [ -z "$a" ] && a="·"; [ -z "$b" ] && b="·"
      if [ "$pos" = "1" ]; then a="✓"; else b="✓"; fi
      item="${who}${a}${b}"
      found=1
    fi
    out="${out:+$out }$item"
  done
  if [ "$found" -eq 0 ]; then
    if [ "$pos" = "1" ]; then np="${who}✓·"; else np="${who}·✓"; fi
    out="${out:+$out }$np"
  fi

  # 3. 整列写回
  awk -F'|' -v mid="$mid" -v newack="$out" '
    BEGIN { OFS="|" }
    /^\|/ {
      m=$3; gsub(/^[ \t]+|[ \t]+$/, "", m)
      if (m == mid) { $7=" " newack " "; print; next }
    }
    { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ───────────────────────── 消息投递 ─────────────────────────
# 往某个会话的收件箱丢一条消息。ccjoin 通知组员、cctell 发消息都走这里。
# 参数：收件人编号 组名 发件人代号 发件人编号 正文 深度 紧急(是/否) 类型(普通/系统)

t_deliver() {
  local to_id="$1" group="$2" from_alias="$3" from_id="$4" body="$5"
  local depth="${6:-0}" urgent="${7:-否}" kind="${8:-普通}" mid="${9:-}"
  local need_decision="${10:-否}"
  local purpose="${11:-}"

  local inbox="$SESSIONS_DIR/$to_id/收件箱"
  mkdir -p "$inbox"

  local urgent_tag=""
  [ "$urgent" = "是" ] && urgent_tag="-急"
  # 文件名里的组名和代号要去掉可能撑坏路径的字符
  local safe_group="${group//\//_}" safe_from="${from_alias//\//_}"
  # 文件名带上消息号 —— 它本身就是「时分秒 + 随机三位」，天生不重样。
  #
  # 早先是「时间戳 + 组 + 谁发的」，同一秒内多条就撞名，靠一个「文件在不在」的循环加序号。
  # 那是**先查后写**：两个进程同时看到「不在」，就都挑中同一个名字，后写的把先写的盖掉，
  # 而且一声不响 —— 消息直接没了。真机实测：5 条并发只有 3 条进了对方信箱。
  # 下面那圈 noclobber 是兜底：它靠系统的「文件已存在就失败」来判定，中间没有空隙。
  local tag="${mid:-$$-$(t_epoch)}"
  local file="$inbox/$(t_stamp)-${safe_group}-来自${safe_from}${urgent_tag}-${tag}.md"
  local n=1
  until ( set -o noclobber; : > "$file" ) 2>/dev/null; do
    file="$inbox/$(t_stamp)-${safe_group}-来自${safe_from}${urgent_tag}-${tag}-$n.md"
    n=$((n + 1))
    [ "$n" -gt 50 ] && break
  done

  cat > "$file" <<EOF
---
组: $group
消息号: ${mid:-无}
来自: $from_alias
来自编号: $from_id
收件编号: $to_id
时间: $(date '+%Y-%m-%d %H:%M:%S')
时间戳: $(t_epoch)
接力深度: $depth
紧急: $urgent
类型: $kind
需决策: $need_decision
发送目的: ${purpose:-未说明}
---

$body
EOF
  printf '%s' "$file"
}

# ───────────────────────── 收件程序状态 ─────────────────────────

t_watcher_pidfile() { printf '%s/.watcher.pid' "$(t_mydir)"; }

# 收件程序脚本在哪。优先用开窗口时记下的那条（那是**装好的插件**的位置，
# 而当前脚本有可能是从源码仓库跑的）；但那条路径带版本号，升级后老目录若被清掉就成了死路
# —— 打给人的却是一条跑不通的命令，人照着起不来，从此静默离线。所以先验一眼再用。
t_bin_dir() {
  local f="${TEAM_ROOT}/.plugin/binpath" p=""
  [ -f "$f" ] && p="$(cat "$f" 2>/dev/null)"
  if [ -n "$p" ] && [ -f "$p/watcher.sh" ]; then printf '%s' "$p"; else printf '%s' "$SKILL_DIR/bin"; fi
}

t_watcher_running() {
  # Codex 由原生 send_message_to_thread 直接唤醒目标任务，不运行轮询进程。
  # 对沿用的脚本来说，这等价于“收件程序始终在岗”。
  [ "${TEAM_RUNTIME}" = "codex" ] && return 0
  local f; f="$(t_watcher_pidfile)"
  [ -f "$f" ] || return 1
  local p; p="$(cat "$f" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# ───────────────────────── 显示辅助 ─────────────────────────

# 编号 → 好看的名字（优先代号，没有就用系统名，再没有就截短的编号）
t_display() {
  local id="$1" a
  a="$(t_alias_of "$id")"
  if [ -n "$a" ]; then printf '%s' "$a"
  else
    a="$(t_sysname_of "$id")"
    if [ -n "$a" ]; then printf '%s(未收编)' "$a"
    else printf '%s…' "${id:0:8}"; fi
  fi
}

# 我当前加入的组，一行一个
t_my_groups() {
  local g; g="$(t_groups_of "$(t_sid)")"
  [ -z "$g" ] || [ "$g" = "-" ] && return 0
  printf '%s' "$g" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

# 我在不在协作中（决定要不要跑那些后台机制）
# 「在协作里」= 这个窗口**登记过代号**。
#
# ⚠️ 判据从「在不在讨论组里」改成「有没有代号」：代号是窗口的身份，而
#    **登记代号就等于接入传话台** —— 一个不在任何组、但有代号的窗口，随时可能
#    有人传话给它，收件程序必须在岗，否则它在别人眼里永远是「离线」。
#    没登记代号的窗口仍然什么都不跑，「零影响」那条承诺照旧成立。
t_in_collab() { [ -n "$(t_alias_of "$(t_sid)")" ]; }

# 传话台的回执：直接追加一行到当日记录。
# 不另开文件是有意的 —— 当日记录每天滚存、只留 7 天，回执跟着它走，
# 就不用再给回执单独配一套清理。
t_talk_ack() {   # $1=消息号 $2=谁 $3=已送达|已处理
  t_lock 传话台 8 || return 1
  t_talk_roll
  printf '## %s · 回执 · %s · %s：%s\n\n' "$(date '+%H:%M:%S')" "$1" "$3" "$2" >> "$(t_talk_log)"
  t_unlock 传话台
}

# ───────────────────────── 找在跑的收件程序（跨系统） ─────────────────────────
#
# 为什么单独包一层：
#   1. Windows 的 Git Bash **没有 pgrep**，那边只能翻进程列表
#   2. 插件化之后路径里多了一层版本号：
#        插件版  …/plugins/cache/xbcx/team/<版本号>/bin/watcher.sh
#        老装法  …/.claude/skills/team/bin/watcher.sh
#      模式写成 team/.*bin/watcher.sh 两种布局都能匹配到
# ⚠️ 要排掉「自己」和「叫自己的那个进程」。
#    匹配靠的是整条命令行，所以**任何一条命令只要文字里出现了 watcher.sh 这串字，
#    执行它的那个 shell 自己就会被算成一个收件程序**。
#    实测撞到过：跑一条含该路径的清理命令后，体检报「有 1 个在跑」，而实际一个都没有。
# ⚠️ 光靠「命令行里出现过 watcher.sh」会认错人。
#    匹配的是整条命令行，所以**任何一条命令只要文字里带了这个路径，
#    执行它的那个 shell 自己就会被算成一个收件程序**（连它的祖先进程也一样）。
#    实测撞到过：跑一条含该路径的清理命令之后，体检报「有 1 个在跑」，而实际一个都没有。
#
#    所以先粗筛、再逐个核实：**这个进程的命令本身是不是在跑这个脚本**——
#    也就是命令行头两个词里，有没有一个是以 /watcher.sh 结尾的。
#    「bash …/bin/watcher.sh」算，「bash -c 一大段里提到了 …/bin/watcher.sh」不算。
t_watcher_pids() {
  local raw pid args
  if command -v pgrep >/dev/null 2>&1; then
    raw="$(pgrep -f "team/.*bin/watcher\.sh" 2>/dev/null)"
  else
    raw="$(ps -ef 2>/dev/null | grep -E "team/.*bin/watcher\.sh" | grep -v grep | awk '{print $2}')"
  fi
  for pid in $raw; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    args="$(ps -p "$pid" -o args= 2>/dev/null)"
    # 取不到命令行（某些系统上 ps 参数不同）就按老办法保留，宁可多报不漏报
    if [ -z "$args" ]; then printf '%s\n' "$pid"; continue; fi
    # ⚠️ 必须【只看头两个词】。直接对整条命令行做通配会在任意位置命中 ——
    #    一条 `bash -c '… bash /路径/watcher.sh &  …'` 的命令行里也含这个路径，
    #    那样就把发问的 shell 自己算了进来（实测撞到过）。
    set -- $args
    case "$1" in */watcher.sh) printf '%s\n' "$pid"; continue ;; esac
    case "$2" in */watcher.sh) printf '%s\n' "$pid" ;; esac
  done
}

# ───────────────────────── 跨系统的时间与文件操作 ─────────────────────────
#
# macOS 用的是 BSD 版命令，Windows 的 Git Bash 用的是 GNU 版，同一件事写法不同。
# 下面几个统一包一层：先按 BSD 写法试，不行再按 GNU 写法试。
# **新代码一律用这几个函数，不要再直接写 stat -f / date -r / sed -i**。

# ───────────────────────── 传话台：按日分割的记录 ─────────────────────────
#
# 传话台不是讨论组：没有成员、没有共识，**不放在协作组目录里**，所以
# ccgroups / ccwho / 开窗口的协作现状天然看不见它。它只有一样东西 —— 记录。
#
# 当日那份**文件名固定**（传话记录.md），隔天才改名成「传话记录-日期.md」。
# 固定名的好处：任何地方引用「传话记录」永远是同一个路径，不用算今天几号。

# ── 每台机器自己的配置 ──
#
# 放在 ${TEAM_ROOT}/.plugin/config，一行一条 key=value，井号开头是注释。
# 优先级：环境变量 > 这个文件 > 默认值。
# 为什么要有文件：环境变量只在当次进程里有效，关掉窗口就没了；
# 而「这台机器传话记录留几天」是**跟着机器走**的设置，各人各环境可以不一样。
t_conf() {   # $1=键名  $2=默认值
  local f v; f="${TEAM_ROOT}/.plugin/config"
  [ -f "$f" ] || { printf '%s' "$2"; return 0; }
  v="$(awk -F= -v k="$1" '
        /^[[:space:]]*#/ { next }
        { key=$1; gsub(/^[ \t]+|[ \t]+$/,"",key)
          if (key == k) { sub(/^[^=]*=/,""); gsub(/^[ \t]+|[ \t]+$/,"",$0); print; exit } }' "$f" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}

# 传话记录保留几天。改法：写进 ${TEAM_ROOT}/.plugin/config 的 talk_keep_days，
# 或临时用环境变量 TEAM_TALK_KEEP_DAYS 覆盖一次。
TEAM_TALK_KEEP_DAYS="${TEAM_TALK_KEEP_DAYS:-$(t_conf talk_keep_days 7)}"
TEAM_TALK_LOCK_WAIT="${TEAM_TALK_LOCK_WAIT:-30}"  # 抢传话记录这把锁最多等几秒（自测会调小它来造「抢不到」）

t_talk_dir() { printf '%s/传话台' "$TEAM_ROOT"; }
t_talk_log() { printf '%s/传话记录.md' "$(t_talk_dir)"; }

# 滚存 + 保证当日文件存在。**调用方必须已经拿到「传话台」这把锁。**
#
# ⚠️ 按哪个日期改名：按**文件头一行自己声明的日期**，不用「昨天」也不用文件修改时间。
#    · 用「昨天」会错 —— 中间可能空了好几天
#    · 用修改时间会错 —— 复制、同步、备份都会改掉它，而写在文件里的日期不会变
t_talk_roll() {
  local d f today old target n m
  d="$(t_talk_dir)"; mkdir -p "$d" 2>/dev/null
  f="$(t_talk_log)"
  today="$(date '+%Y-%m-%d')"

  if [ -f "$f" ]; then
    old="$(sed -n '1s/^# 传话记录 · //p' "$f" | tr -d ' \r')"
    if [ -n "$old" ] && [ "$old" != "$today" ]; then
      target="${d}/传话记录-${old}.md"; n=2
      while [ -e "$target" ]; do target="${d}/传话记录-${old}-${n}.md"; n=$((n + 1)); done
      mv "$f" "$target"
    elif [ -z "$old" ]; then
      # 头一行认不出日期（被人手改过、或半截文件）→ 按修改时间另存，
      # 绝不覆盖、也绝不丢：宁可多一个「来路不明」的文件，不能吞掉记录
      m="$(t_fmt_mtime "$f" '+%Y-%m-%d')"; [ -n "$m" ] || m="未知日期"
      target="${d}/传话记录-${m}-来路不明.md"; n=2
      while [ -e "$target" ]; do target="${d}/传话记录-${m}-来路不明-${n}.md"; n=$((n + 1)); done
      mv "$f" "$target"
    fi
  fi

  if [ ! -f "$f" ]; then
    printf '# 传话记录 · %s\n\n> 当日固定名；隔天自动改名成「传话记录-日期.md」。历史保留 %s 天。\n> 正文一律全文照录，不截断。\n\n' \
      "$today" "$TEAM_TALK_KEEP_DAYS" > "$f"
  fi

  # 顺手清过期的历史文件（当日那份永远不删）
  find "$d" -maxdepth 1 -name '传话记录-*.md' -type f -mtime "+${TEAM_TALK_KEEP_DAYS}" -delete 2>/dev/null

  # 把之前抢不到锁、暂存在「待入账」里的补进来（按时间顺序），补完就删。
  # 这一步必须在锁里做 —— 调用方已经持有「传话台」这把锁了。
  local pend pf
  pend="${d}/待入账"
  if [ -d "$pend" ]; then
    while IFS= read -r pf; do
      [ -n "$pf" ] || continue
      cat "$pf" >> "$f" 2>/dev/null && rm -f "$pf"
    done <<< "$(find "$pend" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)"
    rmdir "$pend" 2>/dev/null
  fi
}

# 追加一条记录。$1=类型 $2=消息号 $3=发件代号 $4=收件代号 $5=目的 $6=正文全文
#                $7=发件编号 $8=收件编号
#
# ⚠️ 编号也要记，不能只记代号：「这条能不能回」那道门是拿这里的编号做凭据的，
#    而代号会改名、会被顶掉 —— 凭据不能建在会变的东西上。
t_talk_append() {
  # ⚠️ 抢不到锁**绝不能把记录丢掉**。
  #    实测（公司 Windows，五条并发）：那台机器进程起得慢，一次抢锁超过 8 秒，
  #    于是那条只打了句警告就没记 —— 而调用方通常把输出丢进 /dev/null，
  #    结果是「消息发出去了、记录里没有」，**静默丢账**。
  #    现在：等久一点；仍抢不到就落进「待入账」，下次任何一次成功写入时补进去。
  if ! t_lock 传话台 "$TEAM_TALK_LOCK_WAIT"; then
    local pend; pend="$(t_talk_dir)/待入账"
    mkdir -p "$pend" 2>/dev/null
    {
      printf '## %s · %s → %s · %s\n\n' "$(date '+%H:%M:%S')" "$3" "$4" "$1"
      printf -- '- 消息号：%s\n' "$2"
      printf -- '- 发件编号：%s\n' "${7:-未知}"
      printf -- '- 收件编号：%s\n' "${8:-未知}"
      printf -- '- 目的：%s\n\n' "$5"
      printf '%s\n\n' "$6"
      printf -- '---\n\n'
    } > "${pend}/$(t_stamp)-${2}.md" 2>/dev/null
    t_warn "传话记录正被占用，这条先记进「待入账」，下次写入时自动补上（消息本身已经发出去了）"
    return 0
  fi
  t_talk_roll
  {
    printf '## %s · %s → %s · %s\n\n' "$(date '+%H:%M:%S')" "$3" "$4" "$1"
    printf -- '- 消息号：%s\n' "$2"
    printf -- '- 发件编号：%s\n' "${7:-未知}"
    printf -- '- 收件编号：%s\n' "${8:-未知}"
    printf -- '- 目的：%s\n\n' "$5"
    printf '%s\n\n' "$6"
    printf -- '---\n\n'
  } >> "$(t_talk_log)"
  t_unlock 传话台
}

# 把记录里每条消息摘成一行：消息号|投递或回复|发件编号|收件编号
# 当日和历史都扫（隔天再回也算数；历史只留 7 天，更早的自然就回不了了）
t_talk_index() {
  local d f
  d="$(t_talk_dir)"; [ -d "$d" ] || return 0
  for f in "$d"/传话记录.md "$d"/传话记录-*.md; do
    [ -f "$f" ] || continue
    awk '
      /^## / {
        kind = ""; mid = ""; from = ""; to = ""
        if ($0 ~ /传话台投递/) kind = "投递"
        else if ($0 ~ /传话台回复/) kind = "回复"
        next
      }
      /^- 消息号：/   { mid  = $0; sub(/^- 消息号：/,   "", mid);  next }
      /^- 发件编号：/ { from = $0; sub(/^- 发件编号：/, "", from); next }
      /^- 收件编号：/ {
        to = $0; sub(/^- 收件编号：/, "", to)
        if (mid != "" && kind != "") print mid "|" kind "|" from "|" to
        next
      }
    ' "$f"
  done
}

# ───────────────────────── 在册记录多久没动静了 ─────────────────────────
#
# 心跳只在收件程序跑着时才有，所以「从没起过收件程序」的老记录没有心跳文件。
# 那种情况退回去看这个窗口名下还有什么东西被动过（名片、信箱），取最新的一个。
# 全都没有 → 给一个很大的值，当成很久没动静。
t_last_seen_age() {   # $1=编号 → 多少秒没动静
  local id="$1" d newest=0 m f
  d="$SESSIONS_DIR/$id"
  for f in "$d/.beat" "$d/.beat-last" "$d/名片.md" "$d/收件箱" "$d"; do
    [ -e "$f" ] || continue
    m="$(t_mtime "$f")"
    [ "$m" -gt "$newest" ] && newest="$m"
  done
  [ "$newest" -eq 0 ] && { printf '%s' 999999999; return 0; }
  printf '%s' "$(( $(t_epoch) - newest ))"
}

# 哪些在册记录可以清：**不在任何组 + 长期没动静**。
# 在组里的绝不清（删了组里就剩一个没人认得的编号）；在线的绝不清。
TEAM_STALE_DAYS="${TEAM_STALE_DAYS:-7}"

t_stale_index_ids() {
  local id gs age
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    gs="$(t_groups_of "$id")"
    [ "$gs" = "-" ] && gs=""
    [ -n "$gs" ] && continue                      # 还在组里 → 不清
    t_is_online "$id" && continue                 # 在线 → 不清
    age="$(t_last_seen_age "$id")"
    [ "$age" -ge $(( TEAM_STALE_DAYS * 86400 )) ] && printf '%s\n' "$id"
  done <<< "$(t_index_all_ids)"
}

# 代号变更史：只追加、不删。用来回答「这个代号上周是谁」——
# 强制顶掉一条死记录之后，这是唯一能追回去的线索。
t_alias_history() { printf '%s/代号变更史.md' "$TEAM_ROOT"; }

t_alias_history_add() {   # $1=代号 $2=原编号 $3=新编号 $4=说明
  local f; f="$(t_alias_history)"
  [ -f "$f" ] || printf '# 代号变更史\n\n只追加，不删。用来回答「这个代号上周是谁」。\n\n| 时间 | 代号 | 原编号 | 新编号 | 说明 |\n|---|---|---|---|---|\n' > "$f"
  printf '| %s | %s | %s | %s | %s |\n' "$(t_now)" "$1" "${2:--}" "${3:--}" "$4" >> "$f"
}

# 回复台账：哪条投递已经回过了。回过就销账，第二次再回就拒。
t_reply_ledger() { printf '%s/%s/.replied' "$SESSIONS_DIR" "${1:-$(t_sid)}"; }

t_reply_used() { [ -e "$(t_reply_ledger)/$1" ]; }

t_reply_mark() {
  local d; d="$(t_reply_ledger)"
  mkdir -p "$d" 2>/dev/null
  : > "$d/$1" 2>/dev/null
  # 顺手清过期的。**保留期跟传话记录用同一个**：回过的账要是先没了，
  # 那条投递就又能回一次；反过来记录没了、台账还在，也只是白占地方。
  find "$d" -maxdepth 1 -type f -mtime "+${TEAM_TALK_KEEP_DAYS}" -delete 2>/dev/null
}

# ───────────────────────── 心跳：这个窗口还活着吗 ─────────────────────────
#
# 收件程序在岗时每 30 秒碰一下自己的心跳文件；90 秒内碰过就算在线。
#
# ⚠️ 为什么不写进会话索引那张表：索引是所有窗口**共享**的一张 markdown 表格，
#    每 30 秒抢一次锁去写，多开几个窗口就互相堵；而且那张表是给人看的，
#    会被刷得没法读。各窗口写各自的文件 = 零锁竞争、零冲突。
#    索引里「最后活跃」那一列不再用于任何在线判断，它的含义只是
#    「这行记录上次被写的时间」。
#
# ⚠️ 心跳只在收件程序跑着的时候才有。一个开着但没起收件程序的窗口 = 判定离线，
#    这是对的：它本来就收不到消息。
# ⚠️ 每一轮都写（收件程序 5 秒一轮）。原先设的是 30 秒一次，公司 Windows 上实测发现
#    那台机器起进程慢，**循环一轮的真实耗时会被拉长 3~4 倍**：配 1 秒实测变成 3~4 秒，
#    照这个倍数，30 秒会变成 60~120 秒，直接逼近甚至越过 90 秒那条判离线的线 ——
#    结果就是一个活着的窗口被判离线、传话发不过去。
#    写一次心跳只是把一个空文件的时间戳刷一下，代价可以忽略，没必要省这个。
TEAM_BEAT_EVERY="${TEAM_BEAT_EVERY:-5}"    # 多久写一次（秒）；默认等于一轮
TEAM_BEAT_STALE="${TEAM_BEAT_STALE:-90}"   # 多久没写就算离线（秒）

t_beat_file() { printf '%s/%s/.beat' "$SESSIONS_DIR" "${1:-$(t_sid)}"; }

# 收件程序正常下班时，心跳不是删掉而是改名存这里，当个「墓碑」。
# 为什么要留：心跳一删，「关掉的窗口」和「从没起过收件程序的窗口」就长得一模一样，
# 于是①地址簿对所有关掉的窗口都写「没起过收件程序」——这是句假话；
# ②「刚离线不到 10 分钟要再确认一次」那道闸算不出离线多久，直接失效，
#   一个 10 秒前才关掉的窗口，它的代号能被无声顶走。
t_beat_last_file() { printf '%s/%s/.beat-last' "$SESSIONS_DIR" "${1:-$(t_sid)}"; }

# 碰一下自己的心跳（只有收件程序会调）
t_beat() {
  local f; f="$(t_beat_file "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  : > "$f" 2>/dev/null
}

# 距上次心跳多少秒；从来没有过心跳返回 -1
t_beat_age() {
  # 过渡期要看两个名字：心跳文件刚从「.心跳」改名成「.beat」，
  # 而别的窗口可能还跑着旧版本、仍在写旧名字。只认新名字的话，
  # 一个活着的窗口会被判成离线 —— 传话直接发不过去。取两者里最新的那个。
  local f o a b; f="$(t_beat_file "$1")"; o="$(dirname "$f")/.心跳"
  a=-1; b=-1
  [ -f "$f" ] && a=$(( $(t_epoch) - $(t_mtime "$f") ))
  [ -f "$o" ] && b=$(( $(t_epoch) - $(t_mtime "$o") ))
  if   [ "$a" -lt 0 ]; then printf '%s' "$b"
  elif [ "$b" -lt 0 ]; then printf '%s' "$a"
  elif [ "$a" -le "$b" ]; then printf '%s' "$a"
  else printf '%s' "$b"; fi
}

t_is_online() {
  # Codex 原生任务消息能直接唤醒 idle 任务，不需要常驻 watcher。登记在索引中的
  # 线程先视为“可投递”，真正发送前由 Skill 用 list_threads 再核对是否已归档/不存在。
  if [ "${TEAM_RUNTIME}" = "codex" ]; then
    [ -n "$(t_alias_of "$1")" ]
    return
  fi
  local a; a="$(t_beat_age "$1")"
  [ "$a" -ge 0 ] && [ "$a" -le "$TEAM_BEAT_STALE" ]
}

# 离线了多久（秒）。在线判据只认心跳，这个函数管的是「离线时长」，所以多看一步墓碑：
#   心跳还在（被强杀 / 机器断电留下的）→ 用它，距今多久就是离线多久
#   心跳没了但有墓碑（正常下班）      → 用墓碑，那就是下班时刻
#   两个都没有                        → -1，是真没起过
# ⚠️ 别拿它当在线判据：正常下班 3 秒后墓碑年龄只有 3 秒，会被误判成在线。
t_offline_age() {
  local a f; a="$(t_beat_age "$1")"
  [ "$a" -ge 0 ] && { printf '%s' "$a"; return 0; }
  f="$(t_beat_last_file "$1")"
  [ -f "$f" ] || { printf '%s' "-1"; return 0; }
  printf '%s' "$(( $(t_epoch) - $(t_mtime "$f") ))"
}

# 给人看的一句话：在线 / 离线 23 分钟 / 从没起过收件程序
t_online_text() {
  local a
  if [ "${TEAM_RUNTIME}" = "codex" ]; then
    if [ -n "$(t_alias_of "$1")" ]; then
      printf '可由 Codex 原生消息唤醒'
    else
      printf '不在 Codex 协作地址簿中'
    fi
    return 0
  fi
  t_is_online "$1" && { printf '在线'; return 0; }
  a="$(t_offline_age "$1")"
  if   [ "$a" -lt 0 ];     then printf '离线（没起过收件程序）'
  elif [ "$a" -lt 60 ];    then printf '刚离线'
  elif [ "$a" -lt 3600 ];  then printf '离线 %s 分钟' "$((a / 60))"
  elif [ "$a" -lt 86400 ]; then printf '离线 %s 小时' "$((a / 3600))"
  else                          printf '离线 %s 天'   "$((a / 86400))"
  fi
}

# 文件的修改时间（epoch 秒）。取不到给 0。
t_mtime() {
  # ⚠️ 顺序不能反：Git Bash 上 stat -f 会把 %m 当成文件名去查文件系统，
  #    结果吐出一大段文件系统信息而不是时间戳，调用方拿到就报「需要整数」。
  #    先试 GNU 写法（Windows 能用），macOS 上它会失败再退回 BSD 写法。
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# 把一个 epoch 时间戳格式化。 $1=时间戳  $2=格式（如 '+%H:%M'）
t_fmt_epoch() {
  # 同理先试 GNU 写法：Git Bash 上 date -r 会把数字当文件名
  date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2" 2>/dev/null || echo ""
}

# 把某个文件的修改时间格式化。 $1=文件  $2=格式（如 '+%m-%d'）
t_fmt_mtime() {
  local m
  m="$(t_mtime "$1")"
  [ "$m" = "0" ] && { echo ""; return 0; }
  t_fmt_epoch "$m" "$2"
}

# 原地改文件。BSD 的 sed -i 必须跟一个备份后缀（用空串），GNU 的不能跟。
t_sed_inplace() {   # $1=sed 表达式  $2=文件
  sed -i '' "$1" "$2" 2>/dev/null || sed -i "$1" "$2" 2>/dev/null
}

# ───────────────────────── 真正的孤儿收件程序 ─────────────────────────
#
# ⚠️ 「机器上有几个收件程序」不能直接当成「有几个孤儿」。
#    这套东西的正常形态就是多会话协作 —— 组里 5 个人就该有 5 个收件程序在跑。
#    拿总数去跟「本会话该有 1 个」比，**只要真的多端跑起来，每个端都会误报**，
#    而且提示还会叫人去跑 ccclean，照做就是把别人正在用的进程当孤儿杀掉。
#    （2026-08-16 四端联调时实测到：5 个成员，每个端都看到「检测到 5 个，本会话只该有 1 个」）
#
# 判据跟 ccclean 一致：进程能在某个会话的 .watcher.pid 里找到主人，就不是孤儿；
# 找不到主人、或者主人那个会话已关闭，才算孤儿。
t_orphan_watcher_pids() {
  local pid owner d pf
  for pid in $(t_watcher_pids); do
    owner=""
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      pf="$d/.watcher.pid"
      [ -f "$pf" ] && [ "$(cat "$pf" 2>/dev/null)" = "$pid" ] && owner="$(basename "$d")"
    done <<< "$(find "$SESSIONS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)"
    if [ -z "$owner" ]; then
      printf '%s\n' "$pid"
    elif [ "$(t_status_of "$owner")" = "已关闭" ]; then
      printf '%s\n' "$pid"
    fi
  done
}

# 共识里【某一节】有没有实质内容。
# 判据跟 t_consensus_real_lines 一致：去掉标题、引用说明、空行、括号占位句之后还剩几行。
# $1=共识文件  $2=节名（不带「## 」）
t_consensus_section_lines() {
  awk -v want="$2" '
    /^## / { insec = (substr($0,4) == want) ? 1 : 0; next }
    insec { print }
  ' "$1" 2>/dev/null \
  | grep -vE '^[[:space:]]*$|^>|^-{3,}[[:space:]]*$|^[[:space:]]*（.*$' \
  | wc -l | tr -d ' '
}

# 共识里有没有这个节
t_consensus_has_section() {   # $1=共识文件  $2=节名
  grep -qxF "## $2" "$1" 2>/dev/null
}

# ───────────────────────── 角色（哪个端） ─────────────────────────
#
# 判定「谁跟我是同一个端」。
#
# ⚠️ 判据是【仓库地址】，不是目录名，也不是工程结构。三种办法实测对比过：
#
#   场景                          目录名   工程结构   仓库地址
#   Mac 上 waiqin_android          ✅       ✅        ✅
#   公司 Win 上 D:/…/waiqingx      ❌       ✅        ✅
#   worktree（10 个安卓分支目录）   ❌       ✅        ✅
#   PHP / Java / 总控 三个壳子      ✅       ❌        ✅   ← 壳子里没有任何构建文件
#   跨机器认成同一个端              ❌       ✅        ✅
#
# 只有仓库地址全场景通过：目录能改名、能建 worktree、能换机器换盘符，
# 而 clone 自同一个仓库这件事不会变。
# 实测：公司 Windows 的 D:\WorkSpack\android\waiqingx 与 Mac 的 waiqin_android，
# origin 都是 XbTerminal/waiqin.git —— 目录名毫无共同点，仓库地址一模一样。

# 从仓库地址里取出「组织/仓库名」那段。
# 取最后两段，并把 ssh 写法的冒号当成分隔符 ——
# 这样 https://host/A/b.git 和 root@host:A/b.git 都能得到同一个 A/b。
t_repo_key() {
  local u="${1%.git}"
  u="${u##*://}"                          # 去掉 https:// 之类
  u="${u#*@}"                             # 去掉 user@
  u="$(printf '%s' "$u" | tr ':' '/')"    # ssh 写法的冒号当分隔符
  u="${u%/}"
  local last="${u##*/}" rest="${u%/*}"
  printf '%s/%s' "${rest##*/}" "${last}"
}

# 仓库 → 角色。这张表是固化的，跨机器通用 ——
# 大家 clone 的是同一批仓库，所以同事拿到插件不用改任何东西。
t_role_of_repo() {
  case "$(t_repo_key "$1")" in
    XbTerminal/waiqin)    printf 'android' ;;
    ios/waiqin)           printf 'iOS' ;;
    waiqin/harmony)       printf 'harmony' ;;
    waiqin/ai_dev_php)    printf 'php' ;;
    waiqin/ai_dev_java|waiqin/legwork|waiqin/wq_web) printf 'java+react' ;;
    waiqin/ai_dev_full)   printf '总控' ;;
    *) return 1 ;;
  esac
}

# 目录 → 角色。先问仓库地址，问不出才退回目录名。
t_role_of_dir() {
  local d="$1" u r
  case "$d" in ""|-) return 0 ;; esac

  # 第一优先：仓库地址（worktree 也能取到，取到的跟主工程是同一个）
  if [ -d "$d" ]; then
    u="$(git -C "$d" remote get-url origin 2>/dev/null)"
    if [ -n "$u" ]; then
      r="$(t_role_of_repo "$u" 2>/dev/null)" && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    fi
  fi

  # 兜底：按目录名。用于「不是 git 仓库」或「仓库不在上面那张表里」的情况。
  case "$d" in
    *waiqin_android*)  printf 'android' ;;
    *waiqin_ios*)      printf 'iOS' ;;
    *waiqin_harmony*)  printf 'harmony' ;;
    *waiqin_php*)      printf 'php' ;;
    *waiqin_java*|*waiqin_web*) printf 'java+react' ;;
    *waiqin_full*)     printf '总控' ;;
    *)                 printf '%s' "$(basename "$d")" ;;
  esac
}

# 我自己是哪个角色
t_my_role() { t_role_of_dir "$PWD"; }

# ───────────────────────── 中文对齐 ─────────────────────────
#
# ⚠️ printf 的 %-20s 按【字符数】补空格，而中文在终端里占两格 ——
#    中英混排必然错位。这里自己算显示宽度。
#
# 算法：UTF-8 里 ASCII 占 1 字节、中文占 3 字节。
#       显示宽度 = 字符数 + (字节数 - 字符数) / 2
#       例：「组名」2 字符 6 字节 → 2 + 2 = 4 格；「team」4 字符 4 字节 → 4 格。
t_dwidth() {
  local s="$1" chars bytes
  chars=${#s}
  bytes=$(printf '%s' "$s" | wc -c | tr -d ' ')
  echo $(( chars + (bytes - chars) / 2 ))
}

# 把字符串补到指定显示宽度（右侧补空格）
t_pad() {   # $1=字符串 $2=目标宽度
  local s="$1" want="$2" w n
  w=$(t_dwidth "$s")
  n=$(( want - w ))
  [ "$n" -lt 0 ] && n=0
  printf '%s%*s' "$s" "$n" ""
}
