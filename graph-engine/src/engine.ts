/**
 * graphhopper graph engine — node/edge/phase 遷移を計算し .graphhopper/state.json を更新する。
 * bun で直接実行する CLI（ビルド不要）。bin/graphhopper と hooks/*.sh から呼ばれる。
 */
import { execSync } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type Phase = "designing" | "implementing" | "polish" | "done";

export interface Edge {
  from: Phase;
  event: string;
  to: Phase;
}

export interface GraphDef {
  phases: Phase[];
  initial: Phase;
  edges: Edge[];
}

export type VerdictLevel = "clean" | "drift";
export type VerdictSource = "advisor" | "verifier";

export interface Verdict {
  source: VerdictSource;
  level: VerdictLevel;
  reason: string;
  ts: string;
}

export interface State {
  phase: Phase;
  goal: string;
  eval_cmd: string;
  baseline_rev: string;
  verdict: Verdict | null;
  /** polish フェーズで simplify を実行済みか（goal につき1回。polish に入る遷移で false にリセット） */
  polished: boolean;
  created_at: string;
  updated_at: string;
}

export interface HistoryEntry {
  ts: string;
  event: string;
  from: Phase;
  to: Phase;
}

function pluginRoot(): string {
  // src/engine.ts -> src -> graph-engine -> <plugin root>
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, "..", "..");
}

function repoRoot(): string {
  try {
    return execSync("jj root", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    // fall through
  }
  try {
    return execSync("git rev-parse --show-toplevel", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return process.cwd();
  }
}

/** 現在の working copy の commit id（jj優先、gitフォールバック）。init時のbaseline捕捉に使う。 */
function currentRev(root: string): string {
  try {
    return execSync("jj log -r @ --no-graph -T commit_id", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      cwd: root,
    }).trim();
  } catch {
    // fall through
  }
  try {
    return execSync("git rev-parse HEAD", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      cwd: root,
    }).trim();
  } catch {
    return "";
  }
}

/** baseline_rev からの変更行数（追加+削除）。router gate（diff規模判定）に使う。 */
export function diffLines(baselineRev: string): number {
  const root = repoRoot();
  if (!baselineRev) return 0;
  try {
    const out = execSync(`jj diff --from ${baselineRev} --stat`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      cwd: root,
    });
    return sumStatLines(out);
  } catch {
    // fall through
  }
  try {
    const out = execSync(`git diff --shortstat ${baselineRev}`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      cwd: root,
    });
    const m = out.match(/(\d+) insertion.*?(\d+) deletion/s);
    if (m) return Number(m[1]) + Number(m[2]);
    const insOnly = out.match(/(\d+) insertion/);
    const delOnly = out.match(/(\d+) deletion/);
    return (
      (insOnly ? Number(insOnly[1]) : 0) + (delOnly ? Number(delOnly[1]) : 0)
    );
  } catch {
    return 0;
  }
}

function sumStatLines(statOutput: string): number {
  // jj diff --stat の最終行 "N files changed, M insertions(+), K deletions(-)" 相当を拾う
  const m = statOutput.match(/(\d+) insertion.*?(\d+) deletion/s);
  if (m) return Number(m[1]) + Number(m[2]);
  const insOnly = statOutput.match(/(\d+) insertion/);
  const delOnly = statOutput.match(/(\d+) deletion/);
  if (insOnly || delOnly) {
    return (
      (insOnly ? Number(insOnly[1]) : 0) + (delOnly ? Number(delOnly[1]) : 0)
    );
  }
  // フォーマットが取れない場合は変更ファイル数×1行として非ゼロを返す（skipせず安全側=fan-out実行に倒す）
  const lines = statOutput.trim().split("\n").filter(Boolean);
  return lines.length > 0 ? lines.length * 10 : 0;
}

function graphhopperDir(): string {
  return join(repoRoot(), ".graphhopper");
}

function statePath(): string {
  return join(graphhopperDir(), "state.json");
}

function historyPath(): string {
  return join(graphhopperDir(), "history.jsonl");
}

function loadGraph(): GraphDef {
  const raw = readFileSync(
    join(pluginRoot(), "graph-engine", "graph.json"),
    "utf8",
  );
  return JSON.parse(raw) as GraphDef;
}

function now(): string {
  return new Date().toISOString();
}

export function stateExists(): boolean {
  return existsSync(statePath());
}

export function loadState(): State {
  const raw = readFileSync(statePath(), "utf8");
  return JSON.parse(raw) as State;
}

function appendHistory(entry: HistoryEntry): void {
  appendFileSync(historyPath(), `${JSON.stringify(entry)}\n`, "utf8");
}

function saveState(state: State, event: string, from: Phase): void {
  state.updated_at = now();
  writeFileSync(statePath(), `${JSON.stringify(state, null, 2)}\n`, "utf8");
  appendHistory({ ts: state.updated_at, event, from, to: state.phase });
}

export function initState(goal: string): State {
  const root = repoRoot();
  mkdirSync(graphhopperDir(), { recursive: true });
  const graph = loadGraph();
  const ts = now();
  const state: State = {
    phase: graph.initial,
    goal,
    eval_cmd: "",
    baseline_rev: currentRev(root),
    verdict: null,
    polished: false,
    created_at: ts,
    updated_at: ts,
  };
  writeFileSync(statePath(), `${JSON.stringify(state, null, 2)}\n`, "utf8");
  writeFileSync(historyPath(), "", "utf8");
  appendHistory({ ts, event: "init", from: graph.initial, to: graph.initial });
  return state;
}

export function resetState(): void {
  if (existsSync(statePath())) rmSync(statePath());
  if (existsSync(historyPath())) rmSync(historyPath());
}

export function setEval(cmd: string): State {
  const state = loadState();
  state.eval_cmd = cmd;
  saveState(state, "set_eval", state.phase);
  return state;
}

export function verdictSet(
  source: VerdictSource,
  level: VerdictLevel,
  reason: string,
): State {
  const state = loadState();
  state.verdict = { source, level, reason, ts: now() };
  saveState(state, `${source}_${level}`, state.phase);
  return state;
}

/** graph.json のエッジ定義に基づき phase を遷移する。該当エッジが無ければ変化なし。 */
export function transition(event: string): State {
  const graph = loadGraph();
  const state = loadState();
  const from = state.phase;
  const edge = graph.edges.find((e) => e.from === from && e.event === event);
  if (edge) {
    state.phase = edge.to;
    if (edge.to !== "polish") {
      // polish フェーズに入る/出る以外の遷移では verdict を持ち越さない
      state.verdict = null;
    }
    if (edge.to === "polish") {
      // polish に入るたび simplify をリセット（goal につき1回だけ simplify する）
      state.polished = false;
    }
  }
  saveState(state, event, from);
  return state;
}

export function getField(state: State, path: string): unknown {
  const parts = path.split(".");
  let cur: unknown = state;
  for (const part of parts) {
    if (cur === null || cur === undefined || typeof cur !== "object")
      return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}

function formatStatus(state: State): string {
  return [
    `goal: ${state.goal || "(none)"}`,
    `phase: ${state.phase}`,
    `eval_cmd: ${state.eval_cmd || "(none)"}`,
    `baseline_rev: ${state.baseline_rev || "(none)"}`,
    `verdict: ${
      state.verdict
        ? `${state.verdict.source}:${state.verdict.level} — ${state.verdict.reason}`
        : "(pending)"
    }`,
    `polished: ${state.polished}`,
    `updated_at: ${state.updated_at}`,
  ].join("\n");
}

function main(): void {
  const [, , cmd, ...args] = process.argv;

  switch (cmd) {
    case "init": {
      const goal = args.join(" ");
      const state = initState(goal);
      console.log(`initialized. phase: ${state.phase}`);
      break;
    }
    case "status": {
      if (!stateExists()) {
        console.log('no active goal (run: graphhopper init "<goal>")');
        break;
      }
      console.log(formatStatus(loadState()));
      break;
    }
    case "get": {
      const path = args[0];
      if (!path) {
        console.error("usage: engine.ts get <field.path>");
        process.exitCode = 1;
        break;
      }
      const value = getField(loadState(), path);
      console.log(typeof value === "string" ? value : JSON.stringify(value));
      break;
    }
    case "set": {
      const field = args[0];
      const value = args[1];
      if (field === "polished") {
        if (value !== "true" && value !== "false") {
          console.error("usage: engine.ts set polished <true|false>");
          process.exitCode = 1;
          break;
        }
        const state = loadState();
        state.polished = value === "true";
        saveState(state, "set_polished", state.phase);
        console.log(`polished set to ${state.polished}`);
      } else {
        console.error(`unknown field: ${field}`);
        process.exitCode = 1;
      }
      break;
    }
    case "set-eval": {
      const evalCmd = args.join(" ");
      setEval(evalCmd);
      console.log("eval_cmd updated");
      break;
    }
    case "advisor-set": {
      const level = args[0];
      const reason = args.slice(1).join(" ");
      if (level !== "clean" && level !== "drift") {
        console.error("usage: engine.ts advisor-set <clean|drift> <reason>");
        process.exitCode = 1;
        break;
      }
      const state = verdictSet("advisor", level, reason);
      console.log(
        `verdict recorded (advisor): ${level}. phase: ${state.phase}`,
      );
      break;
    }
    case "verifier-set": {
      const level = args[0];
      const reason = args.slice(1).join(" ");
      if (level !== "clean" && level !== "drift") {
        console.error("usage: engine.ts verifier-set <clean|drift> <reason>");
        process.exitCode = 1;
        break;
      }
      const state = verdictSet("verifier", level, reason);
      console.log(
        `verdict recorded (verifier): ${level}. phase: ${state.phase}`,
      );
      break;
    }
    case "diff-lines": {
      const state = loadState();
      console.log(String(diffLines(state.baseline_rev)));
      break;
    }
    case "transition": {
      const event = args[0];
      if (!event) {
        console.error("usage: engine.ts transition <event>");
        process.exitCode = 1;
        break;
      }
      const state = transition(event);
      console.log(`phase -> ${state.phase}`);
      break;
    }
    case "reset": {
      resetState();
      console.log("reset done");
      break;
    }
    default: {
      console.error(
        "usage: engine.ts <init|status|get|set|set-eval|advisor-set|verifier-set|diff-lines|transition|reset> [args...]",
      );
      process.exitCode = 1;
    }
  }
}

if (import.meta.main) {
  main();
}
