// 가상 피팅 프로브 — docs/task_fitting_quality_v2.md §3.
//
// 앱 빌드·함수 배포 없이 이미지 모델·호출 방식·프롬프트를 로컬에서 비교한다.
// Node 22+ 내장 fetch만 쓴다(외부 의존성 없음). API 키는 GEMINI_API_KEY
// 환경변수로만 받고, URL이 아니라 x-goog-api-key 헤더로 보낸다 — 로그에
// 찍히는 URL에는 애초에 키가 없고, 혹시 응답 본문 등에 섞여 나와도
// mask()가 가린다.
//
//   node probe.mjs schema            # §3-2 스키마 확정 호출만
//   node probe.mjs matrix            # §3-3 매트릭스(schema.json 필요)
//   node probe.mjs matrix --variants A,B --cases K1,K4   # 부분 재실행(결과 병합)
//   node probe.mjs repeat B:K7:3 B2:K7:3   # 지정 칸만 반복(회차별 파일, 기존 결과 보존)
//   node probe.mjs html              # results.json → index.html 재생성
//   node probe.mjs all               # schema → matrix → html (기본값)

import {readFileSync, writeFileSync, existsSync, mkdirSync} from "node:fs";
import {join, dirname} from "node:path";
import {fileURLToPath} from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const INPUT = join(HERE, "input");
const OUTPUT = join(HERE, "output");
const STEPS = join(OUTPUT, "steps");
const BASE_URL = "https://generativelanguage.googleapis.com/v1beta";

const OLD_MODEL = "gemini-3.1-flash-image";
const NEW_MODEL = "gemini-nano-banana-2.1";
const CALL_TIMEOUT_MS = 180_000; // §3-1 — 구 모델 5분 매달림 전례(논문 5.19.2)
const GAP_MS = 2_000; // §3-3 호출 사이 간격

// 슬롯 → 앱의 최상위 category(A의 현행 프롬프트에 그대로 들어가는 이름)와
// 신규 프롬프트 라벨. 순서는 앱의 fittingOrder(상의→하의→아우터→신발→
// 액세서리) + 액세서리 동률은 main.dart 슬롯 맵 선언 순서(모자→가방→시계).
const SLOTS = {
  top: {category: "상의", label: "상의 / top"},
  bottom: {category: "하의", label: "하의 / bottom"},
  outer: {category: "아우터", label: "아우터 / outerwear"},
  shoes: {category: "신발", label: "신발 / shoes"},
  hat: {category: "액세서리", label: "모자 / hat, worn on the head"},
  bag: {category: "액세서리", label: "가방 / bag"},
  watch: {category: "액세서리", label: "시계 / watch, worn on the wrist"},
};
const CORE = ["top", "bottom", "outer", "shoes"];
const CASES = {
  K1: ["top"],
  K4: ["top", "bottom", "outer", "shoes"],
  K5: ["top", "bottom", "outer", "shoes", "hat"],
  K7: ["top", "bottom", "outer", "shoes", "hat", "bag", "watch"],
};
const VARIANTS = {
  A: {model: OLD_MODEL, mode: "sequential", prompt: "legacy", thinking: null},
  B: {model: NEW_MODEL, mode: "oneshot", prompt: "new", thinking: "minimal"},
  C: {model: NEW_MODEL, mode: "oneshot", prompt: "new", thinking: "medium"},
  D: {model: NEW_MODEL, mode: "sequential", prompt: "new", thinking: "minimal"},
  E: {model: NEW_MODEL, mode: "core+acc", prompt: "new", thinking: "minimal", cases: ["K5", "K7"]},
  // 재현성 확인용(실행 기록 "재현성 확인 계획") — B와 전부 같고 Rules 마지막
  // 줄만 다르다. matrix 기본 순회에는 넣지 않는다(repeat 또는 --variants로만).
  B2: {model: NEW_MODEL, mode: "oneshot", prompt: "new", thinking: "minimal", lastRule: "b2", repeatOnly: true},
};

// 세 변형에서 공통으로 쓰는 크롭 박스(정규화 좌표, 원본 프레임 기준).
// 초깃값은 v1 1회분 크롭(머리~어깨 x=[0.28,0.64] y=[0,0.20], 모자
// x=[0.30,0.62] y=[0,0.118])이다 — 전신 사진 구도가 다르면 여기만 고치고
// `node probe.mjs html`로 다시 만든다. 페이지에 좌표·배율이 그대로 찍힌다.
const CROPS = {
  face: {name: "얼굴~어깨", x0: 0.28, x1: 0.64, y0: 0.0, y1: 0.2},
  hat: {name: "모자", x0: 0.3, x1: 0.62, y0: 0.0, y1: 0.118},
  // 반복 실행 섹션 전용 — "넣지 않은 아이템 추가"(손목·가방 부위)를 보기 위한 몸통 크롭.
  torso: {name: "몸통·손목", x0: 0.18, x1: 0.78, y0: 0.22, y1: 0.62},
};

const API_KEY = process.env.GEMINI_API_KEY ?? "";
const mask = (s) => (API_KEY ? String(s).split(API_KEY).join("***") : String(s));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(mask(a.join(" ")));

// ── 이미지 헤더 파싱(라이브러리 없이) ──────────────────────────────
function sniffMime(buf) {
  if (buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return "image/png";
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "image/jpeg";
  if (buf.length > 12 && buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  return "unknown";
}

function imageSize(buf) {
  const mime = sniffMime(buf);
  if (mime === "image/png") return {w: buf.readUInt32BE(16), h: buf.readUInt32BE(20)};
  if (mime === "image/jpeg") {
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) { i++; continue; }
      const marker = buf[i + 1];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
      const len = buf.readUInt16BE(i + 2);
      const isSof = marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
      if (isSof) return {w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5)};
      i += 2 + len;
    }
  }
  if (mime === "image/webp") {
    const chunk = buf.toString("ascii", 12, 16);
    if (chunk === "VP8X") return {w: 1 + buf.readUIntLE(24, 3), h: 1 + buf.readUIntLE(27, 3)};
    if (chunk === "VP8 ") return {w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff};
    if (chunk === "VP8L") {
      const b = buf.readUInt32LE(21);
      return {w: (b & 0x3fff) + 1, h: ((b >> 14) & 0x3fff) + 1};
    }
  }
  return null;
}

const extFor = (mime) => ({"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}[mime] ?? "bin");
const sizeText = (d) => (d ? `${d.w}×${d.h}` : "?");

// ── 입력 ──────────────────────────────────────────────────────────
const INPUT_FILES = ["person", ...Object.keys(SLOTS)];

function loadInputs() {
  const missing = INPUT_FILES.filter((n) => !existsSync(join(INPUT, `${n}.jpg`)));
  const labelsPath = join(INPUT, "labels.json");
  if (missing.length || !existsSync(labelsPath)) {
    console.error(
      [
        "입력이 부족합니다. tools/fitting_probe/input/ 에 아래를 넣으세요:",
        ...INPUT_FILES.map((n) => `  ${n}.jpg${missing.includes(n) ? "   ← 없음" : ""}`),
        `  labels.json${existsSync(labelsPath) ? "" : "   ← 없음"}  예: {"top": "색상 네이비, 패턴 스트라이프, 핏 레귤러", ...}`,
        "",
        "v1 set4_7벌 원본을 받으려면: fetch_inputs.py (README 참고, Firestore·Storage 읽기 전용).",
        "원본이어야 한다 — 썸네일·배경 제거본(cutout) 금지.",
      ].join("\n"),
    );
    process.exit(2);
  }
  const labels = JSON.parse(readFileSync(labelsPath, "utf8"));
  const lack = Object.keys(SLOTS).filter((k) => typeof labels[k] !== "string" || !labels[k].trim());
  if (lack.length) {
    console.error(`labels.json에 설명이 없는 슬롯: ${lack.join(", ")}`);
    process.exit(2);
  }
  const files = {};
  for (const n of INPUT_FILES) {
    const buf = readFileSync(join(INPUT, `${n}.jpg`));
    files[n] = {buf, mime: sniffMime(buf), dims: imageSize(buf), bytes: buf.length};
  }
  return {files, labels};
}

// ── 프롬프트 ──────────────────────────────────────────────────────
// lib/services/gemini_service.dart _buildFittingPrompt 원문 그대로(Dart '''
// 문자열은 여는 따옴표 뒤 첫 줄바꿈을 버리고, 끝은 줄바꿈 하나로 끝난다).
function legacyPrompt(categories) {
  const clothingList = categories.map((n) => `- ${n}`).join("\n");
  return `첫 번째 사진의 사람에게 이후 사진에 있는 옷을 입혀서 자연스러운 합성 이미지를 만들어주세요.

착용할 옷:
${clothingList}

생성 규칙:
- 첫 번째 사진 속 사람의 얼굴, 체형, 피부톤, 헤어스타일을 그대로 유지해주세요
- 제공된 옷 이미지의 옷을 그 사람에게 자연스럽게 입혀주세요
- 전신이 보이도록 해주세요
- 자연스러운 포즈와 배경을 유지해주세요
- 실제로 그 옷을 입은 것처럼 사실적으로 표현해주세요
`;
}

// B의 Rules는 NEW_RULES_HEAD + LAST_RULE.b 로 조립해도 이전과 글자 하나 다르지
// 않다(줄바꿈 하나로 이어 붙임). B2는 마지막 줄만 LAST_RULE.b2로 바꾼다.
const NEW_RULES_HEAD = `Rules:
- Keep the person's face, hair, skin tone, body shape, pose, camera framing and background exactly as in IMAGE 1.
- Replace only the clothing in each item's category. Leave everything else the person wears unchanged.
- Reproduce each item exactly: same color, pattern, print/logo, fabric texture, length and silhouette. Never redraw, restyle or invent a logo or detail.
- Use only the item itself from each item image — ignore its background, hanger, mannequin or any other person.
- Items must sit naturally on the body: a hat fits snugly on the head with hair visible below it, a bag is held or worn on the shoulder, a watch is on the wrist. Realistic drape, contact shadows and lighting consistent with IMAGE 1.`;
const LAST_RULE = {
  b: "- Every listed item must be worn. Show the full body. Output exactly one photorealistic image with no added text or extra items.",
  b2: "- Every listed item must be worn. Do not add any item that is not in the list above — no extra jewelry, glasses or accessories. Show the full body. Output exactly one photorealistic image with no added text.",
};
const newRules = (lastRule = "b") => `${NEW_RULES_HEAD}\n${LAST_RULE[lastRule]}`;

const inline = (buf, mime) => ({inlineData: {mimeType: mime, data: buf.toString("base64")}});

// A: 앱 현행 요청 재현 — [프롬프트, 현재 이미지, 옷 이미지], mimeType은 jpeg 고정.
function legacyParts(baseBuf, slot, files) {
  return [
    {text: legacyPrompt([SLOTS[slot].category])},
    inline(baseBuf, "image/jpeg"),
    inline(files[slot].buf, "image/jpeg"),
  ];
}

// 신규(§3-4): 텍스트 라벨을 각 이미지 바로 앞에 끼운다. mimeType은 매직 넘버로.
function newParts(baseBuf, slots, files, labels, lastRule = "b") {
  const parts = [
    {text: "You are a virtual try-on engine. Edit IMAGE 1 so the person wears the items shown in the following images."},
    {text: "IMAGE 1 — the PERSON. This is the base image to edit."},
    inline(baseBuf, sniffMime(baseBuf)),
  ];
  slots.forEach((slot, i) => {
    parts.push({text: `IMAGE ${i + 2} — ITEM (${SLOTS[slot].label}): ${labels[slot]}`});
    parts.push(inline(files[slot].buf, files[slot].mime));
  });
  parts.push({text: newRules(lastRule)});
  return parts;
}

// ── 호출 ──────────────────────────────────────────────────────────
function setPath(obj, path, value) {
  const keys = path.split(".");
  let o = obj;
  keys.slice(0, -1).forEach((k) => (o = o[k] ??= {}));
  o[keys.at(-1)] = value;
}

async function rawCall(model, body) {
  const url = `${BASE_URL}/models/${model}:generateContent`;
  const payload = JSON.stringify(body);
  const t0 = performance.now();
  let status = 0;
  let json = null;
  let error = null;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {"content-type": "application/json", "x-goog-api-key": API_KEY},
      body: payload,
      signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
    });
    status = res.status;
    const text = await res.text();
    try { json = JSON.parse(text); } catch { error = `non-JSON 응답: ${text.slice(0, 200)}`; }
    if (!res.ok) error = json?.error?.message ?? error ?? `HTTP ${status}`;
  } catch (e) {
    error = e?.name === "TimeoutError" ? `시한 초과(${CALL_TIMEOUT_MS / 1000}초)` : `${e?.name}: ${e?.message}`;
  }
  const secs = (performance.now() - t0) / 1000;
  let image = null;
  let textOut = "";
  if (!error && json) {
    const parts = json.candidates?.[0]?.content?.parts ?? [];
    for (const p of parts) {
      const d = p.inlineData ?? p.inline_data;
      if (d?.data && !p.thought) image = {buf: Buffer.from(d.data, "base64"), declaredMime: d.mimeType ?? d.mime_type};
      if (p.text && !p.thought) textOut += p.text;
    }
    if (!image) {
      error = `이미지 없음 finishReason=${json.candidates?.[0]?.finishReason ?? "?"} ` +
        `blockReason=${json.promptFeedback?.blockReason ?? "-"} text=${textOut.slice(0, 120)}`;
    }
  }
  log(`  POST ${url} → ${status || "ERR"} ${secs.toFixed(1)}s req=${payload.length}B${error ? " · " + error.slice(0, 160) : ""}`);
  return {
    status, secs, error: error ? mask(error).slice(0, 400) : null, image, requestBytes: payload.length,
    usage: json?.usageMetadata ?? null,
  };
}

const retryable = (r) => !r.status || r.status === 429 || r.status >= 500 || (r.status === 200 && !r.image);

// §3-3: 실패한 호출은 1회만 재시도. schema 단계는 4xx(필드 거부)를 재시도하지
// 않는다 — 그 응답 자체가 확정하려는 정보다.
async function call(model, body, {retryOn4xx = true} = {}) {
  const first = await rawCall(model, body);
  if (!first.error) return {...first, retried: false, attempts: [first]};
  if (!retryOn4xx && !retryable(first)) return {...first, retried: false, attempts: [first]};
  await sleep(GAP_MS);
  const second = await rawCall(model, body);
  return {...second, secs: first.secs + second.secs, retried: true, attempts: [first, second]};
}

// ── §3-2 스키마 확정 ───────────────────────────────────────────────
async function getModel(model) {
  try {
    const res = await fetch(`${BASE_URL}/models/${model}`, {headers: {"x-goog-api-key": API_KEY}, signal: AbortSignal.timeout(30_000)});
    const json = await res.json().catch(() => null);
    return {status: res.status, methods: json?.supportedGenerationMethods ?? null, error: res.ok ? null : mask(json?.error?.message ?? "")};
  } catch (e) {
    return {status: 0, methods: null, error: `${e?.name}: ${e?.message}`};
  }
}

async function runSchema() {
  const {files, labels} = loadInputs();
  const parts = newParts(files.person.buf, ["top"], files, labels);
  const log2 = [];
  const record = (name, gc, r) => {
    log2.push({name, generationConfig: gc, status: r.status, secs: +r.secs.toFixed(1), error: r.error,
      mime: r.image ? sniffMime(r.image.buf) : null, declaredMime: r.image?.declaredMime ?? null,
      dims: r.image ? imageSize(r.image.buf) : null, bytes: r.image?.buf.length ?? null,
      thoughtsTokens: r.usage?.thoughtsTokenCount ?? null});
    if (r.image) writeFileSync(join(STEPS, `schema_${name}.${extFor(sniffMime(r.image.buf))}`), r.image.buf);
  };
  const tryGc = async (name, gc) => {
    log(`[schema] ${name} ${JSON.stringify(gc)}`);
    const r = await call(NEW_MODEL, {contents: [{parts}], generationConfig: gc}, {retryOn4xx: false});
    record(name, gc, r);
    await sleep(GAP_MS);
    return r;
  };

  const models = {[NEW_MODEL]: await getModel(NEW_MODEL), [OLD_MODEL]: await getModel(OLD_MODEL)};
  log(`[schema] models.get ${JSON.stringify(models)}`);

  const s = {models, endpointOk: false, modalities: null, imageOnlyOk: null, thinkingField: null, minimalOk: null,
    sizeField: null, aspectField: null, responseMime: null, responseDeclaredMime: null, responseDims: null, calls: log2};

  // 1·4: 엔드포인트 + IMAGE 단독 허용 여부
  let r = await tryGc("modalities_IMAGE", {responseModalities: ["IMAGE"]});
  if (!r.error) { s.endpointOk = true; s.imageOnlyOk = true; s.modalities = ["IMAGE"]; }
  else {
    s.imageOnlyOk = false;
    r = await tryGc("modalities_IMAGE_TEXT", {responseModalities: ["IMAGE", "TEXT"]});
    if (!r.error) { s.endpointOk = true; s.modalities = ["IMAGE", "TEXT"]; }
  }
  if (!s.endpointOk) {
    // Interactions API 존재 여부만 기록(본문 스키마는 모른다 — 상태 코드만 본다).
    try {
      const res = await fetch(`${BASE_URL}/interactions`, {method: "POST",
        headers: {"content-type": "application/json", "x-goog-api-key": API_KEY},
        body: JSON.stringify({model: NEW_MODEL, input: "ping"}), signal: AbortSignal.timeout(60_000)});
      const t = await res.text();
      s.interactionsProbe = {status: res.status, body: mask(t.slice(0, 300))};
    } catch (e) { s.interactionsProbe = {status: 0, body: `${e?.name}: ${e?.message}`}; }
    return finishSchema(s);
  }
  s.responseMime = log2.at(-1).mime;
  s.responseDeclaredMime = log2.at(-1).declaredMime;
  s.responseDims = log2.at(-1).dims;
  const base = {responseModalities: s.modalities};

  // 3: thinking 필드
  for (const [field, value] of [["thinkingConfig.thinkingLevel", "minimal"], ["thinkingConfig.thinkingLevel", "MINIMAL"]]) {
    const gc = structuredClone(base); setPath(gc, field, value);
    r = await tryGc(`thinking_${value}`, gc);
    if (!r.error) { s.thinkingField = field; s.minimalOk = true; s.minimalValue = value; break; }
  }
  if (!s.thinkingField) s.minimalOk = false;

  // 2: 크기·비율 필드
  for (const field of ["imageConfig.imageSize", "responseFormat.image.imageSize"]) {
    const gc = structuredClone(base); setPath(gc, field, "1K");
    r = await tryGc(`size_${field}`, gc);
    if (!r.error) { s.sizeField = field; break; }
  }
  if (s.sizeField) {
    const aspect = s.sizeField.replace(/imageSize$/, "aspectRatio");
    const gc = structuredClone(base); setPath(gc, s.sizeField, "1K"); setPath(gc, aspect, "3:4");
    r = await tryGc(`aspect_${aspect}`, gc);
    if (!r.error) s.aspectField = aspect;
  }
  return finishSchema(s);
}

function finishSchema(s) {
  writeFileSync(join(OUTPUT, "schema.json"), JSON.stringify(s, null, 2));
  writeResultsMd();
  log(`[schema] endpointOk=${s.endpointOk} modalities=${JSON.stringify(s.modalities)} thinking=${s.thinkingField} ` +
    `minimal=${s.minimalOk} size=${s.sizeField} aspect=${s.aspectField} mime=${s.responseMime} dims=${sizeText(s.responseDims)}`);
  return s;
}

// ── §3-3 매트릭스 ─────────────────────────────────────────────────
function genConfig(v, schema) {
  if (v.model === OLD_MODEL) return {responseModalities: ["IMAGE", "TEXT"]}; // 현행 그대로
  const gc = {responseModalities: schema.modalities};
  setPath(gc, schema.thinkingField, schema.minimalValue === "MINIMAL" ? v.thinking.toUpperCase() : v.thinking);
  if (schema.sizeField) setPath(gc, schema.sizeField, "1K");
  return gc;
}

// 한 번의 "케이스 실행" = 앱에서 피팅 버튼 한 번. 단계 목록을 받아 앞 단계
// 출력을 다음 단계 베이스로 넘긴다. 앱과 같은 부분 성공 규칙: 첫 단계 실패는
// 전체 실패, 이후 실패는 그때까지의 결과 + 누락 카테고리.
async function runCase(vKey, kKey, files, labels, schema, {outName = `${vKey}_${kKey}`, saveSteps = true} = {}) {
  const v = VARIANTS[vKey];
  const slots = CASES[kKey];
  const stages = v.mode === "sequential" ? slots.map((s) => [s])
    : v.mode === "oneshot" ? [slots]
    : [slots.filter((s) => CORE.includes(s)), slots.filter((s) => !CORE.includes(s))];
  const gc = genConfig(v, schema);
  const startedAt = new Date().toISOString();
  let current = files.person.buf;
  const steps = [];
  const missing = [];
  for (let i = 0; i < stages.length; i++) {
    const parts = v.prompt === "legacy" ? legacyParts(current, stages[i][0], files) : newParts(current, stages[i], files, labels, v.lastRule);
    log(`[${vKey}/${kKey}] 단계 ${i + 1}/${stages.length} ${stages[i].join("+")}`);
    const r = await call(v.model, {contents: [{parts}], generationConfig: gc});
    steps.push({slots: stages[i], status: r.status, secs: +r.secs.toFixed(1), retried: r.retried, error: r.error,
      requestBytes: r.requestBytes, thoughtsTokens: r.usage?.thoughtsTokenCount ?? null,
      attemptStatuses: r.attempts.map((a) => a.status)});
    if (r.error) {
      missing.push(...stages.slice(i).flat());
      break;
    }
    current = r.image.buf;
    if (saveSteps && stages.length > 1) writeFileSync(join(STEPS, `${vKey}_${kKey}_s${i + 1}.${extFor(sniffMime(current))}`), current);
    if (i < stages.length - 1) await sleep(GAP_MS);
  }
  const ok = steps.length > 0 && !steps[0].error;
  let out = null;
  if (ok) {
    const mime = sniffMime(current);
    out = {file: `${outName}.${extFor(mime)}`, mime, dims: imageSize(current), bytes: current.length};
    writeFileSync(join(OUTPUT, out.file), current);
  }
  return {variant: vKey, case: kKey, model: v.model, mode: v.mode, thinking: v.thinking, generationConfig: gc,
    calls: steps.reduce((n, s) => n + s.attemptStatuses.length, 0), plannedCalls: stages.length,
    totalSecs: +steps.reduce((t, s) => t + s.secs, 0).toFixed(1), steps, missing, ok, out,
    startedAt};
}

function loadResults() {
  const p = join(OUTPUT, "results.json");
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : {runs: []};
}

async function runMatrix(args) {
  const schemaPath = join(OUTPUT, "schema.json");
  if (!existsSync(schemaPath)) { console.error("schema.json이 없습니다 — 먼저 `node probe.mjs schema`."); process.exit(2); }
  const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
  if (!schema.endpointOk) { console.error("generateContent가 새 모델에서 동작하지 않음 — §3-2 규칙대로 중단."); process.exit(3); }
  if (!schema.thinkingField) { console.error("thinking 필드가 확정되지 않음 — B/C/D/E 구성 불가, 중단."); process.exit(3); }
  const {files, labels} = loadInputs();
  const pick = (flag, all) => {
    const i = args.indexOf(flag);
    return i >= 0 ? args[i + 1].split(",") : all;
  };
  const vKeys = pick("--variants", Object.keys(VARIANTS).filter((k) => !VARIANTS[k].repeatOnly));
  const kKeys = pick("--cases", Object.keys(CASES));
  const results = loadResults();
  results.inputs = Object.fromEntries(INPUT_FILES.map((n) => [n, {mime: files[n].mime, dims: files[n].dims, bytes: files[n].bytes}]));
  results.labels = labels;
  let first = true;
  // 케이스 우선 순회(K1의 A~E → K4의 A~E …) — 같은 케이스의 변형들이 시간상
  // 붙어 있어 업스트림 상태 변동이 변형 간 비교에 덜 섞인다. 실행 순서는
  // results.json의 order에 남는다.
  for (const k of kKeys) {
    for (const vk of vKeys) {
      if (VARIANTS[vk].cases && !VARIANTS[vk].cases.includes(k)) continue;
      if (!first) await sleep(GAP_MS);
      first = false;
      const run = await runCase(vk, k, files, labels, schema);
      results.runs = results.runs.filter((x) => !(x.variant === vk && x.case === k));
      run.order = (results.orderCounter = (results.orderCounter ?? 0) + 1);
      results.runs.push(run);
      writeFileSync(join(OUTPUT, "results.json"), JSON.stringify(results, null, 2));
      writeResultsMd();
      writeHtml();
      log(`[${vk}/${k}] 완료 ok=${run.ok} 총 ${run.totalSecs}s 호출 ${run.calls}${run.missing.length ? " 누락=" + run.missing.join(",") : ""}`);
    }
  }
}

// ── repeat: 지정 칸만 반복 실행(재현성 확인) ─────────────────────────
// node probe.mjs repeat B:K7:3 B:K4:2 B2:K7:3 B2:K4:2
// 회차는 칸마다 기존 최대 회차 다음 번호부터 매긴다(output/repeat/{변형}_{케이스}_r{n}) —
// 기존 결과(본 매트릭스·이전 반복)는 덮어쓰지 않는다. 칸들을 라운드로빈으로
// 돌려(1회차 전 칸 → 2회차 전 칸 …) 시간대 변동이 한 변형에 몰리지 않게 한다.
async function runRepeat(args) {
  const schemaPath = join(OUTPUT, "schema.json");
  if (!existsSync(schemaPath)) { console.error("schema.json이 없습니다 — 먼저 `node probe.mjs schema`."); process.exit(2); }
  const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
  const specs = args.map((a) => {
    const [v, k, n] = a.split(":");
    const times = Number(n);
    if (!VARIANTS[v] || !CASES[k] || !Number.isInteger(times) || times < 1 ||
        (VARIANTS[v].cases && !VARIANTS[v].cases.includes(k))) {
      console.error(`잘못된 지정: ${a} — 형식 변형:케이스:횟수 (예: B:K7:3)`);
      process.exit(2);
    }
    return {v, k, times};
  });
  if (!specs.length) { console.error("반복할 칸이 없습니다. 예: node probe.mjs repeat B:K7:3 B2:K7:3"); process.exit(2); }
  const {files, labels} = loadInputs();
  const results = loadResults();
  results.repeats ??= [];
  const maxRound = Math.max(...specs.map((x) => x.times));
  let first = true;
  for (let round = 0; round < maxRound; round++) {
    for (const {v, k, times} of specs) {
      if (round >= times) continue;
      if (!first) await sleep(GAP_MS);
      first = false;
      const rep = 1 + Math.max(0, ...results.repeats.filter((x) => x.variant === v && x.case === k).map((x) => x.rep));
      const run = await runCase(v, k, files, labels, schema, {outName: `repeat/${v}_${k}_r${rep}`, saveSteps: false});
      run.rep = rep;
      run.order = (results.repeatCounter = (results.repeatCounter ?? 0) + 1);
      results.repeats.push(run);
      writeFileSync(join(OUTPUT, "results.json"), JSON.stringify(results, null, 2));
      writeResultsMd();
      writeHtml();
      log(`[repeat ${v}/${k} r${rep}] 완료 ok=${run.ok} 총 ${run.totalSecs}s${run.missing.length ? " 누락=" + run.missing.join(",") : ""}`);
    }
  }
}

// ── results.md ────────────────────────────────────────────────────
function writeResultsMd() {
  const schemaPath = join(OUTPUT, "schema.json");
  const s = existsSync(schemaPath) ? JSON.parse(readFileSync(schemaPath, "utf8")) : null;
  const res = loadResults();
  const L = ["# 피팅 프로브 결과 (task_fitting_quality_v2 §3)", ""];
  L.push("## 스키마 확정 (§3-2)", "");
  if (!s) L.push("(아직 실행 안 함)");
  else {
    L.push(`| 항목 | 결과 |`, `|---|---|`,
      `| models.get ${NEW_MODEL} | ${s.models?.[NEW_MODEL]?.status} ${JSON.stringify(s.models?.[NEW_MODEL]?.methods ?? s.models?.[NEW_MODEL]?.error)} |`,
      `| 1. generateContent 동작 | ${s.endpointOk ? "예" : "**아니오**"} |`,
      `| 2. 크기 필드 / 비율 필드 | ${s.sizeField ?? "확정 실패"} / ${s.aspectField ?? "확정 실패"} |`,
      `| 3. thinking 필드 · minimal | ${s.thinkingField ?? "확정 실패"} · ${s.minimalOk ? `허용(${s.minimalValue})` : "거부"} |`,
      `| 4. responseModalities ["IMAGE"] 단독 | ${s.imageOnlyOk ? "허용" : "거부"} |`,
      `| 5. 응답 mimeType(실제/선언) · 해상도 | ${s.responseMime ?? "-"} / ${s.responseDeclaredMime ?? "-"} · ${sizeText(s.responseDims)} |`);
    if (s.interactionsProbe) L.push(`| Interactions API 탐침 | ${s.interactionsProbe.status} ${s.interactionsProbe.body.replace(/\|/g, "\\|").replace(/\n/g, " ")} |`);
    L.push("", "스키마 호출 내역:", "", "| 호출 | generationConfig | HTTP | 초 | 출력 | thinking 토큰 | 오류 |", "|---|---|---|---|---|---|---|");
    for (const c of s.calls) {
      L.push(`| ${c.name} | \`${JSON.stringify(c.generationConfig)}\` | ${c.status} | ${c.secs} | ${c.mime ?? "-"} ${sizeText(c.dims)} ${c.bytes ?? ""} | ${c.thoughtsTokens ?? "-"} | ${(c.error ?? "").replace(/\|/g, "\\|")} |`);
    }
  }
  if (res.inputs) {
    L.push("", "## 입력 (축소 없이 그대로 전송)", "", "| 파일 | 실제 형식 | 해상도 | 바이트 | 라벨 |", "|---|---|---|---|---|");
    for (const [n, f] of Object.entries(res.inputs)) L.push(`| ${n}.jpg | ${f.mime} | ${sizeText(f.dims)} | ${f.bytes} | ${res.labels?.[n] ?? "-"} |`);
  }
  L.push("", "## 매트릭스 (§3-3)", "",
    "| 순서 | 변형 | 케이스 | 호출 수 | 총 소요 초 | 단계별 초 | HTTP 상태 | 재시도 | 출력 해상도 | 출력 바이트 | 요청 바이트(최대) | thinking 토큰 | 누락 | 오류 |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
  const rows = [...res.runs].sort((a, b) => a.case.localeCompare(b.case) || a.variant.localeCompare(b.variant));
  for (const r of rows) {
    L.push(`| ${r.order} | ${r.variant} | ${r.case} | ${r.calls} | ${r.totalSecs} | ${r.steps.map((x) => x.secs).join(" / ")} | ` +
      `${r.steps.map((x) => x.attemptStatuses.join("→")).join(" / ")} | ${r.steps.filter((x) => x.retried).length} | ` +
      `${r.out ? sizeText(r.out.dims) + " " + r.out.mime.replace("image/", "") : "-"} | ${r.out?.bytes ?? "-"} | ` +
      `${Math.max(...r.steps.map((x) => x.requestBytes))} | ${r.steps.map((x) => x.thoughtsTokens ?? "-").join(" / ")} | ` +
      `${r.missing.join(",") || "-"} | ${r.steps.map((x) => x.error).filter(Boolean).join(" ; ").replace(/\|/g, "\\|") || "-"} |`);
  }
  if (res.repeats?.length) {
    L.push("", "## 반복 실행 (재현성 확인)", "",
      "| 순서 | 변형 | 케이스 | 회차 | 총 소요 초 | HTTP 상태 | 재시도 | 출력 해상도 | 출력 바이트 | 파일 | 누락 | 오류 |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|");
    const reps = [...res.repeats].sort((a, b) => a.case.localeCompare(b.case) || a.variant.localeCompare(b.variant) || a.rep - b.rep);
    for (const r of reps) {
      L.push(`| ${r.order} | ${r.variant} | ${r.case} | r${r.rep} | ${r.totalSecs} | ${r.steps.map((x) => x.attemptStatuses.join("→")).join(" / ")} | ` +
        `${r.steps.filter((x) => x.retried).length} | ${r.out ? sizeText(r.out.dims) + " " + r.out.mime.replace("image/", "") : "-"} | ${r.out?.bytes ?? "-"} | ` +
        `${r.out?.file ?? "-"} | ${r.missing.join(",") || "-"} | ${r.steps.map((x) => x.error).filter(Boolean).join(" ; ").replace(/\|/g, "\\|") || "-"} |`);
    }
  }
  L.push("", "시간은 호출 왕복 시간 합(재시도 포함, 호출 사이 2초 간격 제외). 시한 180초/호출.");
  writeFileSync(join(OUTPUT, "results.md"), L.join("\n") + "\n");
}

// ── index.html (§3-5) ────────────────────────────────────────────
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));

// CSS 크롭: 정규화 박스를 background-size/position으로 잘라 보여준다(파일은
// 자르지 않는다). 표시 높이 H 고정, 폭은 박스의 실제 픽셀 비율로.
function cropDiv(src, dims, box, H) {
  if (!dims) return `<div class="na">해상도 미상</div>`;
  const bw = box.x1 - box.x0;
  const bh = box.y1 - box.y0;
  const W = Math.round((H * (bw * dims.w)) / (bh * dims.h));
  const px = bw >= 1 ? 0 : (box.x0 / (1 - bw)) * 100;
  const py = bh >= 1 ? 0 : (box.y0 / (1 - bh)) * 100;
  const zoom = H / (bh * dims.h);
  return `<a href="${esc(src)}" target="_blank"><div class="crop" style="width:${W}px;height:${H}px;` +
    `background-image:url('${esc(src)}');background-size:${(100 / bw).toFixed(3)}% ${(100 / bh).toFixed(3)}%;` +
    `background-position:${px.toFixed(3)}% ${py.toFixed(3)}%"></div></a>` +
    `<div class="meta">${dims.w}×${dims.h} · 배율 ${zoom.toFixed(2)}×</div>`;
}

function writeHtml() {
  const res = loadResults();
  const FULL_H = 360;
  const CROP_H = 220;
  const vKeys = Object.keys(VARIANTS).filter((k) => !VARIANTS[k].repeatOnly);
  const byKey = Object.fromEntries(res.runs.map((r) => [`${r.variant}_${r.case}`, r]));
  const vDesc = (k) => {
    const v = VARIANTS[k];
    return `${k} · ${v.model.replace("gemini-", "")} · ${v.mode}${v.thinking ? " · " + v.thinking : ""}`;
  };
  let body = "";
  for (const [k, slots] of Object.entries(CASES)) {
    const inputs = ["person", ...slots].map((n) =>
      `<figure><a href="../input/${n}.jpg" target="_blank"><img src="../input/${n}.jpg" style="height:110px"></a><figcaption>${n}</figcaption></figure>`).join("");
    const cells = (render) => vKeys.map((vk) => {
      const r = byKey[`${vk}_${k}`];
      if (VARIANTS[vk].cases && !VARIANTS[vk].cases.includes(k)) return `<td class="skip">—</td>`;
      if (!r) return `<td class="na">미실행</td>`;
      if (!r.out) return `<td class="na">실패<br><small>${esc(r.steps.map((x) => x.error).filter(Boolean).join("; ").slice(0, 200))}</small></td>`;
      return `<td>${render(r)}</td>`;
    }).join("");
    const head = `<tr><th></th>${vKeys.map((vk) => `<th>${esc(vDesc(vk))}</th>`).join("")}</tr>`;
    const full = cells((r) => `<a href="${esc(r.out.file)}" target="_blank"><img src="${esc(r.out.file)}" style="height:${FULL_H}px"></a>` +
      `<div class="meta"><b>${r.totalSecs}초</b> · 호출 ${r.calls}${r.steps.some((x) => x.retried) ? " (재시도 포함)" : ""}` +
      `${r.missing.length ? ` · <span class="bad">누락 ${esc(r.missing.join(","))}</span>` : ""}</div>`);
    const cropRow = (box) => cells((r) => cropDiv(r.out.file, r.out.dims, box, CROP_H));
    body += `<section><h2>${k} — ${slots.join(" · ")}</h2><div class="inputs">${inputs}</div><table>${head}` +
      `<tr><th>전체</th>${full}</tr>` +
      `<tr><th>${CROPS.face.name}<br><small>x=[${CROPS.face.x0},${CROPS.face.x1}]<br>y=[${CROPS.face.y0},${CROPS.face.y1}]</small></th>${cropRow(CROPS.face)}</tr>` +
      (slots.includes("hat") ? `<tr><th>${CROPS.hat.name}<br><small>x=[${CROPS.hat.x0},${CROPS.hat.x1}]<br>y=[${CROPS.hat.y0},${CROPS.hat.y1}]</small></th>${cropRow(CROPS.hat)}</tr>` : "") +
      `</table></section>`;
  }
  if (res.repeats?.length) {
    body += `<h1>반복 실행 (재현성 확인)</h1><p>변형별 한 줄, 회차 순. "넣지 않은 아이템 추가"는 몸통·손목 크롭에서 본다. B2는 Rules 마지막 줄만 B와 다르다.</p>`;
    const repCases = [...new Set(res.repeats.map((r) => r.case))].sort();
    for (const k of repCases) {
      let rows = "";
      const repVariants = [...new Set(res.repeats.filter((r) => r.case === k).map((r) => r.variant))].sort();
      for (const vk of repVariants) {
        const runs = res.repeats.filter((r) => r.case === k && r.variant === vk).sort((a, b) => a.rep - b.rep);
        const cell = (render) => runs.map((r) => r.out ? `<td>${render(r)}</td>` :
          `<td class="na">r${r.rep} 실패<br><small>${esc(r.steps.map((x) => x.error).filter(Boolean).join("; ").slice(0, 200))}</small></td>`).join("");
        const full = cell((r) => `<div class="meta">r${r.rep}</div><a href="${esc(r.out.file)}" target="_blank"><img src="${esc(r.out.file)}" style="height:${FULL_H}px"></a>` +
          `<div class="meta"><b>${r.totalSecs}초</b>${r.missing.length ? ` · <span class="bad">누락 ${esc(r.missing.join(","))}</span>` : ""}</div>`);
        const crop = (box) => cell((r) => cropDiv(r.out.file, r.out.dims, box, CROP_H));
        rows += `<tr><th>${esc(vk)} 전체</th>${full}</tr>` +
          `<tr><th>${CROPS.torso.name}<br><small>x=[${CROPS.torso.x0},${CROPS.torso.x1}]<br>y=[${CROPS.torso.y0},${CROPS.torso.y1}]</small></th>${crop(CROPS.torso)}</tr>` +
          `<tr><th>${CROPS.face.name}</th>${crop(CROPS.face)}</tr>` +
          (CASES[k].includes("hat") ? `<tr><th>${CROPS.hat.name}</th>${crop(CROPS.hat)}</tr>` : "");
      }
      body += `<section><h2>반복 ${k} — ${CASES[k].join(" · ")}</h2><table>${rows}</table></section>`;
    }
  }
  const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>피팅 프로브 비교</title><style>
:root{--bg:#fff;--fg:#1a1a1a;--mute:#666;--line:#ddd;--bad:#c0392b}
@media (prefers-color-scheme:dark){:root{--bg:#161616;--fg:#eee;--mute:#999;--line:#333;--bad:#ff6b5b}}
body{background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,sans-serif;margin:16px}
table{border-collapse:collapse}th,td{border:1px solid var(--line);padding:6px;vertical-align:top;text-align:center}
th{font-weight:600;font-size:12px}section{margin-bottom:40px;overflow-x:auto}
.inputs{display:flex;gap:8px;margin:8px 0}figure{margin:0;text-align:center}figcaption,.meta{font-size:12px;color:var(--mute)}
.crop{background-repeat:no-repeat;display:inline-block}.na,.skip{color:var(--mute)}.bad{color:var(--bad);font-weight:600}
</style></head><body><h1>피팅 프로브 비교 (task_fitting_quality_v2 §3-5)</h1>
<p>전체 프레임 표시 높이 ${FULL_H}px, 크롭 표시 높이 ${CROP_H}px로 통일. 크롭은 CSS로만 했고(파일 미가공) 박스는 원본 프레임 기준 정규화 좌표, 전 변형 공통. 배율 = 표시 높이 ÷ 박스의 원본 픽셀 높이. 이미지를 누르면 원본 전체가 열린다.</p>
${body}</body></html>`;
  writeFileSync(join(OUTPUT, "index.html"), html);
}

// ── main ──────────────────────────────────────────────────────────
const [cmd = "all", ...args] = process.argv.slice(2);
mkdirSync(STEPS, {recursive: true});
mkdirSync(join(OUTPUT, "repeat"), {recursive: true});
if (cmd === "html") { writeResultsMd(); writeHtml(); log(`→ ${join(OUTPUT, "index.html")}`); process.exit(0); }
if (!API_KEY) { console.error("GEMINI_API_KEY 환경변수가 없습니다."); process.exit(2); }
if (cmd === "schema" || cmd === "all") {
  loadInputs();
  const s = await runSchema();
  if (!s.endpointOk) { console.error("generateContent가 새 모델에서 동작하지 않음 — §3-2에 따라 여기서 멈춘다."); process.exit(3); }
}
if (cmd === "matrix" || cmd === "all") await runMatrix(args);
if (cmd === "repeat") await runRepeat(args);
writeResultsMd();
writeHtml();
log(`→ ${join(OUTPUT, "results.md")}\n→ ${join(OUTPUT, "index.html")}`);
