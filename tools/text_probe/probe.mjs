// 텍스트 모델 프로브 — docs/task_text_model_v1.md §3.
//
// 앱 빌드·함수 배포 없이 텍스트 모델 후보(G0 현행 / G1 Gemini 최신 / C Claude
// Sonnet)를 같은 프롬프트로 비교한다. 프롬프트는 다시 쓰지 않는다 — 앱의 빌더
// 출력을 덤프한 input/prompts.json(test/text_probe_dump_test.dart)을 그대로 보낸다.
// Node 22+ 내장 fetch만 쓴다(외부 의존성 없음). tools/fitting_probe의 관례를 따른다.
//
// 키는 환경변수로만: GEMINI_API_KEY(x-goog-api-key 헤더), ANTHROPIC_API_KEY
// (x-api-key 헤더). 둘 다 URL에 싣지 않고, 로그·오류 문자열에 섞여도 mask()가 가린다.
// ANTHROPIC_API_KEY가 없으면 Gemini 후보만 돌리고 그 사실을 결과에 적는다.
//
//   node probe.mjs schema   # §3-2 스키마 확정 호출(약 20회)
//   node probe.mjs run      # §3-3 측정(후보 3개 합계 약 258회, schema.json 필요)
//   node probe.mjs run --candidates G0,G1 --tasks T1   # 부분 재실행(같은 칸은 덮어씀)
//   node probe.mjs run --candidates C --tasks T1 --claude-effort medium   # §3-4 사전 허용 추가 실행("C@medium"으로 따로 저장)
//   node probe.mjs report   # results.json → results.md·index.html 재생성

import {readFileSync, writeFileSync, existsSync, mkdirSync} from "node:fs";
import {join, dirname, resolve} from "node:path";
import {fileURLToPath} from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const INPUT = join(HERE, "input");
const OUTPUT = join(HERE, "output");
const RAW = join(OUTPUT, "raw");

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta";
const CLAUDE_URL = "https://api.anthropic.com/v1/messages";
const CALL_TIMEOUT_MS = 90_000; // §3-1
const CONCURRENCY = 3; // §3-1 제공자별 동시 3건

const CANDIDATES = {
  G0: {provider: "gemini", model: "gemini-3.5-flash", note: "현행(기준선)"},
  G1: {provider: "gemini", model: "gemini-3.8-flash", note: "Gemini 최신 안정 Flash"},
  C: {provider: "claude", model: "claude-sonnet-5-5", note: "Claude Sonnet 5.5"},
};
const GEMINI_FALLBACK_CANDIDATES = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"];

// §3-4가 사전 허용한 C 추가 실행(effort 한 단계 상향 등)은 "C@<effort>" 키로 따로
// 저장한다 — 원래 C 결과를 덮어쓰지 않는다. 모델·제공자는 C와 같다.
function candOf(key) {
  const [base, effort] = key.split("@");
  const c = CANDIDATES[base];
  return effort ? {...c, note: `${c.note} · effort ${effort}`, effort} : c;
}
const candRank = (k) => Object.keys(CANDIDATES).indexOf(k.split("@")[0]) * 10 + (k.includes("@") ? 1 : 0);
const candLabel = (k) => `${candOf(k).model}${candOf(k).effort ? ` (effort ${candOf(k).effort})` : ""}`;

// §3-3 T1·T4 본문 비교에 보일 쌍 — 결과를 보기 전에 고정.
const T1_SHOWCASE_PAIRS = ["p001", "p007", "p013"];

const GEMINI_KEY = process.env.GEMINI_API_KEY ?? "";
const CLAUDE_KEY = process.env.ANTHROPIC_API_KEY ?? "";
const mask = (s) => {
  let out = String(s);
  for (const k of [GEMINI_KEY, CLAUDE_KEY]) if (k) out = out.split(k).join("***");
  return out;
};
const log = (...a) => console.log(mask(a.join(" ")));
const median = (xs) => {
  const v = xs.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
};
const mean = (xs) => {
  const v = xs.filter((x) => Number.isFinite(x));
  return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null;
};
const round1 = (x) => (x == null ? null : Math.round(x * 10) / 10);

// ── 입력 ──────────────────────────────────────────────────────────
function loadPrompts() {
  const p = join(INPUT, "prompts.json");
  if (!existsSync(p)) {
    console.error([
      "input/prompts.json이 없습니다. 준비 순서(키 불필요):",
      "  1) python fetch_items.py --credentials <서비스 계정 키>   → input/items.json",
      "  2) TEXT_PROBE_DUMP=1 flutter test test/text_probe_dump_test.dart  (저장소 루트에서) → input/prompts.json",
    ].join("\n"));
    process.exit(2);
  }
  return JSON.parse(readFileSync(p, "utf8"));
}

function sniffMime(buf) {
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return "image/png";
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "image/jpeg";
  if (buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  return "image/jpeg";
}

const imageCache = new Map();
function imagePart(relPath) {
  if (!imageCache.has(relPath)) {
    const buf = readFileSync(resolve(REPO, relPath));
    imageCache.set(relPath, {mime: sniffMime(buf), data: buf.toString("base64")});
  }
  const img = imageCache.get(relPath);
  return {inlineData: {mimeType: img.mime, data: img.data}};
}

const PERSON_IMAGE = "tools/fitting_probe/input/person.jpg";

// 과제별 요청 — Gemini 형식(parts + 앱의 generationConfig). Claude는 아래에서 변환.
function buildTasks(prompts) {
  const gc = prompts.generationConfig;
  const tasks = [];
  for (const c of prompts.t1) {
    for (const rep of [1, 2]) {
      tasks.push({task: "T1", id: `${c.pairId}_${c.side}_r${rep}`, meta: {pairId: c.pairId, side: c.side, rep},
        parts: [{text: c.prompt}], generationConfig: gc.outfitAnalysis, kind: "analysis"});
    }
  }
  for (const c of prompts.t2) {
    // 앱은 원본 사진을 image/jpeg로 보내지만, 프로브 입력은 라벨링 자료의 PNG라
    // 실제 형식(매직 넘버)으로 표기한다 — 후보 모두에 같은 조건.
    tasks.push({task: "T2", id: c.itemId, meta: {itemId: c.itemId, category: c.category},
      parts: [{text: c.prompt}, imagePart(c.imageFile)], generationConfig: gc.attributeExtraction, kind: "json"});
  }
  for (const rep of [1, 2, 3]) {
    tasks.push({task: "T3", id: `r${rep}`, meta: {rep}, parts: [{text: prompts.t3.prompt}],
      generationConfig: gc.weeklyPlan, kind: "json"});
  }
  prompts.t4.forEach((c, i) => {
    tasks.push({task: "T4", id: `c${i + 1}`, meta: {slots: c.slots}, stream: true,
      parts: [{text: c.prompt}, imagePart(PERSON_IMAGE)], generationConfig: gc.outfitAnalysis, kind: "analysis"});
  });
  return tasks;
}

// ── 호출: Gemini ──────────────────────────────────────────────────
function geminiConfig(cand, task, schema) {
  const gc = structuredClone(task.generationConfig);
  // §3-2에서 thinkingBudget 0이 거부된 모델이면 확정한 대체 필드로 바꾼다.
  const repl = schema?.gemini?.[cand.model]?.thinkingReplacement;
  if (repl && gc.thinkingConfig) gc.thinkingConfig = repl;
  return gc;
}

// 앱 _extractTextFromResponse와 같은 규칙: candidates[0].content.parts[0].text.
function geminiText(json) {
  const parts = json?.candidates?.[0]?.content?.parts;
  const t = parts?.[0]?.text;
  return typeof t === "string" ? t : null;
}

async function callGemini(model, task, gc) {
  const body = JSON.stringify({contents: [{parts: task.parts}], generationConfig: gc});
  const url = task.stream ?
    `${GEMINI_BASE}/models/${model}:streamGenerateContent?alt=sse` :
    `${GEMINI_BASE}/models/${model}:generateContent`;
  const t0 = performance.now();
  const res = await fetch(url, {
    method: "POST",
    headers: {"content-type": "application/json", "x-goog-api-key": GEMINI_KEY},
    body, signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
  });
  if (!task.stream) {
    const text = await res.text();
    const secs = (performance.now() - t0) / 1000;
    let json = null;
    try { json = JSON.parse(text); } catch { /* 아래 */ }
    if (!res.ok) return {status: res.status, secs, error: json?.error?.message ?? text.slice(0, 300)};
    return {status: res.status, secs, text: geminiText(json), usage: json?.usageMetadata ?? null,
      finish: json?.candidates?.[0]?.finishReason ?? null, modelVersion: json?.modelVersion ?? null};
  }
  if (!res.ok) {
    const text = await res.text();
    return {status: res.status, secs: (performance.now() - t0) / 1000, error: text.slice(0, 300)};
  }
  // SSE: 앱(_callProxyTextStream)처럼 이벤트마다 parts[0].text를 이어 붙인다.
  let firstSecs = null;
  let out = "";
  let usage = null;
  let finish = null;
  for await (const data of sseData(res.body)) {
    let j;
    try { j = JSON.parse(data); } catch { continue; }
    const t = geminiText(j);
    if (t) {
      if (firstSecs == null) firstSecs = (performance.now() - t0) / 1000;
      out += t;
    }
    if (j.usageMetadata) usage = j.usageMetadata;
    if (j.candidates?.[0]?.finishReason) finish = j.candidates[0].finishReason;
  }
  return {status: res.status, secs: (performance.now() - t0) / 1000, firstSecs, text: out, usage, finish};
}

// SSE 블록(빈 줄로 구분)마다 data: 줄을 꺼낸다. Gemini는 CRLF, Anthropic은 LF로
// 구분하므로 줄바꿈을 LF로 맞춘 뒤 자르고, 스트림 끝에 남은 블록도 처리한다.
async function* sseData(stream) {
  const decoder = new TextDecoder();
  let buf = "";
  const take = (block) => block.split("\n").filter((l) => l.startsWith("data:"))
    .map((l) => l.slice(5).trimStart()).join("\n");
  for await (const chunk of stream) {
    buf = (buf + decoder.decode(chunk, {stream: true})).replace(/\r\n/g, "\n");
    let idx;
    while ((idx = buf.indexOf("\n\n")) >= 0) {
      const data = take(buf.slice(0, idx));
      buf = buf.slice(idx + 2);
      if (data) yield data;
    }
  }
  const rest = take(buf.trim());
  if (rest) yield rest;
}

// ── 호출: Claude ──────────────────────────────────────────────────
// Gemini parts → Claude content blocks(순서 유지). 샘플링 값은 보내지 않는다.
function claudeContent(parts) {
  return parts.map((p) => (p.text != null ?
    {type: "text", text: p.text} :
    {type: "image", source: {type: "base64", media_type: p.inlineData.mimeType, data: p.inlineData.data}}));
}

function claudeBody(model, task, cfg, extra = {}) {
  const maxTokens = cfg.maxTokens?.[task.task] ?? cfg.maxTokens?.default ?? 4000;
  const body = {model, max_tokens: maxTokens, messages: [{role: "user", content: claudeContent(task.parts)}]};
  if (cfg.thinking) body.thinking = cfg.thinking;
  if (cfg.effort) body.output_config = {effort: cfg.effort};
  if (task.stream) body.stream = true;
  return {...body, ...extra};
}

function claudeHeaders(version) {
  return {"content-type": "application/json", "x-api-key": CLAUDE_KEY, "anthropic-version": version};
}

async function callClaudeRaw(body, version) {
  const t0 = performance.now();
  const res = await fetch(CLAUDE_URL, {
    method: "POST", headers: claudeHeaders(version), body: JSON.stringify(body),
    signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
  });
  if (!body.stream || !res.ok) {
    const text = await res.text();
    const secs = (performance.now() - t0) / 1000;
    let json = null;
    try { json = JSON.parse(text); } catch { /* 아래 */ }
    if (!res.ok) return {status: res.status, secs, error: json?.error?.message ?? text.slice(0, 300), errorType: json?.error?.type};
    const blocks = json?.content ?? [];
    return {status: res.status, secs, json,
      text: blocks.filter((b) => b.type === "text").map((b) => b.text).join(""),
      blockTypes: blocks.map((b) => b.type), usage: json?.usage ?? null, finish: json?.stop_reason ?? null,
      modelVersion: json?.model ?? null};
  }
  // 스트리밍: content_block_delta 중 text_delta만 본문으로 이어 붙인다.
  let firstSecs = null;
  let out = "";
  let usage = null;
  let finish = null;
  const eventTypes = [];
  const deltaTypes = new Set();
  for await (const data of sseData(res.body)) {
    let j;
    try { j = JSON.parse(data); } catch { continue; }
    if (eventTypes.length < 40) eventTypes.push(j.type);
    if (j.type === "content_block_delta") {
      deltaTypes.add(j.delta?.type);
      if (j.delta?.type === "text_delta") {
        if (firstSecs == null) firstSecs = (performance.now() - t0) / 1000;
        out += j.delta.text;
      }
    }
    if (j.type === "message_start") usage = j.message?.usage ?? usage;
    if (j.type === "message_delta") {
      finish = j.delta?.stop_reason ?? finish;
      usage = {...(usage ?? {}), ...(j.usage ?? {})};
    }
  }
  return {status: res.status, secs: (performance.now() - t0) / 1000, firstSecs, text: out, usage, finish,
    eventTypes, deltaTypes: [...deltaTypes]};
}

// ── 공통 실행 ─────────────────────────────────────────────────────
async function callOnce(candKey, task, schema) {
  const cand = candOf(candKey);
  try {
    if (cand.provider === "gemini") return await callGemini(cand.model, task, geminiConfig(cand, task, schema));
    const cfg = cand.effort ? {...schema.claude, effort: cand.effort} : schema.claude;
    return await callClaudeRaw(claudeBody(cand.model, task, cfg), schema.claude.version);
  } catch (e) {
    return {status: 0, secs: null, error: e?.name === "TimeoutError" ? `시한 초과(${CALL_TIMEOUT_MS / 1000}초)` : `${e?.name}: ${e?.message}`};
  }
}

// §3-1: 실패(HTTP 오류·시한 초과·네트워크)는 1회만 재시도하고 기록한다.
// 형식 실패(점수·JSON 파싱)는 재시도하지 않는다 — 그 자체가 측정값이다.
async function callWithRetry(candKey, task, schema) {
  const first = await callOnce(candKey, task, schema);
  if (first.status === 200 && first.error == null) return {...first, retried: false};
  const second = await callOnce(candKey, task, schema);
  return {...second, retried: true, firstError: mask(`${first.status} ${first.error ?? ""}`).slice(0, 300)};
}

async function pool(items, n, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({length: Math.min(n, items.length)}, async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  }));
  return out;
}

// ── 평가 ──────────────────────────────────────────────────────────
// outfit_self_evaluator.dart parseScore와 같은 규칙.
function parseScore(text) {
  if (typeof text !== "string") return null;
  const m = /\[총점\]\s*(\d+)/.exec(text) ?? /\[점수\]\s*(\d+)/.exec(text);
  if (!m) return null;
  const n = parseInt(m[1], 10);
  return Number.isFinite(n) ? Math.min(100, Math.max(1, n)) : null;
}

// gemini_service.dart _parseJsonObject와 같은 규칙(펜스 제거 → 첫 '{'~마지막 '}').
function parseJsonObject(text) {
  if (typeof text !== "string") return null;
  const cleaned = text.trim().replace(/```json\s*/g, "").replace(/```\s*/g, "");
  const s = cleaned.indexOf("{");
  const e = cleaned.lastIndexOf("}");
  if (s < 0 || e < s) return null;
  try { return JSON.parse(cleaned.slice(s, e + 1)); } catch { return null; }
}

// agent_planner.dart _parsePlanArray와 같은 규칙.
function parsePlanArray(text) {
  if (typeof text !== "string") return [];
  const cleaned = text.trim().replace(/```json\s*/g, "").replace(/```\s*/g, "");
  const s = cleaned.indexOf("[");
  const e = cleaned.lastIndexOf("]");
  if (s < 0 || e < s) return [];
  try {
    const v = JSON.parse(cleaned.slice(s, e + 1));
    return Array.isArray(v) ? v.filter((x) => x && typeof x === "object" && !Array.isArray(x)) : [];
  } catch { return []; }
}

const JAPANESE = /[぀-ヿㇰ-ㇿｦ-ﾟ㐀-䶿一-鿿]/;
const ATTR_KEYS = ["color", "style", "pattern", "formality", "fit", "tags"];

function evalT2(text) {
  const obj = parseJsonObject(text);
  if (!obj) return {jsonValid: false, keysOk: false, japanese: false};
  const keysOk = ["color", "style", "pattern", "formality", "fit"].every((k) => typeof obj[k] === "string" && obj[k].trim()) &&
    Array.isArray(obj.tags);
  const values = ATTR_KEYS.flatMap((k) => (Array.isArray(obj[k]) ? obj[k] : [obj[k]])).filter((v) => typeof v === "string");
  return {jsonValid: true, keysOk, japanese: values.some((v) => JAPANESE.test(v)), attrs: obj};
}

function evalT3(text, t3) {
  const valid = new Set(t3.catalogIds);
  const rows = parsePlanArray(text);
  // 앱의 검증: 날짜가 파싱되고 옷장에 있는 id가 하나 이상인 행만 남기고, 하나도
  // 없으면 실패(agent_planner.dart generateWeeklyPlan).
  const kept = rows.filter((r) => typeof r.date === "string" && !Number.isNaN(Date.parse(r.date)) &&
    Array.isArray(r.itemIds) && r.itemIds.some((id) => valid.has(String(id))));
  const allIds = rows.flatMap((r) => (Array.isArray(r.itemIds) ? r.itemIds.map(String) : []));
  const datesCovered = t3.dates.filter((d) => kept.some((r) => r.date === d)).length;
  // 참고 지표: 같은 상의·하의 이틀 연속(프롬프트 제약).
  const byDate = Object.fromEntries(kept.map((r) => [r.date, r.itemIds.map(String)]));
  let consecutive = 0;
  for (let i = 1; i < t3.dates.length; i++) {
    const a = byDate[t3.dates[i - 1]] ?? [];
    const b = byDate[t3.dates[i]] ?? [];
    consecutive += a.filter((id) => b.includes(id) && ["상의", "하의"].includes(t3.categories[id])).length;
  }
  return {appPass: kept.length > 0, rows: rows.length, kept: kept.length, datesCovered,
    invalidIds: allIds.filter((id) => !valid.has(id)).length, consecutiveRepeats: consecutive};
}

function loadLabels() {
  const dir = join(REPO, "tools/eval_harness_selfeval/responses");
  const files = ["박.json", "지유.json", "박서정.json"];
  return files.map((f) => {
    const r = JSON.parse(readFileSync(join(dir, f), "utf8"));
    return Object.fromEntries(r.photo.labels.map((l) => [l.pairId, l.choice]));
  });
}

// 사람 다수결 — docs/task_selfeval_validity_v1.md §9 등록 정의: 사진 조건, 3명 중
// 2명 이상 같은 선택이면 다수결 라벨(`unsure`도 하나의 선택지), 다수 없으면 제외.
// 주의 확인 쌍(p004·p013)도 제외하지 않는다(그 문서의 주 판정과 같음).
function majorityLabels(labelers, pairIds) {
  const out = {};
  for (const pid of pairIds) {
    const counts = {};
    for (const l of labelers) if (l[pid]) counts[l[pid]] = (counts[l[pid]] ?? 0) + 1;
    const [choice, n] = Object.entries(counts).sort((a, b) => b[1] - a[1])[0] ?? [];
    if (n >= 2 && (choice === "left" || choice === "right")) out[pid] = {choice, unanimous: n === 3};
  }
  return out;
}

function agreementScore(majority, scoresBySide) {
  // 모델 선택 = 두 회 평균 점수가 높은 쪽. 같으면 0.5. 한쪽이라도 점수가 없으면 0(실패로 셈).
  let sum = 0;
  let n = 0;
  const detail = {};
  for (const [pid, m] of Object.entries(majority)) {
    n++;
    const l = mean(scoresBySide[`${pid}_left`] ?? []);
    const r = mean(scoresBySide[`${pid}_right`] ?? []);
    let v;
    if (l == null || r == null) v = 0;
    else if (l === r) v = 0.5;
    else v = ((l > r ? "left" : "right") === m.choice) ? 1 : 0;
    detail[pid] = v;
    sum += v;
  }
  return {sum, n, detail};
}

// ── schema (§3-2) ─────────────────────────────────────────────────
async function rawGemini(model, body) {
  const t0 = performance.now();
  try {
    const res = await fetch(`${GEMINI_BASE}/models/${model}:generateContent`, {
      method: "POST", headers: {"content-type": "application/json", "x-goog-api-key": GEMINI_KEY},
      body: JSON.stringify(body), signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* */ }
    return {status: res.status, secs: (performance.now() - t0) / 1000, json,
      error: res.ok ? null : mask(json?.error?.message ?? text.slice(0, 300))};
  } catch (e) {
    return {status: 0, secs: (performance.now() - t0) / 1000, error: `${e?.name}: ${e?.message}`};
  }
}

async function modelGet(model) {
  try {
    const res = await fetch(`${GEMINI_BASE}/models/${model}`, {headers: {"x-goog-api-key": GEMINI_KEY}, signal: AbortSignal.timeout(30_000)});
    const j = await res.json().catch(() => null);
    return {status: res.status, methods: j?.supportedGenerationMethods ?? null, error: res.ok ? null : mask(j?.error?.message ?? "")};
  } catch (e) {
    return {status: 0, error: `${e?.name}: ${e?.message}`};
  }
}

async function runSchema() {
  const prompts = loadPrompts();
  const tasks = buildTasks(prompts);
  const t2 = tasks.find((t) => t.task === "T2");
  const t1 = tasks.find((t) => t.task === "T1");
  const t4 = tasks.find((t) => t.task === "T4");
  const s = {at: new Date().toISOString(), claudeAvailable: !!CLAUDE_KEY, gemini: {}, claude: null, calls: []};
  const rec = (name, r, extra = {}) => {
    const row = {name, status: r.status, secs: round1(r.secs), error: r.error ?? null, ...extra};
    s.calls.push(row);
    log(`[schema] ${name} → ${r.status} ${row.secs ?? "-"}s${r.error ? " · " + String(r.error).slice(0, 160) : ""}`);
    return row;
  };

  // ── Gemini ──
  for (const m of [CANDIDATES.G0.model, CANDIDATES.G1.model, ...GEMINI_FALLBACK_CANDIDATES]) {
    const g = await modelGet(m);
    s.gemini[m] = {modelsGet: g};
    log(`[schema] models.get ${m} → ${g.status} ${JSON.stringify(g.methods ?? g.error)}`);
  }
  for (const m of [CANDIDATES.G1.model, ...GEMINI_FALLBACK_CANDIDATES]) {
    // 1·2: 앱의 T2 설정 그대로(thinkingBudget 0 + responseMimeType + temperature).
    const body = {contents: [{parts: t2.parts}], generationConfig: t2.generationConfig};
    let r = await rawGemini(m, body);
    const asIs = rec(`gemini ${m} T2 앱 설정 그대로`, r, {
      thoughtsTokens: r.json?.usageMetadata?.thoughtsTokenCount ?? null,
      jsonValid: r.status === 200 ? !!parseJsonObject(geminiText(r.json)) : null});
    s.gemini[m].appConfigOk = asIs.status === 200;
    if (asIs.status !== 200) {
      for (const repl of [{thinkingLevel: "minimal"}, {thinkingLevel: "low"}]) {
        const gc = {...t2.generationConfig, thinkingConfig: repl};
        r = await rawGemini(m, {contents: [{parts: t2.parts}], generationConfig: gc});
        const row = rec(`gemini ${m} T2 thinkingConfig=${JSON.stringify(repl)}`, r,
          {thoughtsTokens: r.json?.usageMetadata?.thoughtsTokenCount ?? null});
        if (row.status === 200) { s.gemini[m].thinkingReplacement = repl; break; }
      }
    }
  }

  // ── Claude ──
  if (!CLAUDE_KEY) {
    log("[schema] ANTHROPIC_API_KEY 없음 — Claude 확인 생략, run은 Gemini 후보만 돈다.");
    return finishSchema(s);
  }
  const model = CANDIDATES.C.model;
  const tiny = {model, max_tokens: 64, messages: [{role: "user", content: "확인용입니다. '확인'이라고만 답하세요."}]};
  const c = {versions: {}, model};
  // 1. 인증·버전 헤더
  for (const v of ["2023-06-01", "2026-10-21"]) {
    const r = await callClaudeRaw(tiny, v);
    c.versions[v] = rec(`claude 버전 ${v} 최소 요청`, r, {blockTypes: r.blockTypes, stop: r.finish});
  }
  c.version = c.versions["2023-06-01"].status === 200 ? "2023-06-01" :
    c.versions["2026-10-21"].status === 200 ? "2026-10-21" : null;
  if (!c.version) {
    s.claude = c;
    log("[schema] Claude 인증·형식 문제로 한 번도 성공하지 못함 — §3-2에 따라 멈춘다.");
    return finishSchema(s);
  }
  // 2. temperature 400 여부(문서 확인용 1회)
  c.temperature = rec("claude temperature=0.2", await callClaudeRaw({...tiny, temperature: 0.2}, c.version));
  // 3. 사고 끄기·최소화
  c.thinkingDisabled = rec("claude thinking disabled", await callClaudeRaw({...tiny, thinking: {type: "disabled"}}, c.version));
  c.betweenTools = {};
  for (const effort of ["low", "medium", "high"]) {
    c.betweenTools[effort] = rec(`claude thinking between_tools + effort ${effort}`,
      await callClaudeRaw({...tiny, thinking: {type: "between_tools"}, output_config: {effort}}, c.version));
  }
  c.adaptiveLow = rec("claude thinking adaptive + effort low",
    await callClaudeRaw({...tiny, thinking: {type: "adaptive"}, output_config: {effort: "low"}}, c.version));
  c.effortValues = {};
  for (const effort of ["low", "medium", "high", "xhigh", "max"]) {
    c.effortValues[effort] = rec(`claude effort ${effort}(thinking 생략)`,
      await callClaudeRaw({...tiny, output_config: {effort}}, c.version)).status;
  }
  // 최소 사고 설정: between_tools(사고 끔) + effort low가 되면 그것, 아니면 adaptive + low.
  const cfg = c.betweenTools.low.status === 200 ?
    {thinking: {type: "between_tools"}, effort: "low", label: "between_tools + effort low"} :
    c.adaptiveLow.status === 200 ? {thinking: {type: "adaptive"}, effort: "low", label: "adaptive + effort low"} :
    {thinking: null, effort: "low", label: "effort low(thinking 생략)"};
  // 4·5. 이미지 입력 + 800토큰 분량 JSON이 잘리지 않는 max_tokens
  c.t2 = {};
  for (const mt of [800, 2000]) {
    const r = await callClaudeRaw(claudeBody(model, t2, {...cfg, maxTokens: {T2: mt}}), c.version);
    c.t2[mt] = rec(`claude T2 이미지(${t2.parts[1].inlineData.mimeType}) max_tokens ${mt}`, r, {
      blockTypes: r.blockTypes, stop: r.finish, outputTokens: r.usage?.output_tokens ?? null,
      jsonValid: r.status === 200 ? !!parseJsonObject(r.text) : null});
    if (r.status === 200 && r.finish !== "max_tokens" && parseJsonObject(r.text)) { c.t2MaxTokens = mt; break; }
  }
  // 분석(T1) 응답 블록 구조와 출력량
  const r1 = await callClaudeRaw(claudeBody(model, t1, {...cfg, maxTokens: {T1: 4000}}), c.version);
  c.t1 = rec("claude T1 분석 max_tokens 4000", r1, {blockTypes: r1.blockTypes, stop: r1.finish,
    outputTokens: r1.usage?.output_tokens ?? null, scoreParsed: parseScore(r1.text) != null});
  // 6. 스트리밍 이벤트 형태
  const r4 = await callClaudeRaw(claudeBody(model, t4, {...cfg, maxTokens: {T4: 4000}}), c.version);
  c.stream = rec("claude T4 스트리밍", r4, {eventTypes: r4.eventTypes, deltaTypes: r4.deltaTypes,
    firstSecs: round1(r4.firstSecs), stop: r4.finish});
  c.config = {...cfg, maxTokens: {T1: 4000, T2: c.t2MaxTokens ?? 2000, T3: 4000, T4: 4000}};
  s.claude = c;
  return finishSchema(s);
}

function finishSchema(s) {
  mkdirSync(OUTPUT, {recursive: true});
  writeFileSync(join(OUTPUT, "schema.json"), JSON.stringify(s, null, 2));
  writeReports();
  return s;
}

// ── run (§3-3) ────────────────────────────────────────────────────
async function runMeasure(args) {
  const schemaPath = join(OUTPUT, "schema.json");
  if (!existsSync(schemaPath)) { console.error("schema.json이 없습니다 — 먼저 `node probe.mjs schema`."); process.exit(2); }
  const schemaRaw = JSON.parse(readFileSync(schemaPath, "utf8"));
  const schema = {gemini: schemaRaw.gemini, claude: schemaRaw.claude?.config ? {...schemaRaw.claude.config, version: schemaRaw.claude.version} : null};
  const pick = (flag, all) => {
    const i = args.indexOf(flag);
    return i >= 0 ? args[i + 1].split(",") : all;
  };
  let candKeys = pick("--candidates", Object.keys(CANDIDATES));
  const taskKeys = pick("--tasks", ["T1", "T2", "T3", "T4"]);
  const ei = args.indexOf("--claude-effort");
  if (ei >= 0) candKeys = candKeys.map((k) => (k === "C" ? `C@${args[ei + 1]}` : k));
  const skipped = [];
  if (candKeys.some((k) => k.startsWith("C")) && (!CLAUDE_KEY || !schema.claude)) {
    candKeys = candKeys.filter((k) => !k.startsWith("C"));
    skipped.push(!CLAUDE_KEY ? "C: ANTHROPIC_API_KEY 없음" : "C: 스키마 확정 실패");
  }
  if (candKeys.includes("G1") && schemaRaw.gemini?.[CANDIDATES.G1.model]?.appConfigOk === false &&
      !schemaRaw.gemini?.[CANDIDATES.G1.model]?.thinkingReplacement) {
    candKeys = candKeys.filter((k) => k !== "G1");
    skipped.push("G1: 스키마 확정 실패(T2 설정 거부)");
  }
  const prompts = loadPrompts();
  const tasks = buildTasks(prompts).filter((t) => taskKeys.includes(t.task));
  const results = loadResults();
  results.skipped = skipped;
  results.runAt = new Date().toISOString();
  mkdirSync(RAW, {recursive: true});

  const byProvider = {gemini: [], claude: []};
  for (const ck of candKeys) for (const t of tasks) byProvider[candOf(ck).provider].push({ck, t});
  log(`[run] 후보 ${candKeys.join(",")} · 과제 ${taskKeys.join(",")} · 호출 ${byProvider.gemini.length + byProvider.claude.length}회 예정${skipped.length ? " · 건너뜀: " + skipped.join("; ") : ""}`);
  let done = 0;
  const total = byProvider.gemini.length + byProvider.claude.length;
  const runOne = async ({ck, t}) => {
    const r = await callWithRetry(ck, t, schema);
    const row = {cand: ck, task: t.task, id: t.id, meta: t.meta, status: r.status, secs: round1(r.secs),
      firstSecs: round1(r.firstSecs), retried: r.retried, firstError: r.firstError ?? null,
      error: r.error ? mask(r.error).slice(0, 300) : null, finish: r.finish ?? null, usage: r.usage ?? null,
      text: r.text ?? null};
    if (t.task === "T1") row.score = parseScore(r.text);
    if (t.task === "T2") Object.assign(row, evalT2(r.text));
    if (t.task === "T3") Object.assign(row, evalT3(r.text, prompts.t3));
    results.rows = (results.rows ?? []).filter((x) => !(x.cand === ck && x.task === t.task && x.id === t.id));
    results.rows.push(row);
    done++;
    if (done % 10 === 0 || done === total) {
      writeFileSync(join(OUTPUT, "results.json"), JSON.stringify(results, null, 2));
      log(`[run] ${done}/${total}`);
    }
    return row;
  };
  await Promise.all([pool(byProvider.gemini, CONCURRENCY, runOne), pool(byProvider.claude, CONCURRENCY, runOne)]);
  writeFileSync(join(OUTPUT, "results.json"), JSON.stringify(results, null, 2));
  writeReports();
}

function loadResults() {
  const p = join(OUTPUT, "results.json");
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : {rows: []};
}

// ── 집계·판정 ─────────────────────────────────────────────────────
function summarize() {
  const res = loadResults();
  const rows = res.rows ?? [];
  const key = JSON.parse(readFileSync(join(REPO, "tools/eval_harness_selfeval/answer_key/pairs_answer_key.json"), "utf8"));
  const pairIds = key.pairs.map((p) => p.pairId);
  const majority = majorityLabels(loadLabels(), pairIds);
  const august = {};
  for (const p of key.pairs) for (const side of ["left", "right"]) august[`${p.pairId}_${side}`] = [p[side].score];
  const augustAgree = agreementScore(majority, august);

  const cands = [...new Set(rows.map((r) => r.cand))].sort((a, b) => candRank(a) - candRank(b));
  const sum = {};
  for (const c of cands) {
    const r = (task) => rows.filter((x) => x.cand === c && x.task === task);
    const t1 = r("T1");
    const scoresBySide = {};
    for (const x of t1) (scoresBySide[`${x.meta.pairId}_${x.meta.side}`] ??= []).push(x.score);
    const valid = t1.map((x) => x.score).filter((x) => x != null);
    const diffs = Object.values(scoresBySide).filter((v) => v.length === 2 && v.every((x) => x != null)).map(([a, b]) => Math.abs(a - b));
    const t2 = r("T2");
    const t3 = r("T3");
    const t4 = r("T4");
    sum[c] = {
      T1: {n: t1.length, parsed: valid.length, agree: agreementScore(majority, scoresBySide),
        over70: valid.length ? valid.filter((x) => x >= 70).length / valid.length : null,
        meanDiff: mean(diffs), medianSecs: median(t1.map((x) => x.secs)), meanScore: mean(valid),
        failed: t1.filter((x) => x.status !== 200).length, retried: t1.filter((x) => x.retried).length},
      T2: {n: t2.length, jsonValid: t2.filter((x) => x.jsonValid).length, keysOk: t2.filter((x) => x.keysOk).length,
        japanese: t2.filter((x) => x.japanese).length, medianSecs: median(t2.map((x) => x.secs)),
        failed: t2.filter((x) => x.status !== 200).length},
      T3: {n: t3.length, appPass: t3.filter((x) => x.appPass).length, medianSecs: median(t3.map((x) => x.secs)),
        datesCovered: t3.map((x) => x.datesCovered), invalidIds: t3.map((x) => x.invalidIds), consecutiveRepeats: t3.map((x) => x.consecutiveRepeats)},
      T4: {n: t4.length, medianFirst: median(t4.map((x) => x.firstSecs)), medianSecs: median(t4.map((x) => x.secs)),
        failed: t4.filter((x) => x.status !== 200).length},
    };
  }
  // 관문 판정(§3-4, 기준선 = 이번 프로브의 G0). 관문 6은 사용자 판단.
  const gates = {};
  const g0 = sum.G0;
  for (const c of cands) {
    const s = sum[c];
    const g = {};
    g[1] = s.T1.n === 60 && s.T2.n === 20 && s.T3.n === 3 ?
      (s.T1.parsed >= 59 && s.T2.jsonValid === 20 && s.T2.japanese === 0 && s.T3.appPass === 3) : null;
    if (g0 && c !== "G0") {
      g[2] = s.T1.agree.sum >= g0.T1.agree.sum - 1.0;
      g[3] = s.T1.over70 != null && g0.T1.over70 != null ? Math.abs(s.T1.over70 - g0.T1.over70) <= 0.2 : null;
      g[4] = s.T1.meanDiff != null && g0.T1.meanDiff != null ? s.T1.meanDiff <= g0.T1.meanDiff + 3 : null;
      g[5] = s.T1.medianSecs != null && g0.T1.medianSecs != null && s.T4.medianFirst != null && g0.T4.medianFirst != null ?
        (s.T1.medianSecs <= g0.T1.medianSecs * 1.5 && s.T4.medianFirst <= g0.T4.medianFirst + 2) : null;
    }
    gates[c] = g;
  }
  return {res, rows, sum, gates, majority, augustAgree, cands};
}

// ── 보고서 ────────────────────────────────────────────────────────
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (ch) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[ch]));
const pct = (x) => (x == null ? "-" : `${Math.round(x * 1000) / 10}%`);
const yn = (b) => (b == null ? "-" : b ? "통과" : "**미달**");

function writeReports() {
  mkdirSync(OUTPUT, {recursive: true});
  const schemaPath = join(OUTPUT, "schema.json");
  const s = existsSync(schemaPath) ? JSON.parse(readFileSync(schemaPath, "utf8")) : null;
  const {res, rows, sum, gates, majority, augustAgree, cands} = summarize();
  const L = ["# 텍스트 모델 프로브 결과 (task_text_model_v1 §3)", ""];
  L.push("## 스키마 확정 (§3-2)", "");
  if (!s) L.push("(아직 실행 안 함)");
  else {
    L.push(`실행 ${s.at} · ANTHROPIC_API_KEY ${s.claudeAvailable ? "있음" : "**없음 — Claude 생략**"}`, "");
    L.push("| 호출 | HTTP | 초 | 비고 | 오류 |", "|---|---|---|---|---|");
    for (const c of s.calls) {
      const note = Object.entries(c).filter(([k]) => !["name", "status", "secs", "error"].includes(k) && c[k] != null)
        .map(([k, v]) => `${k}=${typeof v === "object" ? JSON.stringify(v) : v}`).join(" · ");
      L.push(`| ${c.name} | ${c.status} | ${c.secs ?? "-"} | ${note.replace(/\|/g, "\\|")} | ${String(c.error ?? "").replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 200)} |`);
    }
    L.push("", "Gemini:");
    for (const [m, g] of Object.entries(s.gemini ?? {})) {
      L.push(`- \`${m}\`: models.get ${g.modelsGet?.status}${g.appConfigOk != null ? ` · 앱 T2 설정(thinkingBudget 0·JSON·temperature) ${g.appConfigOk ? "그대로 통과" : "거부"}` : ""}${g.thinkingReplacement ? ` · 대체 ${JSON.stringify(g.thinkingReplacement)}` : ""}`);
    }
    if (s.claude?.config) {
      L.push("", `Claude(\`${s.claude.model}\`): 버전 헤더 \`${s.claude.version}\` · 확정 설정 **${s.claude.config.label}** · max_tokens ${JSON.stringify(s.claude.config.maxTokens)}`);
    } else if (s.claude) L.push("", "Claude: **스키마 확정 실패 — 멈춤**");
  }

  L.push("", "## 과제별 결과 (§3-3)", "");
  if (res.skipped?.length) L.push(`건너뛴 후보: ${res.skipped.join("; ")}`, "");
  if (cands.length) {
    L.push("| 후보 | 모델 | T1 파싱 | T1 사람 일치 | T1 70+ 비율 | T1 2회 차 평균 | T1 소요 중앙값(초) | T2 JSON 유효 | T2 필수 키 | T2 가나·한자 | T3 앱 검증 | T4 첫 글자 중앙값(초) | T4 전체 중앙값(초) |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|---|");
    for (const c of cands) {
      const x = sum[c];
      L.push(`| ${c} | \`${candLabel(c)}\` | ${x.T1.parsed}/${x.T1.n} | ${x.T1.agree.sum}/${x.T1.agree.n} | ${pct(x.T1.over70)} | ${round1(x.T1.meanDiff) ?? "-"} | ${round1(x.T1.medianSecs) ?? "-"} | ${x.T2.jsonValid}/${x.T2.n} | ${x.T2.keysOk}/${x.T2.n} | ${x.T2.japanese} | ${x.T3.appPass}/${x.T3.n} | ${round1(x.T4.medianFirst) ?? "-"} | ${round1(x.T4.medianSecs) ?? "-"} |`);
    }
    L.push("", `사람 다수결 대상 쌍 ${Object.keys(majority).length}개(다수 없음 제외, 주의 확인 쌍 포함 — task_selfeval_validity_v1 §9 정의). 참고: 정답지에 저장된 **8월 점수로 계산한 일치 ${augustAgree.sum}/${augustAgree.n}**.`);
    L.push("", "T3 참고 지표(회차별): " + cands.map((c) => `${c} 날짜 ${JSON.stringify(sum[c].T3.datesCovered)}/7 · 없는 id ${JSON.stringify(sum[c].T3.invalidIds)} · 상·하의 연속 ${JSON.stringify(sum[c].T3.consecutiveRepeats)}`).join(" / "));
    L.push("", "실패·재시도: " + cands.map((c) => `${c} T1 실패 ${sum[c].T1.failed}·재시도 ${sum[c].T1.retried}, T2 실패 ${sum[c].T2.failed}, T4 실패 ${sum[c].T4.failed}`).join(" / "));

    L.push("", "## 관문별 판정 초안 (§3-4, 기준선 = 이번 G0)", "",
      "| 후보 | 1 형식 | 2 타당성 | 3 통과 기준 적합 | 4 재현성 | 5 속도 | 6 본문 품질 |", "|---|---|---|---|---|---|---|");
    for (const c of cands) {
      const g = gates[c];
      L.push(`| ${c} | ${yn(g[1])} | ${c === "G0" ? "기준" : yn(g[2])} | ${c === "G0" ? "기준" : g[3] === false ? "**통과 기준 재조정 필요**" : yn(g[3])} | ${c === "G0" ? "기준" : yn(g[4])} | ${c === "G0" ? "기준" : yn(g[5])} | 사용자 판단 |`);
    }
  }
  L.push("", "시간은 호출 왕복 시간(재시도한 호출은 두 번째 호출의 시간). 시한 90초/호출, 제공자별 동시 3건.");
  writeFileSync(join(OUTPUT, "results.md"), L.join("\n") + "\n");
  writeHtml(rows, sum, cands, majority);
}

function writeHtml(rows, sum, cands, majority) {
  const hist = (c) => {
    const scores = rows.filter((x) => x.cand === c && x.task === "T1" && x.score != null).map((x) => x.score);
    const bins = Array.from({length: 10}, (_, i) => scores.filter((s) => s > i * 10 && s <= (i + 1) * 10).length);
    const max = Math.max(1, ...bins);
    return `<div class="hist">${bins.map((b, i) => `<div class="bar" title="${i * 10 + 1}~${(i + 1) * 10}: ${b}"><span style="height:${(b / max) * 100}%"></span><em>${(i + 1) * 10}</em></div>`).join("")}</div>`;
  };
  const textCell = (r) => (r ? `<pre>${esc(r.text ?? r.error ?? "")}</pre><div class="meta">${r.secs ?? "-"}초${r.firstSecs != null ? ` · 첫 글자 ${r.firstSecs}초` : ""}${r.score != null ? ` · 총점 ${r.score}` : ""}</div>` : "<em>없음</em>");
  let body = "<h2>과제별 요약</h2><table><tr><th>후보</th><th>T1 파싱</th><th>사람 일치</th><th>70+ 비율</th><th>2회 차</th><th>T1 중앙값</th><th>T2 JSON</th><th>T2 가나·한자</th><th>T3</th><th>T4 첫 글자</th></tr>";
  for (const c of cands) {
    const x = sum[c];
    body += `<tr><td>${c} <small>${esc(candLabel(c))}</small></td><td>${x.T1.parsed}/${x.T1.n}</td><td>${x.T1.agree.sum}/${x.T1.agree.n}</td><td>${pct(x.T1.over70)}</td><td>${round1(x.T1.meanDiff) ?? "-"}</td><td>${round1(x.T1.medianSecs) ?? "-"}초</td><td>${x.T2.jsonValid}/${x.T2.n}</td><td>${x.T2.japanese}</td><td>${x.T3.appPass}/${x.T3.n}</td><td>${round1(x.T4.medianFirst) ?? "-"}초</td></tr>`;
  }
  body += "</table><h2>T1 점수 분포(1~100, 10점 구간)</h2><div class=\"hists\">" +
    cands.map((c) => `<div><h3>${c}</h3>${hist(c)}</div>`).join("") + "</div>";
  body += "<h2>T4 스트리밍 분석 본문(전신 사진 + 조합)</h2>";
  for (const id of ["c1", "c2", "c3"]) {
    const any = rows.find((x) => x.task === "T4" && x.id === id);
    body += `<h3>${id}${any ? ` — ${esc((any.meta.slots ?? []).join(" · "))}` : ""}</h3><div class="cols">` +
      cands.map((c) => `<div><h4>${c}</h4>${textCell(rows.find((x) => x.cand === c && x.task === "T4" && x.id === id))}</div>`).join("") + "</div>";
  }
  body += "<h2>T1 본문 일부(쌍 3개, 1회차)</h2>";
  for (const pid of T1_SHOWCASE_PAIRS) {
    const m = majority[pid];
    for (const side of ["left", "right"]) {
      body += `<h3>${pid} ${side}${m ? ` <small>(사람 다수결: ${m.choice})</small>` : ""}</h3><div class="cols">` +
        cands.map((c) => `<div><h4>${c}</h4>${textCell(rows.find((x) => x.cand === c && x.task === "T1" && x.id === `${pid}_${side}_r1`))}</div>`).join("") + "</div>";
    }
  }
  const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>텍스트 모델 비교</title><style>
:root{--bg:#fff;--fg:#1a1a1a;--mute:#666;--line:#ddd;--bar:#4a6fa5}
@media (prefers-color-scheme:dark){:root{--bg:#161616;--fg:#eee;--mute:#999;--line:#333;--bar:#7aa2d6}}
body{background:var(--bg);color:var(--fg);font:14px/1.6 system-ui,sans-serif;margin:16px;max-width:1600px}
table{border-collapse:collapse}th,td{border:1px solid var(--line);padding:4px 8px;text-align:left}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px}
pre{white-space:pre-wrap;word-break:break-word;border:1px solid var(--line);padding:8px;max-height:520px;overflow:auto;font:13px/1.6 system-ui,sans-serif}
.meta,small{color:var(--mute);font-size:12px}.hists{display:flex;gap:24px;flex-wrap:wrap}
.hist{display:flex;align-items:flex-end;gap:2px;height:120px}.bar{width:22px;height:100%;display:flex;flex-direction:column;justify-content:flex-end;align-items:center}
.bar span{display:block;width:100%;background:var(--bar)}.bar em{font-size:10px;color:var(--mute);font-style:normal}
</style></head><body><h1>텍스트 모델 비교 (task_text_model_v1 §3)</h1>
<p>같은 프롬프트(앱 빌더 출력)를 후보마다 보냈다. 관문 6(본문 품질)은 아래 본문을 읽고 판단한다. 표의 숫자는 results.md와 같다.</p>
${body}</body></html>`;
  writeFileSync(join(OUTPUT, "index.html"), html);
}

// ── fixtures: 서버 어댑터(functions/src/claude_adapter.ts) 대조용 ─────────
// docs/task_text_model_v1.md "2단계 결정" 보충 a). 프로브가 C에 보낸 요청을
// 같은 함수(claudeBody)로 다시 만들어, 앱의 Gemini 형식 요청과 짝지어 남긴다.
// effort는 프로브가 실제로 잰 설정 — T2·T3은 C(low), T1·T4는 C@medium.
// 이미지 base64는 앞 64자만 남긴다(양쪽에 같은 변환 — 구조 대조에는 충분).
// 응답 픽스처는 results.json에 남은 C의 실제 본문·토큰·stop_reason으로
// Messages API 응답 모양을 다시 만든 것이다(원본 JSON은 저장하지 않았다).
function runFixtures() {
  const schema = JSON.parse(readFileSync(join(OUTPUT, "schema.json"), "utf8"));
  const cfg = {...schema.claude.config};
  const model = CANDIDATES.C.model;
  const trim = (t) => ({...t, parts: t.parts.map((p) => (p.inlineData ?
    {inlineData: {mimeType: p.inlineData.mimeType, data: p.inlineData.data.slice(0, 64)}} : p))});
  const tasks = buildTasks(loadPrompts());
  const pickTask = (name) => trim(tasks.find((t) => t.task === name));
  const effortOf = {T1: "medium", T2: "low", T3: "low", T4: "medium"};
  const requests = ["T1", "T2", "T3", "T4"].map((name) => {
    const t = pickTask(name);
    return {task: name, effort: effortOf[name], stream: !!t.stream,
      geminiRequest: {contents: [{parts: t.parts}], generationConfig: t.generationConfig},
      claudeRequest: claudeBody(model, t, {...cfg, effort: effortOf[name]})};
  });
  const rows = loadResults().rows ?? [];
  const row = (cand, task) => rows.find((x) => x.cand === cand && x.task === task && x.status === 200 && x.text);
  const asMessage = (r) => ({id: "msg_fixture", type: "message", role: "assistant", model,
    content: [{type: "text", text: r.text}], stop_reason: r.finish ?? "end_turn", usage: r.usage ?? {}});
  const responses = {T1: asMessage(row("C@medium", "T1") ?? row("C", "T1")), T2: asMessage(row("C", "T2")), T3: asMessage(row("C", "T3"))};
  const t4 = row("C@medium", "T4") ?? row("C", "T4");
  const pieces = t4.text.match(/[\s\S]{1,40}/g) ?? [];
  const streamEvents = [
    {type: "message_start", message: {id: "msg_fixture", type: "message", role: "assistant", model, content: [], usage: {input_tokens: t4.usage?.input_tokens ?? 0}}},
    {type: "content_block_start", index: 0, content_block: {type: "text", text: ""}},
    {type: "ping"},
    ...pieces.map((text) => ({type: "content_block_delta", index: 0, delta: {type: "text_delta", text}})),
    {type: "content_block_stop", index: 0},
    {type: "message_delta", delta: {stop_reason: t4.finish ?? "end_turn"}, usage: {output_tokens: t4.usage?.output_tokens ?? 0}},
    {type: "message_stop"},
  ];
  const out = {source: "tools/text_probe/probe.mjs fixtures", model, version: schema.claude.version, requests,
    responses, stream: {text: t4.text, events: streamEvents}};
  writeFileSync(join(OUTPUT, "claude_fixtures.json"), JSON.stringify(out, null, 2));
  log(`→ ${join(OUTPUT, "claude_fixtures.json")}`);
}

// ── main ──────────────────────────────────────────────────────────
const [cmd = "", ...args] = process.argv.slice(2);
if (cmd === "fixtures") { runFixtures(); process.exit(0); }
if (cmd === "report") { writeReports(); log(`→ ${join(OUTPUT, "results.md")}\n→ ${join(OUTPUT, "index.html")}`); process.exit(0); }
if (!["schema", "run"].includes(cmd)) {
  console.error("사용법: node probe.mjs schema | run [--candidates G0,G1,C] [--tasks T1,T2,T3,T4] | report");
  process.exit(2);
}
if (!GEMINI_KEY) { console.error("GEMINI_API_KEY 환경변수가 없습니다."); process.exit(2); }
if (cmd === "schema") await runSchema();
if (cmd === "run") await runMeasure(args);
log(`→ ${join(OUTPUT, "results.md")}\n→ ${join(OUTPUT, "index.html")}`);
