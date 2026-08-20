#!/bin/bash
# Codex SessionStart hook。stdin 是 Codex hook JSON；stdout 必须是 Codex hook JSON。

set -o pipefail
INPUT="$(cat)"
ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
[ -n "$ROOT" ] || exit 0

SID="${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}"
[ -n "$SID" ] || SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
CWD_FROM_HOOK="$PWD"
[ -n "$SID" ] || exit 0

export CODEX_THREAD_ID="$SID"
export CODEX_SESSION_ID="$SID"
export TEAM_ROOT="${TEAM_ROOT:-$HOME/codex-team}"

mkdir -p "$TEAM_ROOT/.plugin" 2>/dev/null
printf '%s\n' "$ROOT/bin" > "$TEAM_ROOT/.plugin/binpath" 2>/dev/null

PEERS="$(cd "${CWD_FROM_HOOK:-$PWD}" 2>/dev/null && bash "$ROOT/bin/ccpeers" 2>/dev/null || true)"
BASE_CONTEXT="Codex team 协作已启用。当前任务编号：${SID}。数据目录：${TEAM_ROOT}。收到以 CODEX_TEAM_V1 开头的任务消息时，必须加载 team 技能并按其中的收件协议处理；不要让用户复制粘贴转达。"

json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

if [ -n "$PEERS" ]; then
  FULL_CONTEXT="${BASE_CONTEXT}

当前协作现状：
${PEERS}"
  printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
    "$(json_string "$PEERS")" "$(json_string "$FULL_CONTEXT")"
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(json_string "$BASE_CONTEXT")"
fi
