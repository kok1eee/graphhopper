#!/usr/bin/env bash
set -euo pipefail

# PreToolUse: Edit|Write|NotebookEdit
# designing phase 中はソース書き込みを物理ブロックする（C-2相当の不変条件）。
# .graphhopper/ 配下への直接編集は常に全phaseでブロック（モデルはstateを進めない）。

here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

gh_disabled && exit 0

input="$(gh_read_hook_input)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')"

if ! gh_state_exists; then
  exit 0
fi

# .graphhopper/ 配下は常にブロック（CLI経由でのみ状態変更を許可）
if [[ "$file_path" == "$GH_DIR"/* ]]; then
  echo "graphhopper: .graphhopper/ 配下への直接編集はブロックされます。状態変更は bin/graphhopper CLI 経由で行ってください。" >&2
  exit 2
fi

phase="$(gh_get phase)"
design_doc="$GH_ROOT/plan/design.md"

# design.md は designing phase 終了後は不変（verifierのdrift検出アンカーのため）。
# 決定・進捗の追記は plan/log.md へ（design.mdは書き換えず、log.mdは全phaseで自由に追記可）。
if [[ "$phase" != "designing" ]] && [[ "$file_path" == "$design_doc" ]]; then
  echo "graphhopper: plan/design.md は designing phase 終了後は不変です（verifierのdrift検出アンカー）。決定・進捗の追記は plan/log.md へ書いてください。" >&2
  exit 2
fi

if [[ "$phase" != "designing" ]]; then
  exit 0
fi

# plan/ 配下・.md は常に許可（設計ドキュメントの作成・編集）
if [[ "$file_path" == "$GH_ROOT/plan/"* ]] || [[ "$file_path" == *.md ]]; then
  exit 0
fi

if [[ ! -f "$design_doc" ]]; then
  echo "graphhopper: designing phase 中です。plan/design.md を先に書いてください（source編集はブロック）。" >&2
  exit 2
fi

# design.md が既にあるなら、最初のsource編集を機に implementing へ自動昇格して通す
"$GH_CLI" transition source_edit >/dev/null
exit 0
