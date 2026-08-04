# CLAUDE.md — graphhopper リポで作業するときの指針

graphhopper は flywheel（Claude Code plugin, `~/masayoshi/flywheel`）の後継。
done 直前の council（Sonnet 3体 fan-out）がトークンコストの主因だったため、
graph engineering を中心に据えて一から作り直した最小コア（v1）。

## 鉄則: agent は判断のためだけに使う。配管には使わない

graphhopper の agent 構成は意図的に薄い:

- **researcher**（`model: haiku` 固定）— 事実収集専用。高頻度・判断を含まないので
  メインの文脈を汚さず最安モデルに投げる価値がある。
- **メインの対話エージェント自身** — designing phase で `plan/design.md` を直接書く。
  design を合成する専用の `designer` subagent は**作らない**（design は判断そのものであり、
  メインから切り出す理由が無い）。
- **built-in `/advisor`** — done 直前の唯一の判断ゲート。敵対レビューが要る場面
  （flywheelの`grill`/`critic`相当）も含めて全部これに一本化する。専用の `critic` subagent
  も**作らない**。

判断（design合成・敵対レビュー・doneゲート）を複数の専用 subagent に分散させると、
council の再発になる（トークンコストの再燃）。**判断は「メイン + advisor」の2層で足りる**。
将来 agent を追加したくなったら、まず「これは事実収集か、判断か」を自問し、判断なら
既存の2層に収まらないか先に検討する。

**例外（v2）**: polish/simplify council の verifier fan-out（adversarial/diverse-lens）は
専用の「designer/critic」を切り出すのとは別物。同じ判断を複数の独立した目で検証する
**判断の分散**であり、この原則には抵触しない。詳細は `ROADMAP.md`。

## state machine

```
designing → implementing ⇄(eval fail) → polish [router gate]
  diff小 → built-in /advisor 単体          → clean: done / drift: implementing
  diff大 → Skill: polish (verifier fan-out) → clean: done / drift: implementing
```

C-2相当の不変条件: designing 中は `hooks/design-gate.sh` が source 編集を物理ブロックする。
`.graphhopper/` への直接編集も全phaseで禁止（状態変更は `bin/graphhopper` CLI 経由のみ）。

## headless (`claude -p`) では GRAPHHOPPER_OFF=1 を使う

`claude -p` のような print/headless モードは `/advisor` を対話的に呼び続ける前提が成立せず、
`loop-driver.sh` の steer ループが空回りして timeout する（実際に再現・確認済み）。
print/headless モードを hook から自動検出する公式な方法は無い（session_id 等の JSON
フィールド・env var どちらにも indicator が無いことを調査済み）ため、自動判定より
明示 opt-out を選ぶ。headless 実行時は `GRAPHHOPPER_OFF=1` を明示すると
`design-gate.sh` / `loop-driver.sh` が即 exit 0 になる（flywheel の `FLYWHEEL_OFF=1` と同じ
設計。`hooks/lib/common.sh` の `gh_disabled()`）。

## 詳細

グラフエンジンの実装は `graph-engine/src/engine.ts`（TypeScript, bun直接実行）。
v2 方向性（polish/simplify council を Dynamic Workflows の `parallel()`/verifier パターンで
実装する等）は `ROADMAP.md` を参照。
