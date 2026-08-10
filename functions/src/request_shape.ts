// 프록시(callGeminiText) 요청 본문 형태 판정 — 순수 함수로 분리해 단위
// 테스트한다(rate_limit.ts/payload_limit.ts/signed_url_policy.ts와 같은
// 검증 원칙). index.ts는 model만 화이트리스트로 검사하고 requestBody는
// object이기만 하면 무가공으로 Gemini에 중계한다(index.ts:239-243) —
// 인증만 통과하면 임의의 프롬프트를 우리 API 키로 실행하는 범용 LLM
// 릴레이가 된다. 이 모듈은 그 requestBody가 "우리 앱이 실제로 만드는
// 형태"인지만 판정한다.
//
// S2(App Check)가 보류된 상태이므로(docs/task_hardening_v2.md §3-1-3)
// 이 판정은 심층 방어가 아니라 **현재 유일한 방어**다(§4 서두 정정). 이
// 파일(S3-a)은 판정 로직과 테스트만 다룬다 — index.ts 배선은 S3-b에서
// 한다. 둘을 나누는 이유는 판정 로직을 실호출 경로와 무관하게 먼저
// 검증하기 위함이다.

import {RateLimitKind} from "./rate_limit";

export type RequestShapeViolation =
  | "top_level_unknown_key"
  | "contents_missing"
  | "contents_not_array"
  | "contents_too_many"
  | "part_unknown_key"
  | "parts_too_many"
  | "text_too_long"
  | "inline_data_too_many"
  | "inline_data_bad_mime";

export interface RequestShapeConfig {
  maxContents: number;
  maxPartsPerContent: number;
  maxTotalTextChars: number;
  maxInlineDataCount: number;
}

export interface RequestShapeMetrics {
  contentsCount: number;
  maxPartsInAnyContent: number;
  totalTextChars: number;
  inlineDataCount: number;
}

export interface RequestShapeDecision {
  allowed: boolean;
  violations: RequestShapeViolation[];
  metrics: RequestShapeMetrics;
}

// top-level에서 허용하는 키. 우리 앱(gemini_service.dart)이 실제로
// 만드는 requestBody는 이 넷만 쓴다 - contents/generationConfig는
// 모든 호출에 있고, safetySettings/systemInstruction은 현재 코드에서
// 안 쓰지만 Gemini API 표준 필드라 향후 정당한 확장 여지로 열어둔다.
//
// tools/toolConfig/cachedContent는 명시적으로 막는다 - 특히 tools를
// 막는 이유: 함수 호출(function calling)이나 코드 실행 도구를 붙이면
// 프록시가 "우리가 만든 프롬프트를 텍스트/이미지로 바꾸는 중계기"를
// 넘어서, 모델이 임의 함수를 "호출하려는 의도"를 반환하거나 코드를
// 실행하는 통로가 된다 - 우리 API 키로 도는 범용 에이전트 프록시가
// 되는 것과 같다. 이 프록시가 막으려는 것이 정확히 그것이다.
const ALLOWED_TOP_LEVEL_KEYS = new Set([
  "contents",
  "generationConfig",
  "safetySettings",
  "systemInstruction",
]);

// parts 내부에서 허용하는 키 - 우리 앱은 텍스트 프롬프트(text)와 옷/사진
// 이미지(inlineData)만 보낸다. fileData(Storage 직접 참조), functionCall/
// functionResponse(도구 호출 왕복)는 전부 우리 코드에 없다.
const ALLOWED_PART_KEYS = new Set(["text", "inlineData"]);

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function pushOnce(violations: RequestShapeViolation[], v: RequestShapeViolation): void {
  if (!violations.includes(v)) violations.push(v);
}

// kind는 이번 커밋(S3-a)에서 판정 분기에 쓰지 않는다 - S3-b가 계측
// 로그에 kind를 함께 남겨 "어느 호출 종류에서 어떤 위반이 나오는지"를
// 집계하기 위해 시그니처에 미리 반영해 둔다(index.ts의 checkAndRecordRateLimit/
// evaluatePayloadLimit이 kind를 판정 축으로 쓰는 것과 같은 재사용
// 타입이지만, 이 판정 자체는 지금 kind와 무관하게 전부 같은 config를
// 적용한다 - config를 kind별로 나누는 것은 실측 이후의 일이다).
//
// 이 함수는 예외를 던지지 않는다 - 입력이 무엇이든(null/undefined/문자열/
// 숫자/배열/빈 객체) 위반 목록을 반환하고 정상 종료한다. 호출부의
// try/catch에 기대지 않고 함수 자체가 총체적이어야 한다 - 계측 진입점이
// 서버의 fail-open 원칙을 상속받지 못해 정상 요청까지 막을 뻔했던 사고
// (5.21.7절)를 스키마 검증에서 반복하지 않기 위함이다.
export function evaluateRequestShape(
  body: unknown,
  kind: RateLimitKind,
  config: RequestShapeConfig
): RequestShapeDecision {
  const violations: RequestShapeViolation[] = [];
  const metrics: RequestShapeMetrics = {
    contentsCount: 0,
    maxPartsInAnyContent: 0,
    totalTextChars: 0,
    inlineDataCount: 0,
  };

  if (!isPlainObject(body)) {
    // null/undefined/문자열/숫자/배열 - contents를 둘 자리 자체가 없다.
    violations.push("contents_missing");
    return {allowed: false, violations, metrics};
  }

  for (const key of Object.keys(body)) {
    if (!ALLOWED_TOP_LEVEL_KEYS.has(key)) {
      pushOnce(violations, "top_level_unknown_key");
    }
  }

  const contents = body["contents"];
  if (contents === undefined) {
    violations.push("contents_missing");
    return {allowed: false, violations, metrics};
  }
  if (!Array.isArray(contents)) {
    violations.push("contents_not_array");
    return {allowed: false, violations, metrics};
  }

  metrics.contentsCount = contents.length;
  if (contents.length > config.maxContents) {
    violations.push("contents_too_many");
  }

  for (const content of contents) {
    if (!isPlainObject(content)) continue; // 형태가 아예 다르면 부분 집계만 건너뛴다 - 예외는 안 던진다.
    const parts = content["parts"];
    if (!Array.isArray(parts)) continue;

    metrics.maxPartsInAnyContent = Math.max(metrics.maxPartsInAnyContent, parts.length);
    if (parts.length > config.maxPartsPerContent) {
      pushOnce(violations, "parts_too_many");
    }

    for (const part of parts) {
      if (!isPlainObject(part)) continue;

      for (const key of Object.keys(part)) {
        if (!ALLOWED_PART_KEYS.has(key)) {
          pushOnce(violations, "part_unknown_key");
        }
      }

      if (typeof part["text"] === "string") {
        metrics.totalTextChars += part["text"].length;
      }

      if (part["inlineData"] !== undefined) {
        metrics.inlineDataCount++;
        const inlineData = part["inlineData"];
        const mimeType = isPlainObject(inlineData) ? inlineData["mimeType"] : undefined;
        if (typeof mimeType !== "string" || !mimeType.startsWith("image/")) {
          pushOnce(violations, "inline_data_bad_mime");
        }
      }
    }
  }

  if (metrics.totalTextChars > config.maxTotalTextChars) {
    violations.push("text_too_long");
  }
  if (metrics.inlineDataCount > config.maxInlineDataCount) {
    violations.push("inline_data_too_many");
  }

  return {allowed: violations.length === 0, violations, metrics};
}

// [확정값 - S3-c, 2026-08-11, docs/task_hardening_v2.md §4-4 재산정
// 절차의 결과] S3-b 계측(릴리스 빌드, 5경로 + 순차 피팅 최대 7벌)의
// 실측 최댓값은 다음과 같았다 - contents=1, maxParts=3(피팅 1단계:
// text+이미지 2장), textChars=2745(코디 분석·프로필 기반), inline=2
// (피팅 1단계). 이 값들 자체를 상한으로 쓰지 않는다 - 아래 각 줄에
// 적은 대로, 코드에 존재하지만 이번 계측 창에서 실행되지 않은 두
// 경로(한 번에 방식 가상 피팅, 주간 플랜)의 요구치가 이 실측 최댓값을
// 넘기 때문이다. 상한은 "이번에 관측된 값"이 아니라 "코드가 만들 수
// 있는 값"을 기준으로 잡는다 - 실측은 그 기준이 맞는지 검증하는
// 용도로만 썼다(아래 6종 픽스처 재통과 확인).
export const REQUEST_SHAPE_CONFIG: RequestShapeConfig = {
  // 코드 근거(확정): 1 - gemini_service.dart의 모든 requestBody가
  // `'contents': [{...}]` 형태이며 배열 길이가 1을 넘는 경로가 코드에
  // 없다(S3-b 실측도 전 요청 contents=1로 일치). 값 자체가 항상
  // 상수라 배수를 곱하는 의미가 약해, 여유는 배수가 아니라 고정
  // 여유폭(+2)으로 둔다 - 배수를 곱하면(예: ×5) 이 필드만 부풀려져
  // 다른 상한과 근거의 성격이 달라 보이는 것을 피한다.
  maxContents: 3,
  // 코드 근거(확정, 미실행 경로 포함): 한 번에 방식 가상 피팅
  // (_generateFittingImageOneShot, sequentialFittingEnabled=false일
  // 때의 폴백 경로, 2026-08-11 재확인)이 최댓값을 만든다 - text 1 +
  // inlineData 최대 9(코디보드 8슬롯 + 전신 1). 슬롯 수는
  // main.dart:173-182의 `_fittingItems` 맵 키(아우터/상의/하의/신발/
  // 모자/가방/시계/팔찌, 8개)로 직접 재확인했다 - payload_limit.ts가
  // 이미 인용한 값과 독립적으로 일치. 코드 최댓값 = 1+9 = 10.
  // 여유 배수 ×2 = 20. 배수 근거: 슬롯이 늘어나는 방향의 향후 변경
  // (코디보드 확장)을 흡수하되, 근거 없이 크게 벌리지 않는다 - 관측
  // 최댓값(3, 순차 피팅 1단계)의 3~5배가 아니라 **코드가 만들 수 있는
  // 값의 2배**라는 점이 payload_limit.ts와 같은 원칙("이론상 최악"
  // 기준)이다.
  maxPartsPerContent: 20,
  // [부분 확정 - 추정치 포함] 실측 최댓값(2745, 코디 분석·프로필
  // 기반)은 이번 창에서 시도하지 않은 `planWeeklyOutfits`(주간 플랜,
  // agent_planner.dart:705-707)를 포함하지 않는다 - 이 함수는 옷장
  // 전체를 한 줄씩(`- id=<20자 id> | <카테고리> | <속성 요약>`) 프롬프트에
  // 싣는다. 이 저장소가 반복 인용해 온 데모 옷장 규모(118벌) 기준으로
  // 줄당 약 55~60자 × 118 ≈ 6,500~7,000자, 일정·이력·프롬프트
  // 지시문을 더하면 약 10,000~12,000자로 추정한다(코드를 읽고
  // 추정한 값 - payload_limit.ts처럼 실제 바이트를 잰 것이 아니다,
  // 그래서 "부분 확정"). 옷장 규모 자체에 코드 상한이 없어 이 추정도
  // 상한일 뿐 절대치는 아니다. 추정 최댓값(~12,000) × 여유 배수
  // ×2.5 ≈ 30,000. 배수를 크게 잡은 이유: 이 값만 측정이 아니라
  // 추정이므로, 다른 필드(측정 기반, ×2)보다 여유를 더 둔다.
  maxTotalTextChars: 30_000,
  // 코드 근거(확정, 미실행 경로 포함): maxPartsPerContent와 같은
  // 근거(코디보드 8슬롯 + 전신 1 = 9). 여유 배수 ×2 = 18 - 같은
  // 원칙(코드 최댓값의 2배).
  maxInlineDataCount: 18,
};

// [정정 2026-08-11, S3-c] 위 maxPartsPerContent/maxInlineDataCount는
// 사실상 "한 번에 방식 가상 피팅이 한 요청에 넣을 수 있는 옷 개수"의
// 서버측 상한이 된다 - 코드(_generateFittingImageOneShot)에는 옷
// 개수 자체를 제한하는 검사가 없고, 유일한 제약은 클라이언트 UI의
// 코디보드 슬롯 수(main.dart:173-182, 8개)뿐이었다. 즉 이 계측
// 작업(S3) 이전에는 "옷 몇 벌까지 한 번에 피팅할 수 있는가"를 UI가
// 단독으로 결정하고 있었고, 서버는 그 수를 검증할 수단이 없었다.
// 이번 상한 재산정으로 서버도 "코디보드 슬롯 수(8)에 맞춘 여유
// (슬롯 20/18 상당)"라는 사실상의 상한을 갖게 되었다 - **의도한
// 설계는 아니었다**(옷 개수 상한이 원래 목적이 아니라 요청 형태
// 검증이 목적이었다). 코디보드 슬롯 수가 늘어나면(예: 8 → 12) 이
// 상한도 함께 검토해야 한다는 점을 별도 항목으로 등록한다 -
// docs/task_hardening_v2.md §4-4 참고. 현재 순차 피팅(기본값,
// sequentialFittingEnabled=true)은 이 상한과 무관하다 - 매 요청이
// 항상 이미지 2장(현재 사진 + 옷 1장)만 보내므로 옷 벌 수가 늘어도
// 이 필드들의 값이 커지지 않는다(2026-08-11 S3-c 실측, 7벌까지
// 확인 - 모든 순차 피팅 단계에서 inline=2로 일정).
