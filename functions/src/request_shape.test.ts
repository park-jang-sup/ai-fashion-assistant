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

// ── 우리 앱이 실제로 만드는 6종 요청 형태(와이어 형태 기준) ─────────
// 상상해서 쓰지 않는다 - lib/services/gemini_service.dart를 읽고 그대로
// 옮겼다(텍스트 내용 자체는 상관없어 짧은 대역값으로 대체 - 판정은 형태만
// 본다). 각 픽스처 바로 위에 출처 행을 남긴다.
//
// [정정 2026-08-10] 이 6종은 **사용자 조작 단위가 아니라 와이어 형태
// 단위**다. docs/task_hardening_v2.md §4-3이 한때 이 6종을 "6개 사용자
// 경로"로 그대로 승계해 실행 목록을 만들었으나, 실제 사용자 조작은
// 5가지뿐이다 - (c)/(d)는 서로 다른 두 조작이 아니라 **같은 조작("AI
// 코디 분석하기")이 사용자 프로필 입력 여부에 따라 만드는 두 형태**다
// (analyzeOutfitFromAttributes의 hasProfile 분기, gemini_service.dart:644).
// 두 목록의 대응 관계는 §4-3의 표를 참고할 것 - 픽스처(와이어 형태)
// 분류를 실행 경로(사용자 조작) 분류에 그대로 갖다 쓰면 안 된다는
// 교훈이 여기서 나왔다.

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

// (d) 코디 분석(프로필 기반, 사진 미첨부) — analyzeOutfitFromAttributes,
// gemini_service.dart:628-686, hasProfile=true 분기
// (_buildAttributeAnalysisPromptWithProfile, 659-661행) - "사용자 체형
// 프로필이 입력되어 있으면 그 텍스트가 사진보다 정확하고 훨씬 빠르므로
// 우선하고, 이 경우 전신 사진은 아예 보내지 않는다"(642행 주석) - (c)와
// 달리 inlineData가 없다. parts: [text]만.
//
// [정정 2026-08-10] 원래 "체형 분석"이라는 별도 기능으로 이름 붙였으나
// 실재하지 않는 이름이었다 - 이건 (c)와 **같은 사용자 조작("AI 코디
// 분석하기")**이 사용자가 체형 프로필을 입력해 뒀을 때 타는 분기일
// 뿐이다. "체형 분석"이라는 화면·버튼·진입점은 코드 어디에도 없다
// (fit_predictor.dart:18의 규칙 기반 핏 예측기는 Gemini를 호출하지
// 않으므로 별개). 와이어 형태 자체는 실재하므로(텍스트만, 이미지 없음)
// 픽스처는 유지하고 이름만 바로잡는다 - docs/task_hardening_v2.md
// §4-1/§4-3 참고.
const FIXTURE_OUTFIT_ANALYSIS_WITH_PROFILE = {
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
// (d)와 마찬가지로 이 픽스처도 "체형 분석"이 아니라 analyzeOutfitFromAttributes의
// 세 번째 분기(사진·프로필 둘 다 없음)일 뿐이며, 실제 호출부는
// 자기 평가 루프(outfit_self_evaluator.dart)라는 점만 (d)와 다르다.
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

// (g) 주간 플랜 — planWeeklyOutfits, gemini_service.dart:696-744
// (조립부는 agent_planner.dart:690-728). contents: [{parts: [{text}]}] -
// 텍스트 하나, 이미지 없음. 시스템에서 가장 큰 텍스트 페이로드를
// 만드는 경로다 - 옷장 카탈로그 전체 + 7일 일정 + 최근 피드백을
// 프롬프트에 그대로 싣는다.
//
// [등록 2026-08-11, S3-c 잔여] 이 경로는 S3-b 계측 창(§4-3의 5경로)에
// 한 번도 실행되지 않았고, 지금까지 이 파일의 6종 픽스처에도 없었다 -
// 진짜 커버리지 공백이었다(docs/task_hardening_v2.md §4-4 "planWeeklyOutfits
// 커버리지 공백" 참고 - 사이즈표 OCR의 "귀속 공백"과는 성격이 다르다,
// 그쪽은 형태가 같아 이미 검증돼 있었다). 아래는 그 공백을 메우는
// 픽스처 - gemini_service.dart:705-724의 프롬프트 템플릿을 그대로
// 재현하고, 대표값은 코드가 실제로 쓰는 어휘(TpoTags.labels,
// ClothingAttributes.toPromptLine 필드 형태)에서만 뽑는다. 옷장
// 규모(118벌)는 임의 숫자가 아니라 이 저장소가 반복 인용해 온 실제
// 개발 계정 규모다(docs/DOT_paper_rev8.md, docs/HANDOFF.md).
const PLAN_CATEGORIES = ["상의", "하의", "아우터", "신발", "액세서리"];
const PLAN_COLORS = ["네이비", "블랙", "화이트", "베이지", "그레이", "카키", "브라운", "아이보리"];
const PLAN_STYLES = ["캐주얼", "미니멀", "스트릿", "클래식", "스포티"];
const PLAN_PATTERNS = ["무지", "스트라이프", "체크", "도트"];
const PLAN_FORMALITIES = ["캐주얼", "세미포멀", "포멀"];
const PLAN_FITS = ["슬림", "레귤러", "오버사이즈"];
const PLAN_TAGS = ["봄", "가을", "데일리", "출근룩", "포인트", "베이직"];
// Firestore 자동 생성 문서 ID와 같은 자릿수(20)의 대역값 - 실제 id
// 문자열은 판정에 영향을 주지 않는다(길이만 형태에 반영된다).
const PLAN_ID_PLACEHOLDER = "x".repeat(20);

function buildWardrobeCatalog(itemCount: number): string {
  const lines: string[] = [];
  for (let i = 0; i < itemCount; i++) {
    const category = PLAN_CATEGORIES[i % PLAN_CATEGORIES.length];
    const color = PLAN_COLORS[i % PLAN_COLORS.length];
    const style = PLAN_STYLES[i % PLAN_STYLES.length];
    const pattern = PLAN_PATTERNS[i % PLAN_PATTERNS.length];
    const formality = PLAN_FORMALITIES[i % PLAN_FORMALITIES.length];
    const fit = PLAN_FITS[i % PLAN_FITS.length];
    const tags = [PLAN_TAGS[i % PLAN_TAGS.length], PLAN_TAGS[(i + 1) % PLAN_TAGS.length]];
    // ClothingAttributes.toPromptLine() 형식(lib/models/clothing_attributes.dart:39-42)
    const attrLine =
      `색상 ${color}, 스타일 ${style}, 패턴 ${pattern}, 격식 ${formality}, ` +
      `핏 ${fit}, 태그: ${tags.join(", ")}`;
    // agent_planner.dart:705-707 형식
    lines.push(`- id=${PLAN_ID_PLACEHOLDER} | ${category} | ${attrLine}`);
  }
  return lines.join("\n");
}

const PLAN_TPO_LABELS = ["출근", "데이트", "여행", "운동", "모임", "결혼식", "면접", "경조사", "일상"];
const PLAN_WEATHER_NOTES = [
  " — 비 예보(강수확률 80%) — 밝은 색/니트류 회피, 방수 소재나 어두운 톤 우선",
  " — 추운 날(최저 -5°C) — 두꺼운 아우터 우선",
];
const PLAN_WEEKDAYS_KO = ["월", "화", "수", "목", "금", "토", "일"];

function buildScheduleLines(dayCount: number): string {
  const lines: string[] = [];
  for (let i = 0; i < dayCount; i++) {
    const tpo = PLAN_TPO_LABELS[i % PLAN_TPO_LABELS.length];
    const formality =
      tpo === "결혼식" || tpo === "면접" || tpo === "경조사"
        ? "포멀"
        : tpo === "일상" || tpo === "여행" || tpo === "운동"
          ? "캐주얼"
          : "세미포멀";
    const weatherNote = PLAN_WEATHER_NOTES[i % PLAN_WEATHER_NOTES.length];
    // agent_planner.dart:701-702 형식
    lines.push(
      `${i + 1}. 2026-08-${10 + i} (${PLAN_WEEKDAYS_KO[i]}) — ${tpo} — 요구 격식: ${formality}${weatherNote}`
    );
  }
  return lines.join("\n");
}

function buildFeedbackSection(feedbackLineCount: number): string {
  if (feedbackLineCount === 0) return "";
  const lines: string[] = [];
  for (let i = 0; i < feedbackLineCount; i++) {
    lines.push(`- 2026-08-0${i + 1}: 상의 A + 하의 B 추천 → 실제 착용 상의 A + 하의 C (하의 불일치)`);
  }
  // gemini_service.dart:702-704 형식
  return `\n[취향 피드백 - 반영하세요]\n${lines.join("\n")}\n`;
}

// gemini_service.dart:705-724의 프롬프트 템플릿을 그대로 재현한다.
function buildPlanPrompt(wardrobeCatalog: string, scheduleLines: string, feedbackSection: string): string {
  return `당신은 전문 패션 스타일리스트입니다. 아래 옷장 아이템만 사용해 요청된 날짜별 코디를 계획하세요.

[옷장 아이템] (반드시 이 id만 사용, 목록에 없는 id는 절대 만들지 마세요)
${wardrobeCatalog}

[계획할 날짜]
${scheduleLines}
${feedbackSection}
[제약 조건 - 반드시 지키세요]
- 각 날짜에 상의 1개 + 하의 1개를 기본으로 배정하고, 필요하면 아우터/신발을 더하세요.
- 같은 상의 또는 같은 하의를 이틀 연속 배치하지 마세요(중복 회피).
- 격식이 높은 조합(포멀/세미포멀 아이템)은 출근·데이트·모임처럼 격식이 필요한 날에 우선 배분하세요.
- 어떤 날짜에 그 격식에 딱 맞는 아이템이 옷장에 없더라도 그 날을 건너뛰지 말고, 가장 가까운 차선 조합을 배정한 뒤 reason에 "딱 맞는 조합이 없어 가장 가까운 조합"임을 밝히세요.
- itemIds는 위 옷장에 실제로 존재하는 id만 사용하세요.

[출력 형식 - 반드시 지키세요]
순수 JSON 배열만 출력하세요. 설명 문구·마크다운·코드블록을 절대 붙이지 마세요. 응답의 첫 문자는 '[' 여야 합니다.
각 원소는 {"date":"YYYY-MM-DD","itemIds":["id1","id2"],"reason":"한 줄 이유(한국어)"} 형식입니다.
`;
}

function planWeeklyOutfitsRequestBody(prompt: string): unknown {
  return {
    contents: [{parts: [{text: prompt}]}],
    generationConfig: {
      temperature: 0.4,
      maxOutputTokens: 2000,
      responseMimeType: "application/json",
      thinkingConfig: {thinkingBudget: 0},
    },
  };
}

// 현재 옷장 규모(118벌) 기준 실제 요청 형태 - 7일 일정 + 피드백 5건.
// 측정값: textChars ≈ 11,539(카탈로그 10,093 + 일정 533 + 피드백
// 308 + 템플릿 boilerplate 605) - 상한 30,000의 약 38% - request_shape.ts
// 상단 주석의 추정치(10,000~12,000)와 방향이 맞는다(부분 확정 표기의
// 근거가 여기서 일부 회수된다 - 다만 이건 대표값 계산이지 실기기
// 실측은 아니다, §4-3 "전환 후 검증"에 실기기 실측 항목으로 등록).
const FIXTURE_PLAN_WEEKLY_OUTFITS = planWeeklyOutfitsRequestBody(
  buildPlanPrompt(buildWardrobeCatalog(118), buildScheduleLines(7), buildFeedbackSection(5))
);

const REAL_FIXTURES: Array<[string, unknown]> = [
  ["(a) 속성 추출", FIXTURE_EXTRACT_ATTRIBUTES],
  ["(b) 사이즈표 OCR", FIXTURE_SIZE_CHART_OCR],
  ["(c) 코디 분석(사진 기반)", FIXTURE_OUTFIT_ANALYSIS_WITH_PHOTO],
  ["(d) 코디 분석(프로필 기반, 사진 미첨부)", FIXTURE_OUTFIT_ANALYSIS_WITH_PROFILE],
  ["(e) 자기 평가", FIXTURE_SELF_EVALUATION],
  ["(f) 피팅", FIXTURE_FITTING_STEP],
  ["(g) 주간 플랜(현재 옷장 규모 118벌)", FIXTURE_PLAN_WEEKLY_OUTFITS],
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

// ── S3-c 재산정 상한(REQUEST_SHAPE_CONFIG 실제 값)의 경계값 ──────────
// 위 BOUNDARY_CONFIG는 판정 로직 자체를 빠르게 검증하기 위한 합성
// 값이었다 - 아래는 실제로 배포되는 상한(request_shape.ts 상단
// 주석의 재산정 근거 참고)의 경계에서 직접 검증한다. 한 번에 방식
// 가상 피팅(코드에 있으나 sequentialFittingEnabled=false일 때만
// 실행되는 경로)의 최댓값(parts=10, inline=9)이 새 상한 안에
// 들어오는지가 이 절의 핵심이다 - 이 경로는 S3-b 계측 창에 실행되지
// 않았으므로 실제 요청 형태 픽스처(위 REAL_FIXTURES)에는 없다.

function oneShotFittingFixture(clothingCount: number): unknown {
  // _generateFittingImageOneShot과 같은 뼈대: text 1 + inlineData
  // (전신 1 + 옷 clothingCount장).
  return {
    contents: [{
      parts: [
        {text: "다음 옷들을 순서대로 입혀주세요."},
        {inlineData: {mimeType: "image/jpeg", data: "AAAA"}}, // 전신 사진
        ...Array.from({length: clothingCount}, () => ({
          inlineData: {mimeType: "image/jpeg", data: "AAAA"},
        })),
      ],
    }],
    generationConfig: {responseModalities: ["IMAGE", "TEXT"]},
  };
}

run("실제 상한 — 한 번에 방식 피팅 최댓값(코디보드 8슬롯, parts=10/inline=9)은 통과한다", () => {
  const decision = evaluateRequestShape(oneShotFittingFixture(8), "image", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(decision.metrics.maxPartsInAnyContent, 10);
  assert.strictEqual(decision.metrics.inlineDataCount, 9);
  assert.strictEqual(decision.allowed, true, `violations: ${decision.violations.join(",")}`);
});

run("실제 상한 — maxContents 경계값(==3) 허용, 초과(==4) 거부", () => {
  const atLimit = {contents: [{parts: [{text: "x"}]}, {parts: [{text: "x"}]}, {parts: [{text: "x"}]}]};
  const overLimit = {
    contents: [{parts: [{text: "x"}]}, {parts: [{text: "x"}]}, {parts: [{text: "x"}]}, {parts: [{text: "x"}]}],
  };
  assert.strictEqual(evaluateRequestShape(atLimit, "text", REQUEST_SHAPE_CONFIG).allowed, true);
  const over = evaluateRequestShape(overLimit, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(over.allowed, false);
  assert.ok(over.violations.includes("contents_too_many"));
});

run("실제 상한 — maxPartsPerContent 경계값(==20) 허용, 초과(==21) 거부", () => {
  // inlineData만으로는 parts=20에 못 미쳐 도달한다(inline 상한 18이
  // parts 상한 20보다 먼저 걸린다) - text part로만 구성해 parts
  // 상한을 inline 상한과 독립적으로 검증한다.
  const atLimit = {contents: [{parts: Array.from({length: 20}, () => ({text: "x"}))}]};
  const overLimit = {contents: [{parts: Array.from({length: 21}, () => ({text: "x"}))}]};
  assert.strictEqual(evaluateRequestShape(atLimit, "image", REQUEST_SHAPE_CONFIG).allowed, true);
  const over = evaluateRequestShape(overLimit, "image", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(over.allowed, false);
  assert.ok(over.violations.includes("parts_too_many"));
});

run("실제 상한 — maxInlineDataCount 경계값(==18) 허용, 초과(==19) 거부", () => {
  const atLimit = oneShotFittingFixture(17); // 전신 1 + 옷 17 = inline 18
  const overLimit = oneShotFittingFixture(18); // inline 19
  assert.strictEqual(evaluateRequestShape(atLimit, "image", REQUEST_SHAPE_CONFIG).allowed, true);
  const over = evaluateRequestShape(overLimit, "image", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(over.allowed, false);
  assert.ok(over.violations.includes("inline_data_too_many"));
});

run("실제 상한 — maxTotalTextChars 경계값(==30000) 허용, 초과(==30001) 거부", () => {
  const atLimit = {contents: [{parts: [{text: "a".repeat(30_000)}]}]};
  const overLimit = {contents: [{parts: [{text: "a".repeat(30_001)}]}]};
  assert.strictEqual(evaluateRequestShape(atLimit, "text", REQUEST_SHAPE_CONFIG).allowed, true);
  const over = evaluateRequestShape(overLimit, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(over.allowed, false);
  assert.ok(over.violations.includes("text_too_long"));
});

// 위 경계값 테스트는 순수 텍스트("a" 반복)로 판정 로직 자체만 본다.
// 아래는 같은 경계를 **주간 플랜의 실제 와이어 형태**(generationConfig에
// responseMimeType/thinkingConfig 포함, contents 하나·parts 하나)로 다시
// 확인한다 - "이 상한은 이 경로를 위해 정해졌다"는 §4-4의 근거를 그
// 경로의 실제 형태로 직접 검증하기 위함이다. 템플릿 boilerplate 길이를
// 뺀 만큼만 카탈로그를 채워 총 글자 수를 정확히 경계에 맞춘다.
function planWeeklyOutfitsRequestOfExactLength(targetChars: number): unknown {
  const boilerplateLength = buildPlanPrompt("", "", "").length;
  const padLength = targetChars - boilerplateLength;
  if (padLength < 0) {
    throw new Error(`targetChars(${targetChars})가 템플릿 자체 길이(${boilerplateLength})보다 작다`);
  }
  const prompt = buildPlanPrompt("x".repeat(padLength), "", "");
  return planWeeklyOutfitsRequestBody(prompt);
}

run("실제 상한 — 주간 플랜 형태, maxTotalTextChars 경계값(==30000) 허용, 초과(==30001) 거부", () => {
  const atLimit = planWeeklyOutfitsRequestOfExactLength(30_000);
  const overLimit = planWeeklyOutfitsRequestOfExactLength(30_001);
  const atDecision = evaluateRequestShape(atLimit, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(atDecision.metrics.totalTextChars, 30_000);
  assert.strictEqual(atDecision.allowed, true, `violations: ${atDecision.violations.join(",")}`);
  const overDecision = evaluateRequestShape(overLimit, "text", REQUEST_SHAPE_CONFIG);
  assert.strictEqual(overDecision.metrics.totalTextChars, 30_001);
  assert.strictEqual(overDecision.allowed, false);
  assert.ok(overDecision.violations.includes("text_too_long"));
});

console.log("전부 통과");
