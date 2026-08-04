#!/usr/bin/env bash
set -euo pipefail

gh_repo_root() {
  local r
  if r=$(jj root 2>/dev/null); then printf '%s\n' "$r"; return; fi
  if r=$(git rev-parse --show-toplevel 2>/dev/null); then printf '%s\n' "$r"; return; fi
  pwd
}

GH_ROOT="$(gh_repo_root)"
GH_DIR="$GH_ROOT/.graphhopper"
GH_STATE="$GH_DIR/state.json"

_gh_src="${BASH_SOURCE[0]:-}"
if [[ -n "$_gh_src" ]]; then
  GH_PLUGIN_ROOT="$(cd "$(dirname "$_gh_src")/../.." && pwd)"
else
  GH_PLUGIN_ROOT="$GH_ROOT"
fi
unset _gh_src

if [[ -x "$GH_PLUGIN_ROOT/bin/graphhopper" ]]; then
  GH_CLI="$GH_PLUGIN_ROOT/bin/graphhopper"
else
  GH_CLI="graphhopper"
fi

gh_state_exists() { [[ -f "$GH_STATE" ]]; }

# headless(`claude -p`)実行等でGRAPHHOPPER_OFF=1が明示されていればhookを完全に無効化する。
# print/headlessモードをhookから自動検出する公式な方法は無い（session_id等のJSONフィールド・
# env varどちらにも indicator が無いことを調査済み）ため、自動判定より明示 opt-out を選ぶ。
# flywheel の FLYWHEEL_OFF=1 と同じ設計。
gh_disabled() { [[ "${GRAPHHOPPER_OFF:-}" == "1" ]]; }

# stdin から渡された hook 入力 JSON 全体をキャッシュして返す（複数回呼んでもstdinは1回しか読めないため呼び出し側で1回だけ使う想定）
gh_read_hook_input() { cat; }

# .graphhopper/state.json の dot-path フィールドを取得（jq直読み、bun起動コスト回避）
gh_get() {
  local path="$1"
  gh_state_exists || { printf '\n'; return; }
  jq -r "getpath([\"${path//./\",\"}\"]) // \"\"" "$GH_STATE" 2>/dev/null || printf '\n'
}
