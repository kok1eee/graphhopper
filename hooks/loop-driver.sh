#!/usr/bin/env bash
set -euo pipefail

# Stop hook — eval実行→(router gate)→advisor/verifier検証→doneまでを観測して進める。
# exit 0 = 停止を許可（人間に返す） / exit 2 = 停止を拒否（steerメッセージをstderrに出し継続を強制）
#
# router gate: polish phaseに入ったら、baseline_revからのdiff行数を見て
#   閾値以下 -> built-in /advisor（単体・v1のまま）
#   閾値超   -> Skill: polish（verifier fan-out, Workflow使用）
# のどちらに倒すかをコードで決める（モデルの自己判断に委ねない）。

here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

gh_disabled && exit 0

# 優先順位: env var（アドホックな一時上書き） > .graphhopper/config.json（プロジェクト単位の永続設定） > ハードコードdefault
GH_POLISH_THRESHOLD="${GH_POLISH_THRESHOLD:-$(gh_config_get polish_threshold_lines 40)}"
GH_HANDOFF_THRESHOLD_KB="${GH_HANDOFF_THRESHOLD_KB:-$(gh_config_get handoff_threshold_kb 500)}"

gh_state_exists || exit 0

phase="$(gh_get phase)"

# handoff一度きり通知: transcriptサイズが閾値を超えたら知らせる（対応必須ではない）。
# doneでは意味が無いので対象外。goalにつき1回だけ（handoff_nudgedでdedup）。
# Stop hookでモデルに確実に見せるにはexit 2が要るため、通知はこのターンだけ停止を1回拒否する。
if [[ "$phase" != "done" ]]; then
  handoff_nudged="$(gh_get handoff_nudged)"
  if [[ "$handoff_nudged" != "true" ]]; then
    transcript_path="$(gh_read_hook_input | jq -r '.transcript_path // ""')"
    if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
      size_bytes="$(stat -c%s "$transcript_path" 2>/dev/null || stat -f%z "$transcript_path" 2>/dev/null || echo 0)"
      size_kb=$(( size_bytes / 1024 ))
      if (( size_kb >= GH_HANDOFF_THRESHOLD_KB )); then
        "$GH_CLI" set handoff_nudged true >/dev/null
        echo "graphhopper: 会話が大きくなっています（transcript ${size_kb}KB・閾値${GH_HANDOFF_THRESHOLD_KB}KB）。対応必須ではありません。必要なら \`bin/graphhopper handoff\` で次sessionへの引き継ぎテキストを出力できます（このgoalでは1回だけの通知）。" >&2
        exit 2
      fi
    fi
  fi
fi

case "$phase" in
  designing|done)
    exit 0
    ;;
esac

if [[ "$phase" == "implementing" ]]; then
  eval_cmd="$(gh_get eval_cmd)"
  if [[ -z "$eval_cmd" ]]; then
    # eval未設定。強制はしない（set-evalをモデルが設定するのを待つ）
    exit 0
  fi

  eval_output="$(bash -c "$eval_cmd" 2>&1)"
  eval_status=$?

  if [[ $eval_status -ne 0 ]]; then
    "$GH_CLI" transition eval_fail >/dev/null
    {
      echo "graphhopper: eval FAILED (exit $eval_status)。修正して続けてください。"
      echo "--- eval output (tail) ---"
      printf '%s\n' "$eval_output" | tail -20
    } >&2
    exit 2
  fi

  "$GH_CLI" transition eval_pass >/dev/null
  phase="polish"
fi

if [[ "$phase" != "polish" ]]; then
  exit 0
fi

verdict_level="$(gh_get verdict.level)"

if [[ -z "$verdict_level" ]]; then
  diff_lines="$("$GH_CLI" diff-lines 2>/dev/null || echo 0)"
  if [[ "$diff_lines" -le "$GH_POLISH_THRESHOLD" ]]; then
    echo "graphhopper: eval green（diff ${diff_lines}行・閾値${GH_POLISH_THRESHOLD}行以下）。done前に built-in /advisor で最終レビューしてください。結果は \`$GH_CLI advisor-set clean|drift \"<reason>\"\` で記録してください（記録するまでdoneに進みません）。" >&2
  else
    polished="$(gh_get polished)"
    if [[ "$polished" != "true" ]]; then
      echo "graphhopper: eval green（diff ${diff_lines}行・閾値${GH_POLISH_THRESHOLD}行超）。done前に \`Skill: simplify\` でコード整理を実行してください（適用後 eval 再実行 → \`$GH_CLI set polished true\`）。次の停止で \`Skill: polish\` を誘導します。記録するまでdoneに進みません。" >&2
    else
      echo "graphhopper: eval green（diff ${diff_lines}行・閾値${GH_POLISH_THRESHOLD}行超・simplify済み）。done前に \`Skill: polish\` でverifier fan-outを実行してください。結果は \`$GH_CLI verifier-set clean|drift \"<reason>\"\` で記録してください（記録するまでdoneに進みません）。" >&2
    fi
  fi
  exit 2
fi

if [[ "$verdict_level" == "clean" ]]; then
  "$GH_CLI" transition verdict_clean >/dev/null
  exit 0
fi

# drift
verdict_reason="$(gh_get verdict.reason)"
verdict_source="$(gh_get verdict.source)"
"$GH_CLI" transition verdict_drift >/dev/null
echo "graphhopper: ${verdict_source} drift — ${verdict_reason}。implementing に差し戻しました。修正してください。" >&2
exit 2
