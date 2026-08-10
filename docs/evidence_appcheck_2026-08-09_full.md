# App Check 검증 로그 원문 — 전수 재수집(편향 없는 필터)

## 이 파일의 위치

`docs/evidence_appcheck_2026-08-09.md`(최초 수집분)는 문자열 `INVALID`가
라인에 있어야 걸리는 필터로 333줄을 모았고, 그 결과 `MISSING`+`auth:VALID`
조합("Callable request verification passed", D 레벨, 조용히 통과)이
필터에 걸리지 않아 **체계적으로 누락되었다.** 이 파일은 그 편향을
없앤 필터(`AppCheck` 또는 `Callable request verification` 문자열 포함
— 어떤 검증 결과인지에 의존하지 않는다)로 같은 원본을 다시 훑은
**전수본**이다.

- **수집 시각**: 2026-08-10, 최초 수집과 같은 세션·같은 원본
  (`firebase functions:log -n 1000` 결과, 1869줄, 2026-08-09T04:46 ~
  2026-08-10T05:00). 원본 자체를 다시 조회하지 않았다 — 같은 원본을
  다른 필터로 다시 훑은 것이므로 새 데이터가 섞이지 않았다.
- **필터**: `grep -E "AppCheck|Callable request verification"` — 상태
  이름(`INVALID`/`MISSING`/`VALID`/`passed`/`rejected`)에 의존하지
  않는다. 이 필터도 `AppCheck`/`verification` 문자열 자체에 의존하는
  한계는 있으나(예: 전혀 다른 문구로 로그가 났다면 여전히 놓친다),
  최소한 "찾으려는 상태의 이름"에 의존하던 최초 필터의 편향은 없앴다.
- **결과**: 367줄. `Failed to validate AppCheck token` 110 +
  `Allowing request with invalid AppCheck token` 110 +
  `"message":"Callable request verification failed: AppCheck token was
  rejected."` 110(위 110과 같은 사건의 세 번째 줄) +
  `"message":"Callable request verification passed"` 29 +
  `"message":"...Auth token was rejected."` 8 = 367.

## 왜 이 사건 자체를 기록하는가 — 증거 수집 층위에서 재발한 패턴

**증거 수집 필터가 찾으려는 상태의 이름에 의존해, 다른 상태를
구조적으로 못 보게 만들었다.** 이것은 이 저장소에서 이미 여러 층위
에서 반복된 패턴과 같은 형태다:

- 논문 5.8절 — 코드가 실행되지 않는 경로(도달 불가능한 코드가 존재를
  숨긴다).
- 논문 5.15절 — 이관 과정에서 도달 경로가 소실된다(검토 단위가
  갈라진다).
- `task_hardening_v2.md` §3-3-1 — 계측(`hasApp` 단일 불리언)이
  `INVALID`와 `MISSING`을 같은 값으로 뭉갠다.
- **이 파일 — 증거 수집(grep 필터)이 `MISSING`+`VALID`("passed") 조합
  전체를 구조적으로 못 보게 만들었다.**

네 층위(실행·이관·계측·수집) 모두 같은 구조다: **어떤 상태를 찾도록
설계된 장치는 그 상태의 이름을 알아야 작동하고, 이름을 모르는(또는
다르게 표현되는) 상태는 장치의 시야 밖에 남는다.** 이번 사례가
특히 날카로운 이유는, 편향의 방향이 우리 가설과 **반대**였다는
점이다 — 최초 수집은 축2가 원래 찾던 `MISSING`을 과소평가하고
`INVALID`만 과대평가하는 쪽으로 편향돼 있었다.

## 값별 · 함수별 · 시각별 재확인 (편향 정정, 위 §3-2/§3-3-1의 표와 동일한 수치)

이 전수본으로 다시 집계한 값은 이전에 이미 등록한 표(`task_hardening_v2.md`
§3-2 "배선 이전 증거", §3-3-1)와 **일치한다** — 즉 이전 집계가
결과적으로 옳았던 것은, 그 집계를 만들 때 이미 한 번 전체 원본
(`raw_functions_log.txt`, 1869줄)으로 돌아가 다시 셌기 때문이다.
이 파일은 그 재집계의 **원문 근거**를 처음으로 보존하는 파일이다
(이전 재집계는 수치만 문서에 옮기고 원문 자체는 남기지 않았었다).

| `verifications.app` | 건수 | 비고 |
|---|---|---|
| `INVALID` | 110 | `callGeminiText` 50 / `getSignedImageUrls` 56 / `beginFittingAttempt` 4 |
| `MISSING`(auth VALID, 조용히 통과) | 29 | `callGeminiText` 22 / `beginFittingAttempt` 7 / `getSignedImageUrls` 0 |
| `MISSING`(auth도 INVALID, 별개 사고) | 8 | 전부 `callGeminiText`, 08-09 05:10:17~19Z 2초 안에 몰림 |
| `VALID` | 0 | 이 조회 창(1869줄) 전체에 없음 |

**추가 관측(이 재집계에서 새로 눈에 띈 것)**: `beginFittingAttempt`의
`MISSING` 7건(192~198행)은 **2026-08-09T15:56:13.6 ~ 15:56:17.9,
약 4.4초 안에 전부 몰려 있다.** 순차 피팅 1회는 `beginFittingAttempt`를
**한 번만** 호출하므로(코드 주석 확인, `gemini_service.dart:143-149`),
이 7건은 서로 다른 7번의 피팅 시도이거나 같은 세션 안에서 반복
호출된 것이다. 이 4.4초라는 짧은 창은 `docs/task_hardening_v2.md`
§3-3-2(경쟁 가설 H1/H2)의 판별 대상이므로 여기서는 관측만 기록하고
해석은 그쪽에 둔다.

## 원문 전체 (367줄, 시각순, 편향 없는 필터)

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
2026-08-09T05:06:58.648569Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T05:07:08.975775Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"app":"MISSING","auth":"VALID"}}
2026-08-09T05:10:17.604425Z W callgeminitext: {"verifications":{"auth":"INVALID","app":"MISSING"},"message":"Callable request verification failed: Auth token was rejected."}
2026-08-09T05:10:17.916886Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
2026-08-09T05:10:18.226744Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
2026-08-09T05:10:18.583542Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"auth":"INVALID","app":"MISSING"}}
2026-08-09T05:10:18.852085Z W callgeminitext: {"verifications":{"auth":"INVALID","app":"MISSING"},"message":"Callable request verification failed: Auth token was rejected."}
2026-08-09T05:10:19.180215Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"app":"MISSING","auth":"INVALID"}}
2026-08-09T05:10:19.533629Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"auth":"INVALID","app":"MISSING"}}
2026-08-09T05:53:54.147868Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"app":"MISSING","auth":"VALID"}}
2026-08-09T05:55:58.419785Z D callgeminitext: {"verifications":{"app":"MISSING","auth":"VALID"},"message":"Callable request verification passed"}
2026-08-09T05:56:09.402446Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T05:57:09.677752Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"app":"MISSING","auth":"VALID"}}
2026-08-09T05:58:47.154745Z D callgeminitext: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T05:58:57.051652Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T06:00:30.940869Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T12:05:42.011093Z W callgeminitext: {"message":"Callable request verification failed: Auth token was rejected.","verifications":{"auth":"INVALID","app":"MISSING"}}
2026-08-09T12:07:00.640838Z D callgeminitext: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T12:52:36.659449Z D callgeminitext: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T12:53:08.607525Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"app":"MISSING","auth":"VALID"}}
2026-08-09T12:53:28.460357Z D callgeminitext: {"verifications":{"app":"MISSING","auth":"VALID"},"message":"Callable request verification passed"}
2026-08-09T12:53:52.160463Z D callgeminitext: {"verifications":{"app":"MISSING","auth":"VALID"},"message":"Callable request verification passed"}
2026-08-09T12:55:05.427004Z D callgeminitext: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T15:19:56.278245Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"app":"MISSING","auth":"VALID"}}
2026-08-09T15:20:14.058819Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"app":"MISSING","auth":"VALID"}}
2026-08-09T15:20:26.126746Z D callgeminitext: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T15:20:51.850149Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T15:21:06.571814Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T15:22:23.349525Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T15:56:13.610857Z D beginfittingattempt: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T15:56:14.875790Z D beginfittingattempt: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T15:56:15.446269Z D beginfittingattempt: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T15:56:16.055832Z D beginfittingattempt: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T15:56:16.652864Z D beginfittingattempt: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
2026-08-09T15:56:17.254968Z D beginfittingattempt: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
2026-08-09T15:56:17.885318Z D beginfittingattempt: {"verifications":{"auth":"VALID","app":"MISSING"},"message":"Callable request verification passed"}
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
2026-08-09T16:26:17.770642Z D callgeminitext: {"message":"Callable request verification passed","verifications":{"auth":"VALID","app":"MISSING"}}
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
