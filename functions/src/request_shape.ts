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

// [임시값 - S3-b 계측 후 확정, 임의 변경 금지 아님] 상한은 이번 커밋에서
// 의도적으로 느슨하게 둔다 - 근거 없는 값을 코드에 박고 잊는 것을 막기
// 위해, "실측 예상"(아래 각 줄 주석, gemini_service.dart를 읽고 추정한
// 값이지 계측한 값이 아니다)의 약 3~5배로만 잡는다. S3-b가 계측 로그로
// 실제 분포를 모으면 그 결과로 조인다 - payload_limit.ts의 상한이 실측
// 근거로 "확정"된 것과 달리, 이 값들은 그 단계에 아직 도달하지 못했다.
export const REQUEST_SHAPE_CONFIG: RequestShapeConfig = {
  // 실측 예상 1 - 우리 코드는 항상 contents 배열 원소 1개만 만든다
  // (gemini_service.dart의 모든 requestBody가 `'contents': [{...}]` 형태).
  maxContents: 5,
  // 실측 예상 10 - 한 번에 방식 가상 피팅(_generateFittingImageOneShot,
  // sequentialFittingEnabled=false일 때의 폴백 경로)이 text 1 +
  // inlineData 최대 9(코디보드 슬롯 8 + 전신 1, payload_limit.ts에 이미
  // 문서화된 값)로 parts를 만든다 - 현재 6종 픽스처 중 가장 큰 것(순차
  // 피팅 1단계)은 3이지만, 스키마는 호출부가 아니라 서버가 받는 요청
  // 형태를 재므로 이 폴백 경로도 커버해야 한다.
  maxPartsPerContent: 40,
  // 실측 예상 미측정 - S3-b의 1차 계측 대상. 넉넉히 잡아 정상 프롬프트
  // (사이즈표 OCR 지시문, 코디 분석의 옷장 카탈로그·이력 텍스트 등)가
  // 걸리지 않게 한다.
  maxTotalTextChars: 50_000,
  // 실측 예상 9 - maxPartsPerContent와 같은 근거(코디보드 슬롯 8 + 전신 1).
  maxInlineDataCount: 30,
};
