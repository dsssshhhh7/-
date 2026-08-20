#!/bin/bash
# watcher.sh —— 收件程序（就是那个「传达室大爷」）
#
# 它每 5 秒扫一次自己的收件箱，发现没见过的消息就往标准输出打一行。
# 打出的每一行都会变成一个事件送进会话 —— 这就是「自动收消息」的全部原理。
#
# 它不思考、不花钱、不判断内容，只负责发现和喊话。
# 顺带干两件不花钱的活：盯自己发出去的消息有没有超时没人处理；提醒加工员不在岗。
#
# 必须由会话通过盯梢工具启动，普通后台进程起它没有意义
# （事件送不进会话，等于白跑）。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${TEAM_RUNTIME}" = "codex" ]; then
  echo "Codex 版禁止启动 watcher：原生任务消息会直接唤醒目标任务。" >&2
  exit 0
fi

# 下面几个都能用环境变量覆盖 —— 只为自测能把一小时压成几秒，
# 正常跑不要动，也不要在任何地方默认设置它们。
INTERVAL="${TEAM_INTERVAL:-5}"              # 轮询间隔（秒）
ACK_TIMEOUT="${TEAM_ACK_TIMEOUT:-300}"      # 我发出的消息超过这么久没被处理就提醒（秒）
CHECK_EVERY="${TEAM_CHECK_EVERY:-12}"       # 每多少轮做一次超时/加工员/自停检查（12 轮 = 60 秒）
# 「我的会话还在吗」单独降频：这一步要起一个进程去问 Claude Code，是本循环里
# 唯一有真实开销的动作（不花词元，但每次都 spawn 一个进程）。孤儿进程不急着
# 当秒发现，3 分钟查一次足够。⚠️ 它跟 ORPHAN_ROUNDS 叠乘：默认要连查 3 次都说
# 「没了」才下班，所以真被强关的窗口最长约 9 分钟后才收摊（原来是 3 分钟）。
ORPHAN_EVERY="${TEAM_ORPHAN_EVERY:-36}"     # 每多少轮查一次会话还在不在（36 轮 = 180 秒）
# 空转多久自动下班（秒）。默认 1 小时。
# 每台机器可以在 ${TEAM_ROOT}/.plugin/config 里写 idle_exit_seconds 改它，
# **填 0 就是永不因空转下班**；环境变量 TEAM_IDLE_TIMEOUT 可临时覆盖一次。
IDLE_TIMEOUT="${TEAM_IDLE_TIMEOUT:-$(t_conf idle_exit_seconds 3600)}"
ORPHAN_ROUNDS="${TEAM_ORPHAN_ROUNDS:-3}"    # 连续这么多轮查到"我的会话已经没了"才认定是孤儿

ME="$(t_sid)"
INBOX="$(t_myinbox)"
SEEN="$INBOX/.done"
SENT_DIR="$(t_mydir)/.sent"
PIDFILE="$(t_watcher_pidfile)"

mkdir -p "$INBOX" "$SENT_DIR"
touch "$SEEN"
echo $$ > "$PIDFILE"

# 下班时把心跳文件一起删掉 —— 「心跳文件在 = 收件程序在岗」，
# 留着的话别人会以为这个窗口还能收消息，其实没人送了。
# 下班：心跳不删，改名成墓碑 —— 别人才分得清「关掉的窗口」和「从没起过的窗口」，
# 也才算得出离线了多久（顶代号那道 10 分钟确认闸靠这个）。
cleanup() { rm -f "$PIDFILE"; mv -f "$(t_beat_file)" "$(t_beat_last_file)" 2>/dev/null || rm -f "$(t_beat_file)"; exit 0; }
trap cleanup TERM INT

# 上岗就先碰一下，别让刚起来的窗口被判成离线；顺手把上次下班留的墓碑清掉
rm -f "$(t_beat_last_file)" 2>/dev/null
t_beat
LAST_BEAT="$(t_epoch)"

# 从消息文件头里取一个字段
_field() { sed -n "s/^$1: //p" "$2" 2>/dev/null | head -1; }

round=0
agent_warned=0
not_in_collab=0
orphan_hits=0
LAST_ACTIVE="$(t_epoch)"   # 上一次「有收发」的时刻，用来判空转

# 我的会话还活着吗？
#   返回 0 = 确认已经没了；1 = 还在，或者压根查不了。
# ⚠️ 两个坑，都踩过：
#   ① lib 里那个查在线状态的函数【在进程内缓存、永不刷新】。别的脚本跑一次就退所以
#      没事，watcher 是长跑进程，直接用会永远拿第一次的快照 —— 所以这里每次清缓存。
#   ② 查不到 ≠ 已关闭。claude 命令不在路径里时查询会返回空，所有人都显示离线，
#      拿这个当"我死了"会导致全体自杀。所以只有【查询确实成功】时才敢下结论。
_i_am_gone() {
  unset _AGENTS_CACHE _AGENTS_WARNED
  local json; json="$(t_agents_json 2>/dev/null)"
  # 查询失败或没查成（空数组）→ 不下结论
  [ -z "$json" ] && return 1
  [ "$json" = "[]" ] && return 1
  printf '%s' "$json" | jq -e --arg id "$ME" '.[] | select(.sessionId==$id)' >/dev/null 2>&1 && return 1
  return 0
}

while true; do
  # ── 心跳：告诉别人这个窗口还活着 ──
  # 发消息前的「对方在不在线」全靠它。**每一轮都写**（约 5 秒一次）——
  # 原先是 30 秒一次，公司 Windows 实测那台机器一轮会被拉长 3~4 倍，
  # 30 秒会变成 60~120 秒、逼近 90 秒那条判离线的线，活着的窗口会被判离线。
  # 写的是自己名下的文件，不抢任何锁，代价可以忽略。
  if [ $(( $(t_epoch) - LAST_BEAT )) -ge "$TEAM_BEAT_EVERY" ]; then
    t_beat
    LAST_BEAT="$(t_epoch)"
  fi

  # 自己还在协作里吗？—— 判据是**有没有代号**（登记代号 = 接入传话台）。
  # ⚠️ 不是「在不在讨论组里」：退出全部组之后代号还在，人照样能传话给你，
  #    这时候下班就等于把自己从传话台上摘了。真正该下班的是「代号也没了」。
  # 连续 3 轮都查不到才退，避免索引正被别人改写时的瞬时误判。
  if t_in_collab; then
    not_in_collab=0
  else
    not_in_collab=$((not_in_collab + 1))
    if [ "$not_in_collab" -ge 3 ]; then
      echo "🚪 这个窗口已经没有代号了（注销、或被对账清理），收件程序自动下班。"
      cleanup
    fi
  fi

  # ── 1. 扫新消息 ──
  # 用 find 而不是通配符：收件箱为空时通配符会让脚本直接崩（实测踩过）
  #
  # 判空转看的是【有没有新动静】，不是【箱子里有没有东西】。
  #
  # ⚠️ 踩过的坑：一开始写的是「信箱里有任何 .md 就算活跃」，结果建组通知一直躺在
  #    信箱里没被处理，计时就永远重置，空转超时永远不触发。堆着不处理 ≠ 还在活动。
  #
  # 现在的口径：信箱或已发出目录里，有没有【比上次活跃时刻更新】的文件。
  NEWEST=0
  for d in "$INBOX" "$SENT_DIR"; do
    while IFS= read -r ff; do
      [ -n "$ff" ] || continue
      m=$(t_mtime "$ff")
      [ "$m" -gt "$NEWEST" ] && NEWEST="$m"
    done <<< "$(find "$d" -maxdepth 1 -type f 2>/dev/null)"
  done
  [ "$NEWEST" -gt "$LAST_ACTIVE" ] && LAST_ACTIVE="$NEWEST"

  find "$INBOX" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort | while IFS= read -r f; do
    grep -qxF "$f" "$SEEN" 2>/dev/null && continue

    g="$(_field 组 "$f")"
    from="$(_field 来自 "$f")"
    mid="$(_field 消息号 "$f")"
    depth="$(_field 接力深度 "$f")"
    urgent="$(_field 紧急 "$f")"
    kind="$(_field 类型 "$f")"

    # 走哪条道，取决于档位和加工员在不在岗：
    #   紧急 / 系统通知      → 永远直报主会话（这就是「快道」，绕过加工员）
    #   普通 + smart + 有加工员 → 不直报，交给加工员去加工后转
    #                            （不然主会话会收到两份：原始一份、加工一份，
    #                             加工员白干还白花钱）
    #   其余                 → 直报
    mode_now="$(cat "$(t_mydir)/.gear" 2>/dev/null || echo simple)"
    handoff=0
    if [ "$urgent" != "是" ] && [ "$kind" != "系统" ] \
       && [ "$mode_now" = "smart" ] && [ -f "$(t_mydir)/.agent" ]; then
      handoff=1
    fi

    if [ "$handoff" -eq 1 ]; then
      : # 交给加工员，这里不出声。但下面的「已送达」回执照标——消息确实到了。
    elif [ "$urgent" = "是" ]; then
      echo "🚨 紧急消息｜组=${g}｜来自=${from}｜深度=${depth}｜文件=${f}"
    elif [ "$kind" = "系统" ]; then
      echo "🔔 组通知｜组=${g}｜来自=${from}｜文件=${f}"
    else
      echo "📬 新消息｜组=${g}｜来自=${from}｜深度=${depth}｜文件=${f}"
    fi

    # 交给加工员的那些，不记进自己的已见名单 ——
    # 否则等加工员下班切回 simple 档后，这些消息就再也不会被报出来了。
    if [ "$handoff" -eq 0 ]; then
      echo "$f" >> "$SEEN"
    fi

    # 标「已送达」（第一个符号）。已处理由会话读完后自己标。
    # 标「已送达」。两条路，按消息类型分叉 ——
    # 传话台的消息**不属于任何组**，硬走组那条会被「这个组还在吗」挡掉，
    # 结果就是传话台的回执永远标不上。
    if [ -n "$mid" ] && [ "$mid" != "无" ]; then
      myname="$(t_alias_of "$ME")"
      case "$kind" in
        传话台*)
          [ -n "$myname" ] && t_talk_ack "$mid" "$myname" 已送达
          ;;
        *)
          if [ -n "$g" ] && t_group_exists "$g" && [ -n "$myname" ]; then
            t_lock "组-$g" 2 && {
              t_ack_update "$g" "$mid" "$myname" 1
              t_unlock "组-$g"
            }
          fi
          ;;
      esac
    fi
  done

  round=$((round + 1))
  if [ $((round % CHECK_EVERY)) -eq 0 ]; then

    # ── 0a. 我的会话还在吗（治孤儿）──
    # 单独降频到 3 分钟一次：这是本循环里唯一会 spawn 进程的动作。
    # 会话被强杀时，watcher 不会自己知道，会一直跑下去。实测一台机器上攒到过 12 个。
    # 光靠下面的空转超时治不了它们：别人还在给那个死会话发消息，它就永远不空闲。
    if [ $((round % ORPHAN_EVERY)) -eq 0 ]; then
      if _i_am_gone; then
        orphan_hits=$((orphan_hits + 1))
        if [ "$orphan_hits" -ge "$ORPHAN_ROUNDS" ]; then
          echo "🚪 我的会话已经不在了（大概是窗口被强关），收件程序自动下班，不再占资源。"
          cleanup
        fi
      else
        orphan_hits=0
      fi
    fi

    # ── 0b. 空转太久就下班 ──
    #
    # 判空转看的是【有没有新动静】（上面第 1 步算的 LAST_ACTIVE），
    # **不是【箱子里有没有东西】** —— 堆着不处理 ≠ 还在活动，这个坑踩过。
    #
    # ⚠️ 下班是有代价的，别忘了：下班 = 没心跳 = 别人的地址簿里你是「离线」=
    #    传话默认发不过来（发的人会被拦下并提示改用留言）。安静时段恰恰最常需要传话。
    #    所以这条做成**可配置**：嫌它下得早就把 idle_exit_seconds 调大，
    #    要常驻就填 0。窗口被强关留下的孤儿由上面 0a 治，跟空转是两回事。
    #
    # 下班时 cleanup 会把心跳改名成墓碑，所以别人看到的是「离线 N 分钟」，
    # 而不是「没起过收件程序」—— 分得清「安静太久自己走了」和「压根没接进来」。
    if [ "$IDLE_TIMEOUT" -gt 0 ] && [ "$(( $(t_epoch) - LAST_ACTIVE ))" -ge "$IDLE_TIMEOUT" ]; then
      # 超时不满一分钟时别说「0 分钟」—— 自测会把它压到几秒
      if [ "$IDLE_TIMEOUT" -ge 60 ]; then _idle_say="$((IDLE_TIMEOUT / 60)) 分钟"; else _idle_say="${IDLE_TIMEOUT} 秒"; fi
      echo "🚪 这个窗口 ${_idle_say}没有收发消息，收件程序自动下班了。"
      echo "   ⚠️ 从现在起别人的地址簿里你显示为「离线」，**传话默认发不过来**（对方会被提示改用留言）。"
      echo "   在这个窗口说任何一句话，它就会自己起回来。"
      echo "   不想让它下班：把 ${TEAM_ROOT}/.plugin/config 里的 idle_exit_seconds 调大，或填 0。"
      cleanup
    fi

    # ── 2. 我发出去的消息，有没有超时还没人处理 ──
    find "$SENT_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r sf; do
      warned="$(sed -n 's/^已提醒=//p' "$sf" | head -1)"
      [ "$warned" = "是" ] && continue
      ts="$(sed -n 's/^时间戳=//p' "$sf" | head -1)"
      [ -n "$ts" ] || continue
      age=$(( $(t_epoch) - ts ))
      [ "$age" -lt "$ACK_TIMEOUT" ] && continue

      sg="$(sed -n 's/^组=//p' "$sf" | head -1)"
      smid="$(basename "$sf")"
      rcpts="$(sed -n 's/^收件人=//p' "$sf" | head -1)"

      # 组已经没了（结案或被删）→ 这条发出记录没有意义了，清掉，别再报警。
      # 不清的话会一直提醒一个不存在的组里没人处理消息。
      if [ -n "$sg" ] && ! t_group_exists "$sg"; then
        rm -f "$sf"
        continue
      fi

      pending=""
      for rid in ${rcpts//,/ }; do
        [ -z "$rid" ] && continue
        st="$(t_status_of "$rid")"
        pending="${pending:+${pending}、}$(t_display "$rid")（${st}）"
      done
      [ -n "$pending" ] && \
        echo "⏰ 你 $((age / 60)) 分钟前发的消息（${smid}，组=${sg}）还没被处理：${pending}"

      t_sed_inplace 's/^已提醒=否/已提醒=是/' "$sf" || \
        { sed 's/^已提醒=否/已提醒=是/' "$sf" > "$sf.t" && mv "$sf.t" "$sf"; }
    done

    # ── 3. 加工员在不在岗（只有开了智能档才提醒）──
    mode="$(cat "$(t_mydir)/.gear" 2>/dev/null || echo simple)"
    if [ "$mode" = "smart" ] && [ ! -f "$(t_mydir)/.agent" ]; then
      if [ "$agent_warned" -eq 0 ]; then
        echo "🔧 加工员不在岗（当前档位 smart）—— 下一条消息不会经过分级和过滤，主会话请起一个"
        agent_warned=1
      fi
    else
      agent_warned=0
    fi
  fi

  sleep "$INTERVAL"
done
