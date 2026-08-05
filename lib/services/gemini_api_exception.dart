class GeminiApiException implements Exception {
  final int statusCode;
  final String message;

  GeminiApiException(this.statusCode, this.message);

  // 503(모델 과부하)·429(요청 급증)는 잠시 후 재시도하면 성공할 가능성이
  // 높은 일시적 오류. 그 외(400/403 등)는 재시도해도 같은 결과라 바로 실패 처리.
  bool get isRetryable => statusCode == 503 || statusCode == 429;

  @override
  String toString() => 'Gemini API 오류: $message';
}

// 서버 프록시(callGeminiText) 호출량 상한 초과 — 재시도 대상이 아니다.
// GeminiApiException(429, ...)로 재구성하지 않는 이유: 그러면 isRetryable이
// true가 돼 withTextModelFallback/_withRetry가 대체 모델로 즉시 재시도하고,
// 그 재시도가 다시 카운트를 소모해 상한 소진을 오히려 가속한다. 이 타입은
// on TimeoutException/GeminiApiException/FormatException 중 어디에도 안
// 걸려 자동으로 재시도 없이 전파된다.
class RateLimitExceededException implements Exception {
  final String message;

  RateLimitExceededException(this.message);

  // toString()이 곧 사용자 안내 문구다 — 이 저장소는 fittingError = e.toString(),
  // _ErrorView(message: snapshot.error.toString()) 등 예외 표시를 toString()에
  // 의존하는 관례가 이미 확립돼 있다. 클래스명이 섞이지 않게 message를 그대로 낸다.
  @override
  String toString() => message;
}
