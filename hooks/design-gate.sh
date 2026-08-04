#!/usr/bin/env bash
set -euo pipefail

# PreToolUse: Edit|Write|NotebookEdit
# designing phase 中はソース書き込みを物理ブロックする（C-2相当の不変条件）。
# .graphhopper/ 配下への直接編集は常に全phaseでブロック（モデルはstateを進めない）。

here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

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
if [[ "$phase" != "designing" ]]; then
  exit 0
fi

# plan/ 配下・.md は常に許可（設計ドキュメントの作成・編集）
if [[ "$file_path" == "$GH_ROOT/plan/"* ]] || [[ "$file_path" == *.md ]]; then
  exit 0
fi

design_doc="$GH_ROOT/plan/design.md"
if [[ ! -f "$design_doc" ]]; then
  echo "graphhopper: designing phase 中です。plan/design.md を先に書いてください（source編集はブロック）。" >&2
  exit 2
fi

# design.md が既にあるなら、最初のsource編集を機に implementing へ自動昇格して通す
"$GH_CLI" transition source_edit >/dev/null
exit 0
