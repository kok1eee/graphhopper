# graphhopper v2 方向性メモ

v1（最小コア）で確認済みの前提: 判断は「メイン対話 + `/advisor`」の2層で足りる
（`CLAUDE.md` の agent minimalism 原則）。v2 は polish/simplify council を復活させる際の
実装方式のメモ。まだ実装しない。

## polish/simplify council は Dynamic Workflows で実装する

専用 subagent（code-reuse/code-quality/efficiency 相当）をゼロから作らない。
Claude Code built-in の **Dynamic Workflows**（`agent()` + `parallel()`/`pipeline()`）を使う。
オーケストレーション自体がコードなので、配線を考える分のトークンを払わない。

- **verifier パターン**（adversarial / diverse-lens / judge panel）で判断を分散する。
  これは「配管を専用agentに分ける」（designer/critic を切り出す）とは別物——
  同じ判断を複数の独立した目で検証する**判断の分散**であり、agent minimalism 原則には
  抵触しない。CLAUDE.md に追記済み。
- **router node で無条件発火をやめる**: verifier を呼ぶ前に、コードで
  diff規模・runnable かどうかを判定し、閾値以下なら verifier 呼び出し自体を丸ごとスキップ
  する（`agent()` を1つも呼ばないので完全にゼロコスト）。現行 flywheel の `lite`/`targeted`
  モード（steer明示が無いとモデルが自己判断できない制約付き）より単純かつ確実——
  コードのif文が判定するので「モデルの自己判断で council を削る」という禁止事項自体が
  問題にならない。
- **edge contract**: fan-outが復活したら、subagentが返すJSONをzod等で検証してから使う
  （flywheel-opencodeの`flywheel_extract_finding`相当）。生テキストをhand-parseしない。
- **loop-until-dry**: 発見系の探索ループを回すならround cap必須 + dedupeは「確定済み」
  でなく「既に見た全体」に対して行う（無限空転バグの回避）。
- **per-node model tiering**: Dynamic Workflowsの`model`上書きで、繰り返し系nodeは安い
  モデル、synthesize/verifyだけ高コストモデルに残す。
- **fan-out上限**: 同時実行・累計呼び出しに具体的なガードレールを持つ（暴走防止）。

## opencode / pi アダプタ

別ディレクトリ・別セッションで後日。Dynamic Workflows は Claude Code 固有機能のため、
opencode/pi版では別の仕組み（flywheel-opencodeの`task()`ベースfan-out等）で同等の
verifierパターンを実装する必要がある。
