---
name: polish
description: "diffが大きい変更（router gate閾値超）に対し、adversarial verifier fan-outでdriftを検証する。graphhopperのloop-driver.shがpolish phaseで大diffと判定したときだけsteerで呼ぶ。小diffはbuilt-in /advisorで足りるのでこのskillは呼ばれない。「polish実行」「verifier fan-out」で発動。"
allowed-tools: [Workflow, Bash, TaskOutput]
effort: high
---

# polish — verifier fan-out（Workflow使用・router gate配下）

**大きい diff だけに限定した敵対的検証。** council の再発を避けるため、専用 subagent
（code-reuse/code-quality/efficiency 相当）は作らない。Claude Code built-in の
`Workflow` ツール（`agent()` + `parallel()`、オーケストレーションはコードなのでトークン0）
で 3レンズ（要件/挙動/進捗）の verifier fan-out を1回だけ実行する。

**このskillはloop-driver.shのrouter gateが「diff > 閾値」と判定したときだけ呼ばれる**
（`hooks/loop-driver.sh` 参照）。閾値以下なら built-in `/advisor` に誘導されるのでこの
skill は呼ばれない——無条件発火だった旧 monitor council の再発防止はコード側（router gate）
で担保されている。

## Step 1: 入力を集める

```bash
baseline="$(bin/graphhopper get baseline_rev)"
goal="$(bin/graphhopper get goal)"
jj diff --from "$baseline" > /tmp/gh-polish-diff.txt   # スクラッチに退避、inlineで渡さない
```

`plan/design.md` を Read して要件テキストを確保する（長文はpathで渡す原則）。

## Step 2: Workflow を1回呼ぶ

以下のスクリプトを `Workflow` ツールに `script` として**一字一句そのまま**渡す。
`args` に `{ "diff": "<diffファイルの内容>", "goal": "<goal>", "requirements": "<design.mdの内容>" }`
を渡す（diffが大きい場合は要点を抜粋して渡してよいが、レンズが判断できる粒度は残す）。

```js
export const meta = {
  name: 'polish',
  description: 'adversarial verifier fan-out: 3レンズ(要件/挙動/進捗)でdrift検証',
  phases: [
    { title: 'Verify', detail: '3レンズが並列でdriftを検証' },
  ],
}

const diff = args.diff
const goal = args.goal
const requirements = args.requirements

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

const MAX_LENSES = 5 // fan-out上限（暴走防止）。現在は3固定なので実害は無いが、将来レンズを増やす時の歯止め
// レンズ重要度分離: requirement（doneの定義に直結）だけ opus、behavior/progress は sonnet。
// 「重要」はモデル品質のみを指し、集約は従来どおり全レンズ同等（requirementが他を上書きしない）。
// opus 制約（$1000/月）対策。レンズを追加するときは重要度に応じた model を明示する。
const LENSES = [
  { name: 'requirement', model: 'opus', charter: 'あなたは要件逸脱の敵対的レビュアー。実装がrequirements/design.mdの意図から外れていないか（実装漏れ・解釈ズレ・スコープ逸脱）を検証する。' },
  { name: 'behavior', model: 'sonnet', charter: 'あなたは挙動の敵対的レビュアー。テストが実際のユーザーパスを検証しているか（モック過多・ハッピーパスのみ・エラー握り潰し）を疑う。' },
  { name: 'progress', model: 'sonnet', charter: 'あなたは進捗の敵対的レビュアー。変更がgoalに収束しているか（堂々巡り・残骸・goal無関係な混入）を見る。' },
]
if (LENSES.length > MAX_LENSES) {
  return { verdict: 'drift', reason: `LENSES(${LENSES.length})がMAX_LENSES(${MAX_LENSES})超。fan-out上限違反のため安全側でdrift扱い（人間が閾値/レンズ数を見直すこと）。` }
}

// 判断が要るnode（verify/synthesize）は高コストモデルに残す。tiering: main=sonnet(session既定),
// researcher=haiku, verifier=レンズ重要度分離（requirement=opus / behavior・progress=sonnet）。
// requirement（doneの定義に直結）だけ model:'opus' を必須とする。opus指定を1つでも落とすと
// 要件逸脱検出の保証が silent に消えるので、スクリプト編集時は必ず requirement に
// model:'opus' があることを確認する。
phase('Verify')
const results = await parallel(LENSES.map(l => () =>
  agent(`${l.charter}

goal: ${goal}

要件/設計:
${requirements}

diff:
${diff}

drift（乖離）を検出したら全件報告してください（confidence/severity付き、閾値カットしない）。
無ければ findings: [] と summary に「drift なし」と書いてください。`,
    { model: l.model, label: 'verify:' + l.name, phase: 'Verify', schema: FINDING_SCHEMA })
    .then(r => ({ lens: l.name, ...r }))
))

const reports = results.filter(Boolean)
if (reports.length === 0) {
  return { verdict: 'drift', reason: '全レンズがエラー（verifier fan-out失敗）。人間に確認させるため安全側でdrift扱い。' }
}
// 部分成功: 生き残ったレンズの判定は使うが、欠落があれば reason に明記して人間が気付けるようにする
const missing = LENSES.filter(l => !reports.some(r => r.lens === l.name)).map(l => l.name)
const partialNote = missing.length
  ? `（欠落レンズ: ${missing.join(',')} — agent()エラーの可能性。カバレッジ低下として認識すること）`
  : ''

// confidence 80+ & critical/high のみ採用（confidence-scoring の降格マトリクス相当）
const adopted = reports.flatMap(r => (r.findings || [])
  .filter(f => f.confidence >= 80 && (f.severity === 'critical' || f.severity === 'high'))
  .map(f => ({ ...f, lens: r.lens })))

if (adopted.length === 0) {
  return {
    verdict: 'clean',
    reason: `${reports.map(r => r.lens).join('/')} のレンズで高confidence driftなし${partialNote}`,
    lenses: reports.map(r => r.lens),
  }
}

return {
  verdict: 'drift',
  reason: adopted.map(a => `[${a.lens}] ${a.title}`).join(' / ') + partialNote,
  findings: adopted,
}
```

Workflow は background で走り task ID が返る。完了通知を受けてから Step 3 へ
（必要なら `TaskOutput` で結果を取得）。

## Step 3: verdict を記録する

Workflow の戻り値の `verdict`（`clean`/`drift`）と `reason` を使い、必ず CLI で記録する
（記録するまで loop-driver は done に進めない）:

```bash
bin/graphhopper verifier-set clean "<reason>"
bin/graphhopper verifier-set drift "<reason>"
```

## Step 4: 失敗時 degrade（edge contract）

Workflow がエラー / `error` フィールド / 空を返したら、**無言で clean にすり替えない**。
`verifier-set drift "workflow error: <詳細>"` で安全側に倒し、人間が手動確認する経路に
乗せる。Workflow 自体が動かなかった事実は「driftなし」より重要な情報——沈黙は Goodhart's
Law の穴（外部検証アンカーが無いと筋は通っているが未検証になる）を再現する。

## Gotchas

- **スクリプトの一字一句を変えない**: コピー時の要約・省略・言い換え・整形は禁止。特に
  `schema` を1つでも落とすと構造化出力の強制が効かなくなり、後続の集約ロジックが壊れる。
- **`model` はレンズごとに指定（レンズ重要度分離）**: requirement（doneの定義に直結）は
  必ず `model: 'opus'`、behavior/progress は `model: 'sonnet'`。編集時にレンズを増やすなら
  新しい `agent()` 呼び出しにも重要度に応じた `model` を明示する（ultraworkと同じ規律。
  requirement の opus を1つでも落とすとテストでは検出できず要件逸脱検出の保証が
  silent に消える）。集約は全レンズ同等で requirement が他を上書きしない。
- **verifier-set を忘れる**: 記録しないと loop-driver は pending のまま re-steer する。
- **diffをinlineで会話に貼らない**: `/tmp/gh-polish-diff.txt` に退避し、`args.diff` に
  ファイル内容を渡す（会話コンテキストを膨らませない）。
- **このskillを自己判断で呼ばない**: router gate（loop-driver.sh）が閾値超と判定した
  ときだけ呼ぶ。diffが小さいのに「念のため」で呼ぶと council 無条件発火の再発になる。
- **fan-out上限（MAX_LENSES）を無断で上げない**: レンズを増やすなら暴走防止の上限も
  見直しが必要。上限超はスクリプトが自動でdrift扱いにする（Step 2参照）。
