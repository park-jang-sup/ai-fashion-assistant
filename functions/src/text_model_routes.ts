// 텍스트 모델 경로 표 — docs/task_text_model_v1.md §4-0-a·2단계 결정 3.
//
// 클라이언트는 실제 모델명 대신 별칭(text-primary / text-fallback)을 보낸다.
// 서버가 이 표로 {provider, model}을 정하므로, 모델 전환은 이 표의 한 줄을
// 고치고 함수를 배포하는 것으로 끝난다 — APK를 다시 배포하지 않는다.
//
// - 이미 배포된 APK는 실제 모델명(gemini-3.5-flash, gemini-3.1-flash-lite)을
//   보낸다. 표에 없는 이름은 자기 자신(gemini)으로 풀리므로 그대로 동작한다.
// - 이미지 모델 요청은 무조건 gemini 자기 자신으로 푼다 — Claude로 가지 않는다.
// - 주 모델과 폴백은 서로 다른 제공자다(제공자 장애에도 앱이 동작하도록).
//   text_model_routes.test.ts가 이 성질을 고정한다.
//
// 이 함수는 화이트리스트(ALLOWED_MODELS) 검사를 통과한 이름에만 불린다.
import {PayloadKind} from "./payload_limit";

export type TextProvider = "gemini" | "claude";

export interface ModelRoute {
  provider: TextProvider;
  model: string;
}

export const TEXT_PRIMARY_ALIAS = "text-primary";
export const TEXT_FALLBACK_ALIAS = "text-fallback";

export const TEXT_MODEL_ROUTES: Readonly<Record<string, ModelRoute>> = {
  [TEXT_PRIMARY_ALIAS]: {provider: "claude", model: "claude-sonnet-5-5"},
  [TEXT_FALLBACK_ALIAS]: {provider: "gemini", model: "gemini-3.5-flash"},
};

export function resolveModelRoute(requested: string, kind: PayloadKind): ModelRoute {
  if (kind === "image") return {provider: "gemini", model: requested};
  return TEXT_MODEL_ROUTES[requested] ?? {provider: "gemini", model: requested};
}
