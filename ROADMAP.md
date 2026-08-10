# graphhopper v2 方向性メモ

v1（最小コア）で確認済みの前提: 判断は「メイン対話 + `/advisor`」の2層で足りる
（`CLAUDE.md` の agent minimalism 原則）。v2 は polish/simplify council を復活させる際の
実装方式のメモ。

## 実装済み（v2 第一弾）

- **router gate**: `hooks/loop-driver.sh` が polish phase で `baseline_rev` からの
  diff行数を計測し、閾値（`GH_POLISH_THRESHOLD`、既定40行）以下なら built-in `/advisor`
  単体、閾値超なら `Skill: polish` へ誘導する。コードの if 文が判定するので、モデルの
  自己判断で council を削る/増やすという禁止事項自体が問題にならない。
- **verifier パターン**（adversarial / diverse-lens）: `skills/polish/SKILL.md` が
  built-in `Workflow` ツール（`agent()` + `parallel()`、オーケストレーションはコードなので
  トークン0）で3レンズ（要件/挙動/進捗）の fan-out を実行する。専用 subagent
  （code-reuse/code-quality/efficiency 相当）は作らない——「配管を専用agentに分ける」
  とは別物で、同じ判断を複数の独立した目で検証する**判断の分散**であり、agent
  minimalism 原則には抵触しない（`CLAUDE.md` 参照）。
- **verdict の一般化**: `state.verdict = {source: "advisor"|"verifier", level, reason, ts}`。
  loop-driver は source を問わず同じロジックで処理する。
- **per-node model tiering**: `main=sonnet`（session既定）/ `researcher=haiku`
  （`agents/researcher.md`）/ `advisor・verifier=opus`（built-in `/advisor` と
  `skills/polish` の3レンズ全て `model: 'opus'` 明示）。判断が要るnodeだけ高コスト
  モデルに残す。
- **fan-out上限**: `skills/polish` に `MAX_LENSES` 定数（5）。超えたら安全側でdrift扱い
  にしてスクリプト側で止める。今は3レンズ固定なので実害は無いが歯止めとして機能する。
- **edge contract fallback**: `schema` によるstructured output強制に加え、
  (1) 全レンズエラー時はdrift安全側、(2) 部分成功時は欠落レンズをreasonに明記、
  (3) Workflow自体がerror/空を返したら無言でcleanにすり替えずdrift記録、をSKILL.mdに明文化。
- **v1のライブ動作確認**: `~/.claude/plugins/known_marketplaces.json`（directory-source）
  + `settings.json` の `enabledPlugins` に登録（flywheelと同方式）。`claude -p` ヘッドレス
  起動で実セッション検証済み: (1) design.md無しでのsource編集を`design-gate.sh`が実際に
  ブロック、(2) design.md作成後は許可されimplementingへ自動遷移、(3) eval green後
  `loop-driver.sh`が`eval_pass`をhistory.jsonlに記録しpolish phaseへ遷移。旧flywheelは
  `enabledPlugins`で無効化済み（marketplace登録は残置、再有効化可能）。

Workflow API（`agent()`/`parallel()`/`phase()`/`meta`/schema/model）は `~/masayoshi/flywheel`
の `skills/ultrawork/SKILL.md` で実働確認済みの実 API に基づく（記事の snippet をそのまま
信用せず、自分のリポの実働コードで検証済み）。`Workflow` はセッション共通のツール一覧には
出ず、skill の `allowed-tools` に明示したときだけ使える。

## 実装済み（v2 第二弾）

- **discover skill（loop-until-dry）**: `skills/discover/SKILL.md`。未知件数の発見系探索
  （bug hunt / セキュリティ監査等）を、新規findingが尽きるまで3レンズ並列fan-outで周回する。
  安全装置2つ: (1) round cap（既定8、dry streakに関わらず絶対に止まる上限）、
  (2) dedupeは「既見全体」（確定済みだけでなく未採用も含む）に対して行う——「確定済み」に
  対してdedupeすると reject された finding が毎ラウンド再発見されて loop が永遠に乾かない
  （記事の警告そのもの）。phase graphには組み込まないオンデマンドツール（done gateの外）。
  3レンズ全てmodel:'opus'（tiering: advisor・verifier・discover=opus）。
- **simplify skill（大diff時のコード整理）**: `skills/simplify/SKILL.md` +
  `agents/simplifier.md`。polish分岐で`polished=false`かつ閾値超のとき1回だけ呼ぶ。
  3段構え（simplifier=haiku提案 → メイン=sonnet裏付け適用 → verifier=opus検証）で、
  enterpriseのopus制約（$1000/月）を踏まえopusはverifierに集中。適用後eval再実行 +
  `set polished true` を記録。`state.polished`フラグは`transition`がpolishに入るときに
  リセット（goalにつき1回）。critic（設計レビュー）は多様性が少ないため claude 版には
  導入しない。

### verifier 降格（sonnet）は不採用

verifier fan-out（polish）の sonnet 降格を検討したが不採用（2026-08-10 判断）:
- 大 diff 経路は `diff大 → polish → clean: done` で **built-in /advisor を通らない**
  （/advisor は小 diff 経路専用）。verifier を sonnet に下げると大 diff の opus 最終判断が
  消える
- /advisor 自体のモデルは built-in 依存で opus 保証は無い（`settings.json` は
  `claude-fable-5` 等）
- よって **verifier は opus を維持**。opus 制約への対処は simplify を
  haiku提案 + sonnet適用にする 3段構えで行う（上記）

### verifier レンズ重要度分離（2026-08-10 追加）

「全レンズ sonnet」は不採用のまま、opus 使用を絞るため **レンズ重要度分離**を導入:
- **requirement**（done の定義に直結）: **opus** を維持
- **behavior / progress**（広い走査）: **sonnet**
- 「重要」はモデル品質のみ。集約は全レンズ同等（requirement が他を上書きしない）
- opus 使用が「最重要レンズ1体」に絞られ、大 diff 経路の opus 最終判断は requirement が
  引き続き担保する

## 未実装（次の候補）

- **headless(`claude -p`)モードでの steer 継続**: `/advisor` を実際に呼ぶアクションが無い
  headless実行だと、loop-driverのexit 2 steerがモデルに行動を促せず空回りしてtimeoutする
  ことを確認済み（インタラクティブセッションでは問題にならない想定だが未検証）。

## opencode / pi アダプタ

別ディレクトリ・別セッションで後日。Workflow は Claude Code 固有機能のため、
opencode/pi版では別の仕組み（flywheel-opencodeの`task()`ベースfan-out等）で同等の
verifierパターンを実装する必要がある。
