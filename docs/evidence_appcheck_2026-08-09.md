# App Check 검증 실패 로그 원문 — S2-a 계측 배선 이전

## 메타데이터 (docs/task_hardening_v2.md §3-2 참고용)

- **수집 시각**: 2026-08-10 (S2-a 계측 배선 커밋 `6cb716c` 배포 직후,
  실기기 (a)~(e) 실행 **이전**. 조회 명령: `firebase functions:log
  --project ai-fashion-assistant-personal -n 1000`, 결과를 로컬 파일로
  저장한 뒤 아래 세 패턴으로 필터링:
  - `Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed.`
  - `{"verifications":{"auth":"VALID","app":"INVALID"}, ...}` (필드 순서는 라인마다 다름)
  - `Allowing request with invalid AppCheck token because enforcement is disabled`
- **관측된 함수**: `callGeminiText`(50건), `getSignedImageUrls`(56건),
  `beginFittingAttempt`(4건). `generateFittingImage`/`sendTestPush`/
  `triggerScheduledCheckTest`는 이 조회 창에 해당 패턴이 없었다 — "이
  함수들은 문제가 없다"는 뜻이 아니라 "이 조회 창에 해당 함수 호출
  자체가 없었다"는 뜻이다(구분해서 읽을 것).
- **관측 날짜**: 2026-08-09T04:46:56Z ~ 2026-08-10T04:23:38Z(마지막
  라인은 S2-a 배포 완료 시각 2026-08-10T04:59:55Z **이전**).
- **이 로그는 S2-a 계측 배선(커밋 `6cb716c`, `[appCheck] fn=...
  hasApp=...`) 이전의 것이다.** 즉 우리 커스텀 로그가 아니라
  firebase-functions v2 프레임워크가 onCall 요청을 처리하며 자체적으로
  찍는 App Check 검증 로그다 — 우리가 배선하기 전부터, 정상적인 실사용
  중에 이미 이 패턴이 반복되고 있었다는 근거다.
- **휘발성 경고**: 이 증거는 재현 불가능하다. Cloud Logging의 보존
  기간과 `firebase functions:log`의 조회 창(최근 N줄) 때문에, 실기기
  (a)~(e) 실행 이후 새 로그가 쌓이면 아래 원문과 같은 라인을 다시 볼 수
  없을 가능성이 높다. 그래서 요약이 아니라 원문 그대로 남긴다.

## 부가 관측 — "MISSING"과 "INVALID"는 다른 상태다 (163~165행)

아래 원문 163~165행(`2026-08-09T05:10:17~19Z`, `callgeminitext`)은 위
세 패턴과 다른 문구다:

```
{"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
```

이 세 줄은 `auth` 토큰 자체가 거부된 별개 사고(익명 인증 세션 만료
등으로 추정, 이 문서의 범위 밖)이지만, `verifications.app` 필드가
**`"INVALID"`가 아니라 `"MISSING"`**으로 나온다는 점이 중요하다 —
프레임워크 자신의 로그는 "토큰이 아예 없었다"(MISSING)와 "토큰은
왔으나 유효하지 않았다"(INVALID)를 **이미 구분하고 있다.** 우리
계측(`request.app != null` 단일 판정)은 이 구분을 못 한다는 것이
§3-3에 등록한 해석 규칙의 근거를 한 번 더 뒷받침한다.

## 원문 전체 (333줄, 시각순)

```
2026-08-09T04:46:56.879039Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:46:56.879146Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:46:56.879182Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:46:57.325233Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:46:57.325324Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:46:57.325365Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:46:57.401275Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:46:57.401343Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:46:57.401379Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:10.365363Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:10.365424Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:10.365462Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:10.920043Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:10.920099Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:10.920149Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:11.240190Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:11.374745Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:47:11.374828Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:13.841369Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:14.005918Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:14.006077Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:20.411139Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:20.411195Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:47:20.411244Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:20.921986Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:20.922187Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:47:20.922287Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:20.960771Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:20.960832Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:47:20.960871Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:30.586337Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:30.586420Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:30.586460Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:31.038226Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:31.038439Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:31.038520Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:31.087669Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:31.087727Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:47:31.087764Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:41.925700Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:41.925783Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:41.925822Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:42.351635Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:42.351846Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:47:42.351915Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:42.489364Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:42.489456Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:47:42.489515Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:55.448294Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:55.448369Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:55.448406Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:56.005561Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:56.005761Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:47:56.005827Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:47:56.125113Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:47:56.125177Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:47:56.125215Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:49:33.333728Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:49:33.333792Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:49:33.333832Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:49:33.601091Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:49:33.601180Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:49:33.601190Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:49:34.121520Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:49:34.121672Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:49:34.121738Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:49:47.757990Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:49:47.758097Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:49:47.758121Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:49:48.295376Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:49:48.295457Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:49:48.295503Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:49:48.560799Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:49:48.560937Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:49:48.560995Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:06.214928Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:06.214972Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:50:06.214985Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:06.767247Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:06.767303Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:06.767344Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:06.979271Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:06.979413Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:06.979460Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:17.356228Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:17.356283Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:50:17.356330Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:17.850157Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:17.850266Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:50:17.850318Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:17.929652Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:17.929857Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:17.929917Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:29.441199Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:29.441263Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:29.441292Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:29.896758Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:29.896964Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:29.897161Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:29.967970Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:29.968062Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:29.968097Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:45.622733Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:45.622824Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:50:45.622861Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:46.240393Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:46.240502Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:46.240558Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:50:46.409860Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:50:46.409994Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:50:46.410045Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:51:08.072921Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:51:08.072994Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:51:08.073008Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:51:08.618687Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:51:08.618714Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:51:08.618761Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:51:08.863465Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:51:08.863594Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:51:08.863647Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:52:00.725095Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:52:00.725250Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:52:00.725266Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:52:00.735498Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:52:00.735615Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:52:00.735666Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:53:00.701908Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:53:00.702024Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:53:00.702073Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:55:03.050255Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:55:03.050317Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:55:03.050374Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:55:03.156095Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:55:03.156242Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:55:03.156296Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:55:15.407749Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:55:15.407854Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:55:15.407917Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:55:15.576845Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:55:15.576971Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:55:15.577013Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:56:16.031348Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:56:16.031487Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:56:16.031565Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:57:52.629999Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:57:52.630224Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:57:52.630309Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:57:52.680412Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:57:52.680513Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:57:52.680563Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:58:34.331888Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:58:34.332061Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T04:58:34.332111Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:58:34.337514Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:58:34.337601Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:58:34.337659Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:58:45.518335Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:58:45.518453Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T04:58:45.518513Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T04:58:46.186269Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T04:58:46.186385Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T04:58:46.186444Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T05:10:17.916886Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
2026-08-09T05:10:18.226744Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
2026-08-09T05:10:19.180215Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
2026-08-09T16:12:07.367550Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:12:07.499501Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:12:07.499622Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:12:08.100450Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:12:08.100649Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:12:08.100736Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:12:11.019926Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:12:11.020442Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:12:11.020675Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:12:17.180675Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:12:17.180816Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:12:17.180881Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:13:07.743934Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:13:07.904947Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:13:07.905088Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:13:08.270499Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:13:08.270770Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:13:08.271040Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:13:40.168125Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:13:40.168270Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:13:40.168379Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:13:40.383636Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:13:40.383827Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:13:40.383927Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:14:09.014654Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:14:09.014822Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:14:09.014897Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:14:09.027012Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:14:09.027153Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:14:09.027217Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:16:27.179099Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:16:27.179383Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:16:27.179468Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:16:27.204460Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:16:27.204637Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:16:27.204706Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:29.742811Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:29.742947Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:27:29.742988Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:32.413893Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:32.414002Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:27:32.414069Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:36.128942Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:36.129026Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:27:36.129070Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:38.888227Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:38.888383Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:27:38.888432Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:41.235291Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:41.235379Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:27:41.235421Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:56.465596Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:56.465924Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:27:56.465985Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:27:57.836148Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:27:57.836262Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:27:57.836308Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:28:03.859735Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:28:03.860013Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:28:03.860105Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:28:05.066076Z W beginfittingattempt: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:28:05.236223Z W beginfittingattempt: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:28:05.236330Z W beginfittingattempt: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:28:06.479694Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:28:06.480054Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:28:06.480152Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:28:25.281770Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:28:25.281990Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:28:25.282066Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:28:28.925148Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:28:28.925327Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:28:28.925366Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:28:43.358511Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:28:43.358733Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:28:43.358770Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:24.990650Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:24.990736Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:24.990770Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:25.109578Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:25.109675Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:25.109726Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:25.725536Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:25.725617Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:25.725671Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:27.600070Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:27.600221Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:27.600263Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:30.342197Z W beginfittingattempt: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:30.342488Z W beginfittingattempt: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:29:30.342579Z W beginfittingattempt: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:30.548019Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:30.548223Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:30.548285Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:31.114306Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:31.114491Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:31.114556Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:47.688577Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:47.688744Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:29:47.688813Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:47.718778Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:47.718938Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:47.718973Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:47.867160Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:47.867221Z W getsignedimageurls: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:29:47.867274Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:29:48.177059Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:29:48.177162Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:29:48.177190Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:33.947684Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:33.947776Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:40:33.947815Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:36.462326Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:36.462471Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:40:36.462519Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:39.389495Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:39.389599Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:40:39.389641Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:40.315494Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:40.315576Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:40:40.315620Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:43.528100Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:43.528184Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:40:43.528310Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:45.287819Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:45.287893Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"auth":"VALID","app":"INVALID"}}
2026-08-09T16:40:45.287929Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:46.207932Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:46.208056Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:40:46.208111Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:46.312857Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:46.312950Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:40:46.312977Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:50.992391Z W beginfittingattempt: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:50.992530Z W beginfittingattempt: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-09T16:40:50.992645Z W beginfittingattempt: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:51.267089Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:51.267258Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:40:51.267327Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:40:52.004047Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:40:52.004168Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:40:52.004230Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:41:00.029111Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:41:00.029254Z W callgeminitext: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:41:00.029303Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-09T16:41:14.285866Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-09T16:41:14.286050Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-09T16:41:14.286119Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:22:41.699922Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:22:41.906744Z W getsignedimageurls: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-10T04:22:41.907018Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:22:44.089274Z W getsignedimageurls: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:22:44.089544Z W getsignedimageurls: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-10T04:22:44.089666Z W getsignedimageurls: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:23:08.859761Z W beginfittingattempt: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:23:08.985302Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:23:09.035273Z W beginfittingattempt: {"verifications":{"app":"INVALID","auth":"VALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-10T04:23:09.035452Z W beginfittingattempt: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:23:09.120069Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-10T04:23:09.120254Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:23:10.244108Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:23:10.244410Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-10T04:23:10.244508Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:23:21.848647Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:23:21.848830Z W callgeminitext: {"verifications":{"auth":"VALID","app":"INVALID"},"message":"Callable request verification failed: AppCheck token was rejected."}
2026-08-10T04:23:21.848920Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
2026-08-10T04:23:38.205753Z W callgeminitext: Failed to validate AppCheck token. FirebaseAppCheckError: Decoding App Check token failed. Make sure you passed the entire string JWT which represents the Firebase App Check token.
2026-08-10T04:23:38.205975Z W callgeminitext: {"message":"Callable request verification failed: AppCheck token was rejected.","verifications":{"app":"INVALID","auth":"VALID"}}
2026-08-10T04:23:38.206047Z W callgeminitext: Allowing request with invalid AppCheck token because enforcement is disabled
```
