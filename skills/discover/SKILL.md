---
name: discover
description: "未知件数の発見系探索（bug hunt / セキュリティ監査 / 網羅的レビュー等）をloop-until-dryで回す。新規findingが尽きるまで3レンズで並列探索し、round capで確実に止める。phase graphには組み込まれないオンデマンドツール。「バグ探して」「網羅的に監査」「〇〇が無いか全部見て」「loop-until-dry」で発動。※ 大diffのdrift検証はSkill: polish、done前の単発レビューはbuilt-in /advisor。"
allowed-tools: [Workflow, Bash, TaskOutput]
effort: high
---

# discover — loop-until-dry 探索（Workflow使用）

**「何件あるか分からない」ものを、尽きるまで（かつ確実に止まるまで）探す。** バグ探し・
セキュリティ監査・網羅的レビューなど、事前に件数が分からない探索タスクに使う。

council/subagent を専用に増やすのではなく、Claude Code built-in の `Workflow` ツール
（`agent()` + `parallel()`）で3レンズを並列 fan-out し、**新規findingが出なくなるまで
ラウンドを繰り返す**。ただし2つの安全装置を必ず入れる:

1. **round cap**（既定8）: dry streak に関わらず絶対に止まる上限
2. **dedupe は「既見全体」に対して行う**（確定済みfindingだけでなく、reject/未採用も含めた
   全て）。「確定済み」に対してdedupeすると、一度リジェクトされたfindingが毎ラウンド再発見
   されて loop が永遠に乾かない（無限空転バグ）

## Step 1: 入力を決める

呼び出し側（人間 or メイン対話）が以下を明確にしてから呼ぶ:
- `target`: 何を探すか（例:「認証チェック漏れ」「エラー握り潰し」「境界値バグ」）
- `scope`: どこを探すか（例: パス glob、モジュール名）

## Step 2: Workflow を1回呼ぶ

以下のスクリプトを `Workflow` ツールに `script` として**一字一句そのまま**渡す。
`args` に `{ "target": "<何を>", "scope": "<どこを>" }` を渡す。

```js
export const meta = {
  name: 'discover',
  description: 'loop-until-dry: 未知件数の発見系探索',
  phases: [
    { title: 'Search', detail: '3レンズが並列で探索、既見全体に対してdedupeしながら周回' },
  ],
}

const MAX_ROUNDS = 8
const DRY_ROUNDS_TO_STOP = 2

const target = args.target
const scope = args.scope

const FINDING_SCHEMA = {
  type: 'object', required: ['findings', 'summary'],
  properties: {
    summary: { type: 'string' },
    findings: { type: 'array', items: {
      type: 'object', required: ['severity', 'confidence', 'title'],
      properties: {
        severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
        confidence: { type: 'integer' },
        title: { type: 'string' },
        quote: { type: 'string' },
      },
    } },
  },
}

const LENSES = [
  { name: 'broad-scan', charter: `${target} に関連するパターンを ${scope} 全体で広く探すサーチャー。網羅性重視、grep的な構造探索。` },
  { name: 'semantic-read', charter: `${target} について、${scope} の該当箇所を実際に読んで論理的な妥当性を検証するサーチャー。表面パターンではなく意味を見る。` },
  { name: 'edge-case', charter: `${target} の境界値・異常系（null/空/負数/範囲外/並行性/前ゼロ等）を疑って探すサーチャー。もっともらしく動くが境界で黙って壊れる系を狙う。` },
]

// dedupe は「既見全体」に対して行う（確定済みだけでなく reject/未採用も含む）
const seen = new Set()
const confirmed = []
let dryStreak = 0
let round = 0

phase('Search')
while (dryStreak < DRY_ROUNDS_TO_STOP && round < MAX_ROUNDS) {
  round++
  const seenList = Array.from(seen)
  const results = await parallel(LENSES.map(l => () =>
    agent(`${l.charter}

対象: ${target}
スコープ: ${scope}

これまでに見つかった項目（重複報告しないこと。findingsが無ければfindings:[]）:
${seenList.join('\n') || '（まだ無し）'}

新規のfindingだけ報告してください。confidence(0-100)/severity付き、閾値カットせず全件。`,
      { model: 'opus', label: `search:${l.name}:r${round}`, phase: 'Search', schema: FINDING_SCHEMA })
      .then(r => ({ lens: l.name, ...r }))
  ))

  const reports = results.filter(Boolean)
  const allFindings = reports.flatMap(r => (r.findings || []).map(f => ({ ...f, lens: r.lens })))
  const newOnes = allFindings.filter(f => !seen.has(f.title))
  newOnes.forEach(f => seen.add(f.title))

  if (newOnes.length === 0) {
    dryStreak++
  } else {
    dryStreak = 0
    const adopted = newOnes.filter(f => f.confidence >= 80 && (f.severity === 'critical' || f.severity === 'high'))
    confirmed.push(...adopted)
  }
}

return {
  rounds: round,
  stopped_reason: dryStreak >= DRY_ROUNDS_TO_STOP ? 'dry' : 'max_rounds',
  findings: confirmed,
  total_seen: seen.size,
}
```

Workflow は background で走り task ID が返る。完了通知を受けてから Step 3 へ
（必要なら `TaskOutput` で結果を取得）。

## Step 3: 結果を提示する

- `stopped_reason` が `max_rounds` なら**その旨を明示する**（`dry` で自然に尽きたのか、
  上限で打ち切ったのかは全く違う意味を持つ情報——沈黙しない）。
- `findings` を quote 付きで会話に提示する。件数が多ければ severity 降順で並べる。
- phase graph には影響しない。CLI での記録は不要（このskillはdone gateの外）。

## Gotchas

- **dedupe を「確定済み」に対して行わない**: 未採用（confidence不足等）の finding も
  `seen` に入れる。ここを誤ると、リジェクトされた finding が毎ラウンド再発見されて
  永遠に dry にならない（`facets` 的な既知バグ class、記事の警告そのもの）。
- **round cap を外さない**: `MAX_ROUNDS` は dry streak に関わらぬ絶対的な歯止め。
  スクリプト編集時にこの値を外す/極端に上げない。
- **`model: 'opus'` を欠かさない**: 3レンズとも判断node（tiering: advisor・verifier・
  discover=opus）。
- **scope を広げすぎない**: `target`/`scope` が曖昧だと1ラウンドのコストが跳ねる。
  呼び出し側（Step 1）で具体化してから呼ぶ。
