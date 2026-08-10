---
name: simplify
description: "diffが大きい変更（router gate閾値超）の polish で、単体 agent（simplifier, haiku）に3レンズ（再利用/品質/効率）の整理提案を出させ、メインが裏付け適用してコードを磨く。loop-driver.sh が「polished=false かつ大diff」と判定したときだけ steer で呼ぶ（goalにつき1回）。適用後に eval 再実行 + `set polished true` を済ませる。次工程（Skill: polish）は loop-driver が誘導する。「simplify」「整理して」「冗長を削って」で発動。"
allowed-tools: [Bash, Read, Glob, Grep, Task]
effort: high
---

# simplify — コード整理（単体 agent・router gate 配下）

**大きい diff だけに限定したコード整理。** 3段構え（haiku 提案 → メイン=sonnet の裏付け適用 →
最終の verifier fan-out=opus 検証）で品質を担保する。enterprise の opus 制約（$1000/月）を
踏まえ、**opus は verifier に集中**させ、simplify 自体は haiku + sonnet で処理する。

**この skill は loop-driver.sh の router gate が「diff > 閾値」かつ「polished=false」と
判定したときだけ呼ばれる**。呼び出し後、適用と eval 再実行を済ませて `set polished true` を
記録する。**次工程（`Skill: polish` / verifier fan-out）は loop-driver が誘導する**
（simplify から直接 `Skill: polish` を呼ぶ chain はしない——polish と同様 user/steer 駆動）。

## Step 1: 入力の準備

```bash
baseline="$(bin/graphhopper get baseline_rev)"
goal="$(bin/graphhopper get goal)"
jj diff --from "$baseline" > /tmp/gh-simplify-diff.txt   # スクラッチに退避、inlineで渡さない
```

`plan/design.md` を Read して要件テキストを確保する（長文は path で渡す原則）。

## Step 2: simplifier agent を呼ぶ

`Task`（subagent_type: `simplifier`）を1回呼ぶ。**goal / plan/design.md の内容 / diff path を
必ず渡す**（diff は inline 展開せず `/tmp/gh-simplify-diff.txt` の path で渡す）。

```
Task: simplifier を呼ぶ
  入力:
  - goal: <goal>
  - 要件/設計: <design.md の内容>
  - diff: /tmp/gh-simplify-diff.txt
```

## Step 3: findings を裏付けして適用する（メインの責務）

simplifier は**提案のみ**返す。適用はメインが行う:

- 各 finding を該当ファイルで **Read して裏付け**（Iron Law。推測で適用しない）
- **critical**（挙動不変・局所的）: 自動適用（typo / rename / 冗長中間変数削除）
  - interface 変更・signature 変更・新規依存追加・公開 API の振る舞い変更は
    **high 扱い**にして人間に提示（勝手に直すと design レベルの変更になる）
- **high**: 人間に確認してから修正
- **medium / note**: 報告のみ（恒久記録はしない）

## Step 4: eval 再実行 → polished を記録 → 次の polish へ

```bash
eval_cmd="$(bin/graphhopper get eval_cmd)"
bash -c "$eval_cmd"   # 適用した変更が eval を壊していないか機械確認
```

- **eval 成功**: `bin/graphhopper set polished true` を実行。次工程（Skill: polish）は
  loop-driver が誘導する
- **eval 失敗**: `set polished true` を実行せず中断（loop-driver が eval_fail を拾って
  implementing に戻す）。simplify を「済み」にしない

## Gotchas

- **diff を inline で agent に渡さない**: main context を汚す。`/tmp/gh-simplify-diff.txt`
  に退避して path で渡す（simplifier は bash deny なので自分で diff は取れない）
- **critical を勝手に直して設計を変える**: 「共通化」のための interface 変更は
  design レベルの変更。high 扱いで人間に提示する
- **eval 再実行をしないで polished を立てる**: 適用したコードが未検証のまま
  「済み」扱いになる。必ず eval を通してから `set polished true`
- **この skill を自己判断で呼ばない**: loop-driver.sh が「大diffかつ polished=false」と
  判定したときだけ呼ぶ。diff が小さいのに呼ぶと毎 goal の無駄な整理になる
- **polished を立て忘れる**: 立てないと loop-driver が毎停止 simplify を再誘導する。
  Step 4 の eval 成功後に必ず実行する
