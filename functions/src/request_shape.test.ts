// request_shape.ts 단위 테스트 — payload_limit.test.ts와 같은 방식
// (node:assert 직접 사용, tsc로 컴파일된 lib/request_shape.test.js를
// node로 실행. package.json의 "test" 스크립트 참고).
import * as assert from "node:assert";
import {evaluateRequestShape, RequestShapeConfig, REQUEST_SHAPE_CONFIG} from "./request_shape";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

// ── 우리 앱이 실제로 만드는 6종 요청 형태 ──────────────────────
// 상상해서 쓰지 않는다 - lib/services/gemini_service.dart를 읽고 그대로
// 옮겼다(텍스트 내용 자체는 상관없어 짧은 대역값으로 대체 - 판정은 형태만
// 본다). 각 픽스처 바로 위에 출처 행을 남긴다.

// (a) 속성 추출 — extractAttributes, gemini_service.dart:493-509.
// parts: [text, inlineData] 1장. generationConfig에 responseMimeType/
// thinkingConfig 포함.
const FIXTURE_EXTRACT_ATTRIBUTES = {
  contents: [{
    parts: [
      {text: "이 옷 사진에서 카테고리·색상·스타일·패턴·격식·핏·태그를 JSON으로 추출하세요."},
      {inlineData: {mimeType: "image/jpeg", data: "AAAA"}},
    ],
  }],
  generationConfig: {
    temperature: 0.2,
    maxOutputTokens: 800,
    responseMimeType: "application/json",
    thinkingConfig: {thinkingBudget: 0},
  },
};

// (b) 사이즈표 OCR — extractSizeFromChart, gemini_service.dart:537-553.
// (a)와 같은 뼈대(parts: [text, inlineData] 1장) - temperature만 다르다.
const FIXTURE_SIZE_CHART_OCR = {
  contents: [{
    parts: [
      {text: "이 사이즈표에서 'M' 사이즈 행의 치수만 JSON으로 추출하세요."},
      {inlineData: {mimeType: "image/jpeg", data: "AAAA"}},
    ],
  }],
  generationConfig: {
    temperature: 0.1,
    maxOutputTokens: 800,
    responseMimeType: "application/json",
    thinkingConfig: {thinkingBudget: 0},
  },
};

// (c) 코디 분석(사진 기반) — analyzeOutfitFromAttributes,
// gemini_service.dart:628-686, hasProfile=false && userPhotoUrl!=null
// 분기(_buildAttributeAnalysisPromptWithPhoto, 663-664행) - 전신 사진을
// 함께 보낸다. parts: [text, inlineData] 1장.
const FIXTURE_OUTFIT_ANALYSIS_WITH_PHOTO = {
  contents: [{
    parts: [
      {text: "다음 옷 조합과 전신 사진을 보고 어울림을 평가하세요: 상의(네이비/캐주얼), 하의(베이지/캐주얼)."},
      {inlineData: {mimeType: "image/jpeg", data: "AAAA"}},
    ],
  }],
  generationConfig: {temperature: 0.7, maxOutputTokens: 3000},
};

// (d) 체형 분석(프로필 기반) — analyzeOutfitFromAttributes,
// gemini_service.dart:628-686, hasProfile=true 분기
// (_buildAttributeAnalysisPromptWithProfile, 659-661행) - "사용자 체형
// 프로필이 입력되어 있으면 그 텍스트가 사진보다 정확하고 훨씬 빠르므로
// 우선하고, 이 경우 전신 사진은 아예 보내지 않는다"(642행 주석) - (c)와
// 달리 inlineData가 없다. parts: [text]만.
const FIXTURE_BODY_PROFILE_ANALYSIS = {
  contents: [{
    parts: [
      {text: "사용자 체형(키 175cm, 마름, 어깨 좁음)을 고려해 다음 옷 조합을 평가하세요: 상의(네이비/캐주얼)."},
    ],
  }],
  generationConfig: {temperature: 0.7, maxOutputTokens: 3000},
};

// (e) 자기 평가 — outfit_self_evaluator.dart:116-124가
// analyzeOutfitFromAttributes를 userProfile·userPhotoUrl 둘 다 없이
// 호출한다 - hasProfile=false && userPhotoUrl==null 분기
// (_buildAttributeAnalysisPrompt, 665행) - (d)와 마찬가지로 inlineData가
// 없지만 호출부(자기 평가 루프, 후보 재평가용)가 (c)/(d)와 다르다.
// 와이어 형태는 (d)와 구조적으로 동일하다 - 이것이 실측이다(추정이
// 아니라 코드 확인, 별도 함수가 아니라 같은 함수의 세 번째 분기를 탄다).
const FIXTURE_SELF_EVALUATION = {
  contents: [{
    parts: [
      {text: "다음 옷 조합을 평가하세요: 상의(네이비/캐주얼), 하의(베이지/캐주얼), 신발(화이트/캐주얼)."},
    ],
  }],
  generationConfig: {temperature: 0.7, maxOutputTokens: 3000},
};

// (f) 피팅 — _generateFittingImageSequential, gemini_service.dart:425-433.
// 순차 합성 1단계 = text 1 + inlineData 2장(사용자 현재 사진 + 옷 사진).
// generationConfig가 앞의 다섯과 다르다(responseModalities, 이미지
// 합성 모델 전용).
const FIXTURE_FITTING_STEP = {
  contents: [{
    parts: [
      {text: "첫 번째 사진 속 사람에게 두 번째 사진의 상의를 입혀주세요."},
      {inlineData: {mimeType: "image/jpeg", data: "AAAA"}},
      {inlineData: {mimeType: "image/jpeg", data: "AAAA"}},
    ],
  }],
  generationConfig: {responseModalities: ["IMAGE", "TEXT"]},
};

const REAL_FIXTURES: Array<[string, unknown]> = [
  ["(a) 속성 추출", FIXTURE_EXTRACT_ATTRIBUTES],
  ["(b) 사이즈표 OCR", FIXTURE_SIZE_CHART_OCR],
  ["(c) 코디 분석(사진 기반)", FIXTURE_OUTFIT_ANALYSIS_WITH_PHOTO],
  ["(d) 체형 분석(프로필 기반)", FIXTURE_BODY_PROFILE_ANALYSIS],
  ["(e) 자기 평가", FIXTURE_SELF_EVALUATION],
  ["(f) 피팅", FIXTURE_FITTING_STEP],
];

for (const [label, fixture] of REAL_FIXTURES) {
  run(`실제 요청 형태 ${label} — 현재 상한(REQUEST_SHAPE_CONFIG)을 통과한다`, () => {
    const decision = evaluateRequestShape(fixture, "text", REQUEST_SHAPE_CONFIG);
    assert.strictEqual(decision.allowed, true, `violations: ${decision.violations.join(",")}`);
    assert.deepStrictEqual(decision.violations, []);
  });
}

// ── 위반 케이스 ──────────────────────────────────────────────

run("tools 키 존재 — top_level_unknown_key", () => {
  const body = {contents: [{parts: [{text: "hi"}]}], tools: [{functionDeclarations: []}]};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("top_level_unknown_key"));
});

run("알 수 없는 top-level 키 — top_level_unknown_key", () => {
  const body = {contents: [{parts: [{text: "hi"}]}], cachedContent: "projects/x/cachedContents/y"};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("top_level_unknown_key"));
});

run("contents 누락 — contents_missing", () => {
  const body = {generationConfig: {temperature: 0.5}};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.deepStrictEqual(decision.violations, ["contents_missing"]);
});

run("contents가 배열 아님 — contents_not_array", () => {
  const body = {contents: {parts: [{text: "hi"}]}};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.deepStrictEqual(decision.violations, ["contents_not_array"]);
});

run("part에 알 수 없는 키 — part_unknown_key", () => {
  const body = {contents: [{parts: [{text: "hi"}, {fileData: {fileUri: "gs://x"}}]}]};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("part_unknown_key"));
});

run("inlineData.mimeType이 image/ 아님 — inline_data_bad_mime", () => {
  const body = {
    contents: [{parts: [{inlineData: {mimeType: "application/pdf", data: "AAAA"}}]}],
  };
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("inline_data_bad_mime"));
});

run("inlineData에 mimeType 필드 자체가 없음 — inline_data_bad_mime", () => {
  const body = {contents: [{parts: [{inlineData: {data: "AAAA"}}]}]};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("inline_data_bad_mime"));
});

// ── 경계값 (테스트 전용 좁은 config — REQUEST_SHAPE_CONFIG는 느슨해서
// 경계를 실제로 넘기려면 픽스처가 너무 커진다) ──────────────────────

const BOUNDARY_CONFIG: RequestShapeConfig = {
  maxContents: 2,
  maxPartsPerContent: 3,
  maxTotalTextChars: 20,
  maxInlineDataCount: 2,
};

function contentWithParts(partCount: number): unknown {
  return {parts: Array.from({length: partCount}, () => ({text: "x"}))};
}

run("maxContents 경계값(==2) — 허용", () => {
  const body = {contents: [contentWithParts(1), contentWithParts(1)]};
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.metrics.contentsCount, 2);
});

run("maxContents 초과(==3) — contents_too_many", () => {
  const body = {contents: [contentWithParts(1), contentWithParts(1), contentWithParts(1)]};
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("contents_too_many"));
});

run("maxPartsPerContent 경계값(==3) — 허용", () => {
  const body = {contents: [contentWithParts(3)]};
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.metrics.maxPartsInAnyContent, 3);
});

run("maxPartsPerContent 초과(==4) — parts_too_many", () => {
  const body = {contents: [contentWithParts(4)]};
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("parts_too_many"));
});

run("maxTotalTextChars 경계값(==20) — 허용", () => {
  const body = {contents: [{parts: [{text: "a".repeat(20)}]}]};
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.metrics.totalTextChars, 20);
});

run("maxTotalTextChars 초과(==21) — text_too_long", () => {
  const body = {contents: [{parts: [{text: "a".repeat(21)}]}]};
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("text_too_long"));
});

run("maxTotalTextChars는 모든 content·part의 text를 합산한다", () => {
  const body = {
    contents: [
      {parts: [{text: "a".repeat(10)}, {text: "b".repeat(10)}]},
    ],
  };
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, true); // 정확히 20, 경계 포함
  assert.strictEqual(decision.metrics.totalTextChars, 20);
});

run("maxInlineDataCount 경계값(==2) — 허용", () => {
  const body = {
    contents: [{
      parts: [
        {inlineData: {mimeType: "image/jpeg", data: "A"}},
        {inlineData: {mimeType: "image/jpeg", data: "A"}},
      ],
    }],
  };
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.metrics.inlineDataCount, 2);
});

run("maxInlineDataCount 초과(==3) — inline_data_too_many", () => {
  const body = {
    contents: [{
      parts: [
        {inlineData: {mimeType: "image/jpeg", data: "A"}},
        {inlineData: {mimeType: "image/jpeg", data: "A"}},
        {inlineData: {mimeType: "image/jpeg", data: "A"}},
      ],
    }],
  };
  const decision = evaluateRequestShape(body, "text", BOUNDARY_CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.ok(decision.violations.includes("inline_data_too_many"));
});

// ── 총체성 — 예외를 던지지 않는다 ──────────────────────────────

const MALFORMED_BODIES: Array<[string, unknown]> = [
  ["null", null],
  ["undefined", undefined],
  ["문자열", "not an object"],
  ["숫자", 42],
  ["빈 객체", {}],
  ["배열", [1, 2, 3]],
];

for (const [label, body] of MALFORMED_BODIES) {
  run(`총체성 — body가 ${label}이어도 예외 없이 위반을 반환한다`, () => {
    const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
    assert.strictEqual(decision.allowed, false);
    assert.ok(decision.violations.length > 0);
  });
}

run("총체성 — content 원소가 object가 아니어도 예외 없이 건너뛴다", () => {
  const body = {contents: ["not an object", 42, null]};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, true); // 셋 다 무시되어 parts 집계 0
  assert.strictEqual(decision.metrics.maxPartsInAnyContent, 0);
});

run("총체성 — part 원소가 object가 아니어도 예외 없이 건너뛴다", () => {
  const body = {contents: [{parts: ["not an object", 42, null]}]};
  const decision = evaluateRequestShape(body, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.metrics.totalTextChars, 0);
  assert.strictEqual(decision.metrics.inlineDataCount, 0);
});

// ── metrics 정확성 ──────────────────────────────────────────────

run("metrics — 알려진 입력에 대해 정확한 값을 낸다", () => {
  const body = {
    contents: [
      {parts: [{text: "12345"}]}, // 5 chars, 1 part
      {
        parts: [
          {text: "12345"}, // 5 chars
          {inlineData: {mimeType: "image/jpeg", data: "A"}},
          {inlineData: {mimeType: "image/jpeg", data: "A"}},
        ],
      }, // 3 parts, 2 inlineData
    ],
  };
  const decision = evaluateRequestShape(body, "image", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.metrics.contentsCount, 2);
  assert.strictEqual(decision.metrics.maxPartsInAnyContent, 3); // 두 content 중 최댓값
  assert.strictEqual(decision.metrics.totalTextChars, 10); // 5 + 5
  assert.strictEqual(decision.metrics.inlineDataCount, 2);
  assert.strictEqual(decision.allowed, true);
});

console.log("전부 통과");
