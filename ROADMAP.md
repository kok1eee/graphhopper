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

## 実装済み（v2 第三弾）

- **design.md 不変化ゲート**: `hooks/design-gate.sh` に `plan/design.md` への
  designing phase 終了後の編集ブロックを追加（`.graphhopper/` 直接編集ブロックと同型）。
  `skills/polish`/`skills/simplify` が design.md をdrift検出のアンカーとして読んでいる
  実態を確認した上で塞いだ（2026-08-14 判断）: 実装後に design.md を書き直せると
  「driftをdesign.md側の書き換えで消せる」——polish/SKILL.md自身が警戒している
  Goodhart's Lawの穴と同型の脆弱性になる。
- **plan/log.md 導入（decisions/progressログ、新設）**: design.mdを不変にする以上、
  実装中の決定経緯・棄却した代替案・残issueは別の場所に要る。検討した2案のうち
  **新規ファイル`plan/log.md`への追記**を採用、**jjのcommit historyをそのまま進捗ログ
  として流用する案は不採用**（2026-08-14 判断）。不採用の理由: 「決定」の単位がjjの
  commit境界と自然には一致せず実装の流れを止める負荷が大きい／jj.mdの既存tiering
  （軽微=1行・重要のみ背景を書く）と衝突する／squashで棄却した代替案の記録が消える。
  plan/log.mdは**ハードゲート無し**（design-gateのような物理ブロックを課さない）。
  「ログに残す価値があるか」自体が判断であり、メインエージェントの裁量に委ねる
  （agent minimalism原則——強制する仕組み自体を新設しない）。

## 実装済み（v2 第四弾）

- **handoff機能（v1）**: `bin/graphhopper handoff`（`engine.ts` の `formatHandoff`）。
  goal/phase/eval_cmd/baseline_rev/diff行数/verdictを`state.json`から機械的に組み立て、
  design.md/log.mdは**内容を埋め込まずpathを指すだけ**にする（`skills/polish`の「長文は
  pathで渡す」原則と同じ——handoff自体の出力を膨らませない）。LLM呼び出しゼロの
  決定的なテキスト組み立てのみ（agent minimalism——判断は次sessionのメインエージェントに
  委ね、handoffコマンド自体は配管）。
  **クロスセッションメッセージング統合は不採用**（2026-08-14 判断）: SendMessageは
  テキストのみでdesign.md/log.md本体は運ばない上、受信メッセージも通常プロンプトと
  同様に使用量へ計上される。handoffの出力を新規terminalに自分で貼る／
  `claude "$(bin/graphhopper handoff)"` で十分であり、SendMessage経由にする実質的な
  価値が無い（自分で立ち上げれば足りる）。

## 実装済み（v2 第五弾）

- **design.md質レビュー（opt-in、ハードゲート無し）**: `bin/graphhopper design-set
  clean|drift "<reason>"`（`state.design_review`、`advisor-set`/`verifier-set`と同型）。
  design.mdを不変化した以上、雑な内容のまま永久ロックされるリスクへの安全弁として
  検討したが、**design-gate.shの遷移条件には組み込まずhard gate化しない**（2026-08-14
  判断）。理由: polishのrouter gateがコード判定でハード化できるのは「diff行数」という
  実装後に確定する客観的事実が閾値になるから。design.mdの質はdesign時点では客観的な
  閾値が存在せず（design.mdをどれだけ書くか自体がモデルの記述量で決まる）、ここに
  ゲートを置くと「ゲートを避けるために薄く書く」自己判断エロージョンを一段ズラして
  再生産するだけ。実害も軽い（雑なdesign.mdはverifierのrequirementレンズの確信度を
  下げるだけで、既存のconfidence>=80フィルタが安全側に吸収する）。よって呼ぶかどうかは
  メインエージェントの裁量に委ねるopt-in記録機構とした。`bin/graphhopper init`していない
  単発タスクはこのコマンドの有無に関わらず影響を受けない（design-gate自体が無効なため）。
- **handoff一度きり通知（自動トリガー、非ゲート）**: `hooks/loop-driver.sh`（Stop hook）
  が自身のhook入力JSONから`.transcript_path`を読み、ファイルサイズが
  `GH_HANDOFF_THRESHOLD_KB`（既定500KB）を超えたら`bin/graphhopper handoff`の利用を
  一度だけ知らせる。実装の経緯: headlessモード判定（対話/print区別）には信頼できる
  指標が本当に無いが、「会話が長くなったか」は別問題——手元の既存hook
  （`todo-enforcer.sh`/`herdr-agent-state.sh`）が実際に`.transcript_path`をhook入力
  から読んでいる実例を確認した上で採用（2026-08-14）。hookはセッションを終了/新規
  起動できず「メッセージを出す」しかできないため、Stop hookでモデルに確実に見せる
  ために既存のeval/polish nudgeと同じ`exit 2`方式を使うが、**dedup
  （`state.handoff_nudged`、goalにつき1回のみ）で無限ループ化を防ぐ**。会話が長い
  こと自体はevalの失敗やverdict未記録のような「直すべき異常」ではないため、
  一度知らせたら二度と鳴らさない。

## 実装済み（v2 第六弾）

opencode版（`~/masayoshi/graphhopper-opencode`）へのhandoff基盤移植で、逆にこちら側に
無かったものが見つかり、3点を取り込んだ（2026-08-14）:

- **`.graphhopper/config.json`（プロジェクト単位の永続設定、任意・.gitignore対象）**:
  opencode版が最初から持っていたプロジェクト単位設定ファイル方式をClaude Code版にも導入。
  `polish_threshold_lines`/`handoff_threshold_kb`を設定できる。優先順位は
  **env var（アドホックな一時上書き） > config.json（永続設定） > ハードコードdefault**
  ——既存の`GH_POLISH_THRESHOLD`等のアドホックなenv var上書きを壊さないため、env varを
  最優先に残した。`hooks/lib/common.sh`の`gh_config_get()`。`.gitignore`は
  `.graphhopper/*` + `!.graphhopper/config.example.json`のallowlist方式（opencode版と
  同じ）。`design-gate.sh`は`.graphhopper/`への`Edit`/`Write`ツール経由の直接編集のみ
  ブロックするので、config.jsonの作成・編集はBash経由（`cp config.example.json
  config.json`等）で行う——ゲートの対象外で問題ない（config.jsonはverifierのdrift検出
  整合性に関わる「state」ではなく「設定」なので、design.md/state.jsonと同じ保護は不要）。
- **design.md質レビューの推奨を強化**: opencode版のSKILL.mdが「criticは安価な常設nodeな
  ので毎goal必ず呼ぶ」と強い運用規約になっているのを参考に、`CLAUDE.md`の`design-set`の
  説明に「designingを抜ける前に1回呼ぶことを強く推奨する」を追記。ハードゲート化はしない
  という結論（第五弾）は変えず、文言だけ強めた。
- **handoff自動起動（パターン2）**: `bin/graphhopper handoff --launch`。
  `crypto.randomUUID()`でsession idを事前生成し、`claude --session-id <uuid> --name
  gh-handoff-<uuid先頭8桁> --bg --permission-mode auto "<handoffテキスト>"`を
  `execFileSync`（argv配列、シェル文字列展開なし——goalが自由記述テキストなので
  コマンドインジェクション対策として必須）で起動する。起動後すぐにsession id/nameが
  分かる（claudeの標準出力を解析する必要が無い）。`--bg`は無人で返るため、
  permission modeを明示しないと最初のEdit/Bash要求で無人のまま止まる。`auto`
  （Anthropicの自動判定モード）をユーザー確認の上で既定にした——`acceptEdits`は
  Bash（eval_cmd実行）がゲートされたままで実質止まる、無指定は最初のゲートで確実に
  止まる、を比較した上での選択。既存の手動パターン（`bin/graphhopper handoff`が
  テキストを出力するだけ、ユーザーが自分で新規session/`claude "$(...)"`を叩く）は
  そのまま残す——用途が違う（自分で見ながら継続したいか、無人で先に進めておきたいか）。
  argv配列でのコマンドインジェクション対策はフェイクclaudeバイナリ（実起動はせず
  argvをファイルに書き出すだけ）で`$(rm -rf /)`等を含むgoal文字列が単一引数として
  素通しされることを確認済み。

## 未実装（次の候補）

- **headless(`claude -p`)モードでの steer 継続**: `/advisor` を実際に呼ぶアクションが無い
  headless実行だと、loop-driverのexit 2 steerがモデルに行動を促せず空回りしてtimeoutする
  ことを確認済み（インタラクティブセッションでは問題にならない想定だが未検証）。

## opencode / pi アダプタ

opencode版は`~/masayoshi/graphhopper-opencode`に実装済み（2026-08-05新規実装、
`kok1eee/graphhopper-opencode`にpush済み）。Workflowが無い代わりに`task()`の手動
fan-out + TS toolでround cap/dedupeを強制する方式。3相グラフ・agent minimalism・
tieringはこちら側と同じ原則を踏襲しつつ、`graphhopper-critic`（pre-hoc design
review常設node）や`graphhopper-oracle`（stuck escalation軸）等、こちら側には無い
拡張も持つ（両者は独立に進化しており、今回のhandoff基盤のように一方に入れた改善を
もう一方にも輸入する運用を今後も続ける）。pi版は未着手。
