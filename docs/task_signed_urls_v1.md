# 서명 URL 이행 v1 — 만료 있는 이미지 접근 (천장 1-2)

작성 2026-08-05. 근거: 논문 5.13.2("이미 발급된 주소는 규칙을 어떻게
바꾸어도 계속 열린다 — 근본 해법은 만료 있는 서명 주소이며 서버 계층을
전제한다"), 7.1 "발급된 주소의 회수 불가". 서버 계층은 3.11절로 마련됨.

**한 줄 요약**: 이미지 접근을 "영구 다운로드 토큰 URL"에서 "문서 ID
기반 소유권 검사 후 발급되는 단기 서명 URL"로 이행한다. 신규 발급 →
기존 문서 백필 → 토큰 회수의 3단계이며, **회수(Phase C)만이 구멍을
실제로 닫는 단계**이고 앞 두 단계는 그 전제를 만든다.

---

## 0. 원칙 재확인

- 단계마다 커밋·검증, 기본 비활성 도입(킬 스위치), 실패 방향은 보수적.
- 엔진·매칭·계측 3단 깔때기 무관 — 건드리지 않는다.
- 실데이터 삭제 금지. Phase C의 토큰 메타데이터 제거는 파일 삭제가
  아니다 — 파일·문서는 전부 보존된다.
- firebase deploy / flutter build / adb install 은 사용자 확인 후.
  adb uninstall 금지.

## 1. 손대면 안 되는 것

1. `storage.rules`의 쓰기 경로(업로드·삭제) — 이 작업은 읽기 경로만
   다룬다. isValidImage와 용량 제한은 그대로.
2. 파일의 물리 위치 — 어떤 Phase에서도 Storage 객체를 이동·복사·삭제
   하지 않는다(버킷 루트 잔재 9건 포함 — §8 판단 대기).
3. `fitting_cache`의 캐시 키 체계(SHA-256) — 경로 유도에 그대로 쓴다.
4. Firestore 문서의 기존 URL 필드 — Phase B에서도 **덮어쓰지 않고 path
   필드를 추가**한다. URL 필드 제거는 Phase C 완료 후 별도 판단.

## 2. 배경 — 무엇이 왜 뚫려 있는가 (5.13.2 요약)

- `getDownloadURL()`이 반환하는 주소는 질의 문자열의 토큰으로 규칙
  평가를 우회한다. 화면의 이미지 로드는 이 절대 URL의 일반 HTTP GET
  이므로 **읽기는 처음부터 규칙 밖**이다.
- 파일명 난수화(5.13.1)가 경로 추측은 막았으나, **이미 발급·유출된
  주소는 영구히 열린다** — 스크린샷·공유·로그 어디로든 새면 회수
  불가. 전신 사진이 같은 경로에 있으므로 심각도는 여기서 결정된다.

## 3. 설계 — 핵심 결정 네 가지와 근거

### 3-1. 규칙 강화가 아니라 서버 서명인 이유 (기각한 대안 기록)

대안: 화면 로드를 Storage SDK(`getData`) 경유로 바꾸면 읽기가 규칙을
통과한다. 기각 — Storage 규칙은 Firestore를 읽을 수 없고, 소유권
(ownerUid)은 Firestore에, 파일은 평평한 난수 경로에 있어 규칙이
소유자를 판정할 수 없다. 규칙 경로로 가려면 `{uid}/` 경로 재구조화
+ 전 파일 물리 이동이 필요하다. 서버 서명은 파일 이동 0으로 Firestore
소유권을 참조한다.

### 3-2. 서명 요청 단위는 경로가 아니라 문서 ID

**얕은 설계의 함정**: "인증만 하면 요청된 경로에 서명"으로 만들면,
서명 URL에 경로가 그대로 보이므로 유출 URL → 경로 추출 → 익명 가입
계정으로 재서명이라는 재발급 루프가 생겨 만료가 무력화된다.

따라서 서명자는 문서 ID를 받아 **문서를 직접 읽고 접근 정책을 검사한
뒤 그 문서에 기록된 경로에 서명**한다. 질의·인덱스 불요(직접 get).
컬렉션별 정책:

| 컬렉션 | 검사 | 서명 대상 |
|---|---|---|
| wardrobe | doc.ownerUid == caller | imagePath, cutoutPath |
| demo_wardrobe | 인증만(읽기 전용 공용 세트) | imagePath, cutoutPath |
| fitting_cache | ownerUid 있으면 == caller, 없으면(레거시) 인증만 — §8-2 판단 대기 | fitting_results/{cacheKey}.jpg |

배치 지원 필수: 요청 = [{collection, id}] 목록(상한 ~200), 응답 =
{id → {urls, expiresAt}}. 옷장 화면이 119벌을 한 콜로 해결해야 한다.

### 3-3. 만료·캐시·발급 부하

- 만료 60분, 클라이언트는 만료 80% 시점에 갱신. 서명 URL은 Firestore
  에 **절대 저장하지 않는다**(만료 자산의 영속화는 죽은 링크 양산) —
  메모리 캐시만, 키는 docId.
- Flutter 기본 이미지 캐시가 URL 키라 시간마다 재다운로드가 발생할 수
  있다 — v1에서는 수용하고 관측만 한다(cached_network_image 도입은
  새 의존성이라 별도 판단, §8-4).
- 서명자 호출도 rate_limits 계열의 상한 대상이지만 **기존 텍스트/이미지
  카운터와 분리**한다(signCount 별도 — 표본 오염 금지 원칙의 연장).

### 3-4. IAM 선행 조건 (도구 체인 함정 계열 — 먼저 확인)

V4 서명은 함수 런타임 서비스 계정에 **Service Account Token Creator
(iam.serviceAccounts.signBlob)** 역할이 필요하다. 없으면 코드가 정상
배포되고 호출 시점에만 실패한다 — 5.13.5(설정 이전에 계층의 동작
여부 확인)와 같은 층위의 함정이므로, **Phase A 착수 전에 서명 1건을
실제로 발급해보는 스파이크로 확인**하고 결과를 기록한다.

## 4. 단계 (각 단계 = 커밋 묶음 + 관문)

### Phase A — 발급 경로 신설 (추가만, 기존 동작 무변)

A-1. IAM 스파이크: 임시 스크립트로 서명 1건 발급·브라우저 열람·만료
     후 실패까지 확인. 결과 기록 후 스크립트 폐기.

**[A-1 기록 2026-08-06]**

- **경위**: 런타임 서비스 계정(`838064162852-compute@developer.gserviceaccount.com`,
  2nd gen 함수의 기본 Compute Engine SA — 별도 `serviceAccount` 옵션을
  지정한 적이 없어 기본값)을 임퍼스네이션해, 배포된 함수가 ADC로
  `getSignedUrl`을 부를 때와 동일한 조건(그 SA의 신분으로 **자기 자신을
  대상으로** `iamcredentials:signBlob` 호출)을 로컬에서 재현했다.
  1차 시도 `403 PERMISSION_DENIED: iam.serviceAccounts.signBlob` —
  콘솔에서 편집자 역할만 있던 상태와 일치, 편집자만으로는 signBlob이
  안 된다는 걸 실측으로 확인(§3-4의 우려 그대로 재현).
- **조치**: 사용자가 Cloud Console(IAM & Admin → Service Accounts →
  해당 SA → Permissions → Grant Access)에서 그 SA 자신을 principal로
  **Service Account Token Creator**(`roles/iam.serviceAccountTokenCreator`)
  역할을 부여.
- **전파**: 재시도 스크립트(90초 간격, 최대 10분)를 백그라운드로
  돌렸으나 **1차 재시도(경과 0.0분)에서 즉시 `200`** — 이 프로젝트에서는
  IAM 전파가 사실상 즉시였다(일반적으로 알려진 "수 분 소요"보다 빠름,
  표본 1건이라 일반화하지 않는다).
- **성공 확인**: 실존 파일(`wardrobe_images/1783816569550.jpg`,
  wardrobe 문서 `04TUtBH4kRNbklAimENS`)에 V4 서명(만료 60초) URL을
  수동 구성(signBlob 서명 → canonical request, `@google-cloud/storage`의
  내장 서명기가 Impersonated 클라이언트의 `client_email`을 못 읽어
  "Unable to find credentials"로 실패했기 때문) 후 발급 시각에
  `curl`로 요청 → **`200 image/jpeg 64503 bytes`**.
- **만료 확인**: 발급 후 70초 경과 시점에 **같은 URL**로 재요청(시스템
  시각 조작 없이 실제 경과 대기) → **`400 ExpiredToken` —
  "The provided token has expired. Request signature expired at:
  2026-08-05T15:08:27+00:00"**. 403이 아니라 400/ExpiredToken인 건
  GCS의 실제 동작(서명 유효성 자체가 아니라 만료 시각 검사 실패는
  400으로 응답) — "실패"라는 결론에는 영향 없다.
- **결론**: IAM 조치 완료, V4 서명 발급·만료 둘 다 실측으로 검증됨.
  A-2로 진행한다. 스파이크 스크립트(`functions/scratch_iam_spike_*.js`,
  `functions/scratch_find_test_file.js`) 전부 폐기(커밋 대상 아니었음).
A-2. 서버: `getSignedImageUrls` callable(onCall + auth 검사, 3-2 표의
     정책, 배치, signCount 계측). 판정(정책 검사)은 순수 함수로 분리해
     node 테스트(소유 불일치·미존재 문서·레거시 캐시·배치 상한).
A-3. 클라이언트: 업로드가 path 필드를 **URL 필드와 함께** 기록하도록
     확장(이중 기록 — 롤백 여유). ImageUrlResolver 서비스 신설(배치
     발급, 메모리 캐시, 만료 마진 갱신, **실패 시 기존 URL 필드로
     폴백** — 전환기 안전망, Phase C에서 자연 소멸).
A-4. 화면 배선: 이미지 로드를 Resolver 경유로 교체하되 **킬 스위치
     (dart-define SIGNED_URLS, 기본 false)** — 기본 off에서 기존 경로
     그대로임을 확인하고 커밋.
     **[범위 정정 2026-08-06, §9 참고]** "이미지 로드를 Resolver
     경유로 교체"라고 썼지만 실제로 배선된 곳은 옷장 그리드
     (`_WardrobeCard`) **한 곳뿐**이었다. 표시 18곳 + 다운로드
     (`GeminiService._downloadImageBytes*`) 6곳, 합쳐서 24곳 중
     1곳만 이행하고 나머지 23곳은 레거시 URL 필드를 여전히 직접
     썼다 — 이 범위 착오가 아래 §9 사고의 직접 원인이다.

관문 A: off 상태 실기기 무변 확인 → on 상태(디버그)에서 옷장·데모·
가상 피팅 화면 로드 + Resolver 폴백 발화 0 확인.
**[판정 무효화 2026-08-06, §9 참고]** 이 확인은 옷장 그리드만 봤다
— "가상 피팅 화면 로드"라고 적었지만 피팅룸의 나머지 하위 뷰(사용자
사진 선택, 결과 큰 이미지, 옷 선택 미리보기 등)와 다운로드 경로는
검증 범위에 없었다. 통과 판정 자체가 범위 착오였다.

### Phase B — 백필 (기존 문서에 path 추가)

- `tools/backfill_image_paths/` 스크립트(Admin SDK, 기존 백필 규약
  준수): URL의 `/o/{encodedPath}`에서 경로 역산 → path 필드 추가.
  **URL 필드는 건드리지 않는다.** 대상: wardrobe(119), demo_wardrobe,
  fitting_cache. dry-run 출력 → 사용자 확인 → 실행 → 건수 대조(백필
  118건 전례처럼 누락 0 검증).

**[설계 보강 2026-08-06 — 관문 A 조사에서 발견한 고아 참조 3건 반영]**

경로 역산(`pathFromDownloadUrl`/`signed_url_policy.ts`와 동일 규칙)은
URL 문자열만 보고 성공하며, 그 경로에 실제 파일이 있는지 검증하지
않는다. wardrobe 3건(상의)이 정확히 이 사각지대다 — Firestore 문서는
정상 URL 형태를 갖고 있지만 Storage에 파일이 없다(`tools/
audit_image_refs`로 확인, `exists()==False`). 역산 성공 여부만 보면
이 3건도 "백필 성공"으로 집계돼 문제가 은폐된다.

- dry-run은 `bucket.file(path).exists()`를 **추가로** 호출해, 결과를
  **두 축**으로 분리해 보고한다: (1) 경로 역산 성공/실패, (2) 파일
  존재/부재. 네 조합(성공+존재/성공+부재/실패+존재는 불가능/실패+부재)
  중 "역산 성공 + 파일 부재"가 바로 이번에 찾은 고아 참조 유형이다.
- **부재 건도 백필 대상에서 빼지 않는다.** path 필드는 그대로
  기록하되(역산 자체는 유효하다 — 파일이 없을 뿐 경로 계산은 맞다),
  dry-run 출력에서 별도 목록("파일 없음 — 확인 필요")으로 표시한다.
  데이터를 스크립트가 임의로 판단해 빼면 안 된다 — 처분은 사람이
  정한다(§8에 새 항목으로 등록, 아래 참고).
- 건수 대조 검증("누락 0")은 **path 필드 추가 여부** 기준을 유지한다
  — 파일 존재 여부는 이 검증의 통과 기준이 아니다(존재하지 않는
  파일도 경로 자체는 유효하게 기록돼야 하므로). 파일 부재 건수는
  별도로 보고만 한다.

관문 B: SIGNED_URLS=on 릴리스 APK에서 전 화면 정상 + 폴백 발화 0.
단, 고아 참조 3건(상의)은 처분 전까지 이 "폴백 발화 0" 기준에서
예외로 둔다 — 파일이 없으니 서명해도 로드가 안 되고, Resolver는
정상 동작대로 폴백한다(이건 Resolver 결함이 아니라 원본 데이터
결함이 폴백을 정확히 발화시키는 경우다). 관문 B 통과 판정 시 이
3건의 폴백은 "설명 가능한 예외"로 별도 기록하고 카운트에서 분리한다.
**[판정 무효화 2026-08-06, §9 참고]** "전 화면 정상"이라고 적었으나
실제 확인은 옷장 그리드뿐이었다 — 나머지 20곳(§9 표)은 관문 B
시점에도 여전히 레거시 URL을 직접 썼고, 그 상태로 통과 처리됐다.

**[Phase B 완료 — 2026-08-06, Phase C 착수 전 기준 스냅샷]**

세 백필(본인 계정 wardrobe 120건 / 심사 계정 wardrobe 117건 /
demo_wardrobe 119건) 전부 `--apply` 완료. 매 실행 dry-run 예측치와
실제 기록 건수가 정확히 일치했고, URL 필드(`imageUrl`/
`cutoutImageUrl`)는 전후 대조로 불변 확인, manifest는 매 실행마다
보존(`tools/backfill_image_paths/manifests/`, 커밋 제외). 롤백
정밀도는 본인 계정 백필에서 리허설로 실측(§6 참고 — 문서 전체가
아니라 정확히 백필된 필드만 삭제/복원됨).

| 컬렉션 | 문서 수 | `imagePath` 보유 | `cutoutPath` 보유(대상 중) | 이미지 파일 부재 | 컷아웃 파일 부재 |
|---|---|---|---|---|---|
| `wardrobe` | 237 | 237/237 | 225/225 | 3 | 3 |
| `demo_wardrobe` | 119 | 119/119 | 114/114 | 3 | 3 |
| `fitting_cache`(감사만, write 없음) | 23 | — | — | 0 | — |

**[처분 완료 — 2026-08-06]** 고아 참조 3건(`h5L8bP1MV13Ndprr0fvm`/
`l0zuLPFSFI5Vp4kIqHBS`/`ygx17wBZqrMoJwP547e7`) 사용자가 앱에서 직접
삭제(삭제 성공·재실행 후 미복귀 확인). `demo_wardrobe` 미러 3건도
dry-run 확인 후 삭제. **삭제 후**: `wardrobe` 234건(237−3),
`demo_wardrobe` 116건(119−3), 파일 부재 0건(두 컬렉션 다) — 고아
참조가 데이터에서 완전히 제거됐다. 파일 자체(Storage 쪽 잔재 없음 —
애초에 파일이 없었던 게 문제였으므로 삭제할 파일도 없다)는 해당 없음.

**잔여 백필 없음** — `imagePath`/`cutoutPath`가 모두 대상 문서 100%에
기록됐다(URL 필드 자체가 없는 문서는 애초에 대상이 아님 — 컷아웃
미보유 등 정상 상태). 파일 부재는 wardrobe·demo_wardrobe 각 3건씩,
전부 동일한 고아 참조 3건(§8-5)의 미러 — 실제 깨진 고유 파일은
6개(이미지 3+컷아웃 3), 처분 미정 그대로.

Phase C 착수 조건(§8-1: 배포된 모든 활성 클라이언트가 신 APK) 판단은
아직 별도 — 이 스냅샷은 그 판단이 내려진 뒤 Phase C가 되돌리기 어려운
단계(토큰 회수)로 넘어가기 직전의 기준선이다.

**[갱신 2026-08-06 — 위 스냅샷 이후 추가 변동]** §8 판단 대기 3번의
"버킷 루트 잔재 9건" 처분 오류·정정 경위로 문서 12건이 추가 삭제됐다
(전신 사진, cutout 없어 이미지 완전 소실). 이 표의 `wardrobe 234`/
`demo_wardrobe 116`은 더 이상 최신 건수가 아니다 — 현재는 `wardrobe`
226건, `demo_wardrobe` 112건(§8-3 참고). Phase C-1 dry-run/재대조는
이 갱신된 건수를 기준으로 한다.

### Phase C — 토큰 회수 (구멍이 실제로 닫히는 단계, §8-1 판단 후)

- 전제: 관문 B 통과 + 배포된 모든 활성 클라이언트가 신 APK(§8-1).
- 대상 파일의 `firebaseStorageDownloadTokens` 메타데이터 제거
  (Admin SDK 스크립트, 파일 자체는 무변). 실행 전 dry-run 목록 확인.
- 기본값 전환: SIGNED_URLS 기본 true, 기존 URL 폴백은 "폴백 발화 =
  회수 후 이상 신호"로 의미가 바뀌므로 계측에 남긴다.

**수용 기준(사전 등록)**: 5.13.2의 발견 방법 그 자체 — 회수 전 저장해
둔 구 다운로드 URL을 **로그아웃 브라우저**에서 열어 403/404 실패,
만료 전 서명 URL은 성공, 만료 후 서명 URL은 실패. 구멍을 발견한
도구가 수리를 증명한다. 이 3종 확인이 rev 논문의 해소 서술 근거가
된다.

**[증거 공백 기록 — 2026-08-06]** C-0에서 "회수 전 200 확인·저장
완료"로 보고됐던 `phase_c_acceptance_urls.json`(대표 구 URL 3건)이
실제로는 저장소 어디에도 남아있지 않았다 — 대화 중에만 보고되고
파일로 영속화되지 않은 것으로 추정된다. `wardrobe_images/` C-1 검증은
이 파일 없이 **Firestore에서 구 URL을 재조립해 403을 확인하는
대체 경로**로 성립시켰다(회수 후 상태만 실측, 회수 전 200이었다는
대조군 자체는 재현 가능한 산출물로 남지 않음 — 이번엔 리허설의
사전/사후 curl 기록이 그 역할을 대신했다). **규칙**: C-3
(`fitting_results/`) 착수 전에는 회수 대상 구 URL 표본과 그 상태
코드를 `tools/revoke_storage_tokens/manifests/`와 같은 규약(JSON,
영속 경로, 커밋 제외)으로 저장한 뒤에만 회수를 진행한다 — "저장
완료"라는 보고 자체가 아니라 디스크상의 파일 존재로 확인한다.

**[Phase C-1/C-3 실행 후 전체 롤백 — 2026-08-06, §9로 대체]** 아래
"Phase C-1 완료" 판정과 그 하위의 수용 기준 3종 통과 판정은
**무효다.** C-1(`wardrobe_images/`+`wardrobe_cutouts/` 220건)과
이어진 C-3(`fitting_results/` 24건)까지 실행한 뒤, 표시·다운로드
경로 24곳 중 옷장 그리드 1곳만 서명 URL로 이행돼 있었다는 게
드러나 앱 대부분이 기능 정지됐다. `tools/revoke_storage_tokens`의
manifest 5개(`revoke_20260806_033913/034021/034049/043840/044449`)
전량을 `--rollback`으로 되돌려 244개 객체의 토큰을 원상 복구했다.
경위·재설계는 §9에 있다. 원래 이 자리에 있던 "완료" 서술은 그 시점의
판단 오류를 그대로 보여주는 기록으로서 아래에 취소선 없이 보존한다
(무엇을 몰랐는지 지우지 않는다).

~~**[Phase C-1 완료 — 2026-08-06]** `wardrobe_images/` 109건 +
`wardrobe_cutouts/` 111건 = 220건, `firebaseStorageDownloadTokens`
메타데이터 전량 회수(파일 자체는 무변, `tools/revoke_storage_tokens`).
리허설(단일 파일, `--only`)로 200→403→롤백 200→재회수 403을 먼저
실증한 뒤 전량 적용 — 두 라운드 모두 동일 절차. 증거 파일
(`tools/revoke_storage_tokens/manifests/acceptance_evidence_wardrobe_cutouts_pre.json`
— 회수 전 `statusBefore:200`과 회수 후 `statusAfter:403`이 같은
파일에 함께 기록됨)로 대조군 유실 재발을 막았다.

수용 기준(§4) 3종 중 진행 현황:
- **구 URL 실패**: 충족(위 증거 파일 + `wardrobe_images/` 별도 curl
  3건 전부 403).
- **만료 전 서명 URL 성공**: 충족 — 앱 전 화면(옷장·데모 옷장)이
  토큰 메타데이터가 없는 상태에서 서명 URL 경로만으로 정상 표시됨을
  사용자가 실기기에서 확인(재빌드 없이 기존 `SIGNED_URLS=true`
  설치본으로 검증). `rejectedCount`는 두 라운드 다 0, signCount는
  한 자릿수 유지.
- **만료 후 서명 URL 실패**: A-1 IAM 스파이크에서 이미 확인된 항목
  (짧은 만료로 자연 재현, 시스템 시각 조작 없음) — Phase C에서
  재확인하지 않음, 스파이크 결과를 그대로 인용.

남은 것은 C-2(레거시 `fitting_cache` 처리 판단, §8-2)와 C-3
(`fitting_results/` 토큰 회수), 이후 C-4(SIGNED_URLS 기본값 true 전환).~~

**이 판정이 놓친 것**: "앱 전 화면"을 확인했다고 적었지만 실제로는
옷장 그리드(`_WardrobeCard`)만 봤다. 그 시점에 이미 홈·캘린더·
스크랩·주간계획·코디보드·피팅룸 대부분이 레거시 URL을 직접 참조하고
있었고, C-3(`fitting_results/`)까지 실행되자 가상 피팅 생성 자체
(다운로드 경로)도 막혀 사용자가 "긴급 — 앱에서 모든 옷 이미지가
오류"로 발견했다. §9에 전체 경위와 재설계를 기록한다.

## 5. 계측 (도입과 동시에)

signCount(발급 수)·배치 크기 분포·Resolver 캐시 적중/미스·폴백 발화
수. 폴백 발화는 Phase A~B에서는 "전환 누락 탐지", Phase C 후에는
"이상 신호"로 의미가 바뀐다 — 해석 변경 시점을 문서에 기록한다.

## 6. 하지 말 것 (이 작업 한정 추가분)

- 서명 URL을 Firestore에 저장하지 않는다.
- 경로 문자열을 클라이언트 요청으로 받지 않는다(3-2의 재발급 루프).
- Phase C를 관문 B 이전에 실행하지 않는다 — 순서가 뒤집히면 배포
  순서 역전 사고(5.11.2)의 재판이 된다.
- 억지 만료 재현을 위해 시스템 시각을 조작하지 않는다 — 짧은 만료
  (스파이크에서 1분)로 자연 확인한다.

## 7. rev 논문 반영 예고

완료 시: 7.1 "발급된 주소의 회수 불가" 해소 이동, 5.13.2에 수리 경위
각주(발견 도구=검증 도구 대칭), 저장소 경로 격리(7.1 "성격이 바뀐
항목")의 우선순위 재평가 — 서명 경로가 주 접근로가 되면 규칙의 심층
방어 가치도 재서술.

## 8. 판단 대기 (사용자 몫 — 착수 전 §8-1만, 나머지는 해당 Phase 전)

1. **Phase C 시점과 심사 일정**: 회수는 구 APK의 이미지 로드를 죽인다.
   심사위원 APK가 관문 B 이후 빌드라면 심사 전 회수 가능, 아니면 심사
   후로. 어느 쪽인지 결정 필요 — Phase A·B는 어느 경우든 지금 안전.
2. **레거시 fitting_cache(ownerUid 없는 문서) — [확정 2026-08-06]**:
   **인증만으로 서명 허용.** 근거: 현행 Firestore 규칙이 인증만으로
   읽기를 허용하므로, 서명 정책을 이보다 엄격히 하면(예: 소유자
   대조 강제) 기존에 되던 레거시 캐시 열람이 깨지는 기능 회귀가
   된다. 서명 URL 이행의 목표는 접근 **경로**를 영구 다운로드 URL에서
   서명 URL로 바꾸는 것이지, 그 과정에서 소유권 모델을 새로 만드는
   것이 아니다 — 이관 과정에서 정책을 더 조이지 않는다는 원칙.
   **A-2 구현 대조**: `functions/src/signed_url_policy.ts`의
   `decideSignedUrlAccess`(74~78행)가 이미 이 판정과 정확히 일치—
   `fitting_cache`는 `doc.ownerUid !== undefined && doc.ownerUid !==
   callerUid`일 때만 거부하므로, `ownerUid`가 없는 레거시 문서는
   조건이 거짓이 되어 통과한다(인증된 caller면 누구나 서명 발급).
   A-2 작성 시점에 이미 이 결정을 선반영해뒀던 것으로, 코드 변경
   없이 §8-2를 확정으로 갱신한다.
3. **버킷 루트 잔재 9건 — [정정 2026-08-06, 오판 및 사고 경위]**.
   목록(경로·크기·생성일 2026-07-25 이관 시점 몰림, webp 2건은 사진
   추정·나머지 7건은 스크린샷)을 사용자가 공개 URL로 직접 열람 확인
   후 삭제 승인받아 Admin SDK로 9건 전량 삭제했다. **이때 "어떤
   Firestore 문서도 참조하지 않는 고아 파일"이라는 판단이 틀렸다.**
   삭제 후 진행한 Phase C-1 사전 대조(§0 참고, 문서 참조 고유 경로
   수와 회수 대상 경로 수 대조)에서 `wardrobe` 18건 + `demo_wardrobe`
   9건 = 27개 문서의 `imagePath`가 정확히 이 9개 파일명을 가리키고
   있었다는 게 드러났다 — Phase B 백필이 `imageUrl`에서 경로를
   역산할 때, 이 9건은 `wardrobe_images/` 폴더 규약이 생기기 전
   (2026-05-28~06-04 등록분)이라 버킷 루트에 있었고, 그 사실이
   "버킷 루트 잔재 = 미참조"라는 판단에서 누락됐다. 버킷 버전관리가
   꺼져 있어(`bucket.getMetadata().versioning === undefined`) 서버
   쪽 복구는 불가능했다.

   **재대조 후 처분(2026-08-06)**: 27개 문서 중 cutout이 없어 원본이
   유일한 이미지였던 전신(全身) 사진 12건(`wardrobe` 8 +
   `demo_wardrobe` 4)은 이미지가 완전히 소실되어 문서를 삭제했다
   (직전 재확인으로 원본 파일 부재 재검증 → 문서 전문을
   `tools/delete_orphaned_docs/manifests/`에 백업 후 삭제, 커밋
   제외 — 파일은 못 살려도 문서 메타데이터는 영속 경로에 남긴다).
   cutout이 남아있는 15건(`wardrobe` 10 + `demo_wardrobe` 5, 상의/
   아우터)은 문서와 `imagePath`를 그대로 유지 — 대체 사진 재업로드로
   원본 자리를 채울 예정이라 참조 자리를 남긴다. 단 이 15건은 가상
   피팅이 `imageUrl`(원본)만 사용하므로 **대체 사진 업로드 전까지
   피팅에 실패한다**(`docs/handoff_2026-08-04.md` §9 "가상 피팅 불가
   15건" 참고). 삭제 후 `wardrobe` 226건(234−8), `demo_wardrobe`
   112건(116−4). Phase C 토큰 회수(C-1)와는 별도 커밋으로 기록.

   **재발 방지**: "경로가 회수/삭제 대상 프리픽스 밖"이라는 사실
   자체를 위험 신호로 취급한다 — 파일 삭제 전에는 반드시 관련
   Firestore 컬렉션 전수에서 그 경로를 참조하는 문서가 있는지
   대조한다(`docs/handoff_2026-08-04.md` §2 절대 금지 9번에 규칙화).
4. **cached_network_image 재다운로드 완화 여부**: [정정 2026-08-06]
   §3-3 원문이 "새 의존성이라 별도 판단"이라 적었는데 사실과 다르다
   — `cached_network_image`는 이미 pubspec.yaml(3.4.1)에 있고
   `_WardrobeCard` 등 12곳 이상에서 이미 쓰이고 있었다(신규 도입이
   아니라 기존 의존성). 그래서 실제 열린 질문은 "도입할지"가 아니라
   "서명 URL 만료 갱신마다(80% 시점) 캐시 키가 바뀌어 재다운로드가
   발생하는 걸 완화할지"다 — 예를 들어 캐시 키를 URL 대신 문서 id로
   커스터마이즈하는 방법이 있다(`cached_network_image`의
   `cacheKey` 파라미터). 시간당 재다운로드가 관측으로 문제가 되면
   그때 판단 — 지금은 미조치.
5. **고아 참조 3건(wardrobe 상의, 파일 없는 문서)** — [처분 완료
   2026-08-06]. 관문 A 검증 중 발견(§4 Phase B 설계 보강 참고,
   `tools/audit_image_refs`로 재현 가능). 문서 id
   `h5L8bP1MV13Ndprr0fvm`/`l0zuLPFSFI5Vp4kIqHBS`/`ygx17wBZqrMoJwP547e7`
   — Firestore 문서(imageUrl·cutoutImageUrl 둘 다)는 정상 URL 형태를
   갖고 있으나 Storage에 파일이 없었다(`bucket.blob(path).exists()
   ==False`). 원인(업로드 실패 후 문서만 남았는지/이관 중 유실/별도
   삭제)은 끝내 미규명. **서명 URL 이행과 무관한 기존 데이터
   결함**이었다(신규 코드 미호출 확인됨 — signCount 불변).
   **처분**: 사용자가 앱에서 `wardrobe` 3건을 직접 삭제(삭제 성공·
   재실행 후 미복귀 확인), `demo_wardrobe` 미러 3건은 dry-run 확인
   후 스크립트로 삭제. 삭제 후 `wardrobe` 234건, `demo_wardrobe`
   116건, 파일 부재 0건(두 컬렉션 다) — 재검증 완료.

## 9. Phase C 사고 — 실행 후 전체 롤백 (2026-08-06)

### 경위

C-1(`wardrobe_images/`+`wardrobe_cutouts/` 220건)을 실행하고 §4
수용 기준 3종을 "충족"으로 판정, 이어 §8-2를 확정하고 C-3
(`fitting_results/` 24건)까지 실행했다. 직후 사용자가 전신 사진을
신규 등록하며 "앱에서 모든 옷 이미지가 오류"를 보고했다.

1차 진단(상한 도달·logcat·서버 함수 직접 호출)에서 rate limit·
서명 발급·서명 URL 접근 3개 층 전부 정상으로 확인됐으나 앱은
계속 깨져 있었다. 사용자가 제시한 가설(`GeminiService.
_downloadImageBytes` 경로가 Resolver를 안 거치고 레거시 `imageUrl`을
직접 다운로드한다)을 코드로 확인하는 과정에서, 문제가 그 가설보다
훨씬 컸다는 게 드러났다: **A-4가 "화면 배선"이라고 적어둔 범위는
실제로 옷장 그리드 한 곳뿐이었고, 표시·다운로드를 합쳐 24곳 중
23곳이 여전히 레거시 URL 필드(`imageUrl`/`cutoutImageUrl`/
`fittingImageUrl`)를 직접 참조하고 있었다.** 관문 A·B가 "전 화면
정상"으로 통과시킨 확인도 사실은 그 한 곳만 봤다.

즉시 조치: `tools/revoke_storage_tokens`의 manifest 5개
(`revoke_20260806_033913.json`/`034021.json`/`034049.json`/
`043840.json`/`044449.json`, 리허설 2건 + 108건 + 111건 + 24건 =
244개 객체 상당) 전량을 `--rollback`으로 되돌려 토큰 복원. 증거 파일
(`acceptance_evidence_wardrobe_cutouts_pre.json`,
`acceptance_evidence_fitting_results_pre.json`)의 표본 6건 + 별도
`wardrobe_images/` 3건, 총 9건 curl 재확인으로 전부 200 복귀 확인.
`revoke.py` 전량 재-dry-run으로 대상 245건(신규 업로드 1건 포함)
전부 토큰 보유 상태 확인. 사용자가 실기기에서 홈·옷장·캘린더·
피팅룸을 직접 확인 — **이미지 합성(가상 피팅 생성)까지 정상 동작,
롤백 완료.**

**Phase B(경로 백필)는 롤백 대상이 아니다.** 이번에 되돌린 건
Storage 객체의 `firebaseStorageDownloadTokens` 메타데이터뿐이고,
Phase B가 Firestore 문서에 써넣은 `imagePath`/`cutoutPath` 필드는
전혀 건드리지 않았다 — 그대로 유효하다. A-5는 이 필드를 그대로
재사용한다(다시 백필할 필요 없음).

### 판정 무효화

§4(관문 A·B의 "전 화면 정상"), §4 말미("Phase C-1 완료"와 수용
기준 3종 충족 판정)는 전부 **무효**다 — 검증 범위가 옷장 그리드
1곳에 한정됐던 것을 "전 화면"으로 잘못 기술했다. 원문은 삭제하지
않고 취소선으로 보존한다(§4 참고).

### 직접 원인

A-4 항목의 문구("이미지 로드를 Resolver 경유로 교체")가 실제
작업 범위(그리드 1곳)보다 넓게 쓰였고, 관문 A·B 통과 확인이 그
문구를 그대로 믿고 "전 화면"을 실제로 훑지 않았다. **범위를
코드로 확인하지 않고 관문을 통과시킨 것이 이번 사고의 직접
원인이다.**

### 24개 지점 전수 목록 (재설계 대상)

**[집계 정정 2026-08-06]** 사고 직후 보고·기록에 "표시 15곳"으로
적었으나 실제 표(아래)는 처음부터 18행이었다 — 프로즈 집계만
잘못됐다(15+6=21이 아니라 18+6=24). 아래는 정정된 수치.

#### 표시 경로 18곳 — `CachedNetworkImage` 직접 사용, `SignedNetworkImage` 미배선

| 파일:행 | 위치 | 컬렉션/문서 id 확보 | URL 필드 |
|---|---|---|---|
| `wardrobe_screen.dart:1893` | 카드 액션시트 "비슷한 옷" 썸네일 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `home_screen.dart:541` | 홈 대표 아이템 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `home_screen.dart:899` | 홈 대표 아이템(2) | 위와 동일 | `cutoutImageUrl??imageUrl` |
| `home_screen.dart:886` | 홈 피팅 카드 | `fitting_cache` — **캐시 키 확보 여부 미확인** | `fittingImageUrl` |
| `calendar_screen.dart:528` | 캘린더 대표 아이템 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `calendar_screen.dart:515` | 캘린더 피팅 이미지 | `fitting_cache` — **캐시 키 확보 여부 미확인** | `fittingImageUrl` |
| `calendar_record_sheet.dart:482` | 기록 시트 아이템 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `calendar_record_sheet.dart:407` | 기록 시트 피팅 | `fitting_cache` — **캐시 키 확보 여부 미확인** | `imageUrl`(피팅 결과) |
| `outfit_board.dart:399` | 코디보드 아이템 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `outfit_board.dart:661` | 코디보드 아이템(2) | 위와 동일 | `cutoutImageUrl??imageUrl` |
| `scrap_screen.dart:215` | 스크랩 피팅 이미지 | `fitting_cache` — **캐시 키 확보 여부 미확인** | `fittingImageUrl` |
| `weekly_plan_sheet.dart:150` | 주간계획 아이템 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `fitting_room_screen.dart:623` | 사용자 사진 선택 목록 | `wardrobe`, `photo.id` 있음 | `photo.imageUrl` |
| `fitting_room_screen.dart:983` | 피팅 결과 큰 이미지 | `fitting_cache` — `fittingCacheKey` 있음(캐시 히트 시만, `FittingJobController.fittingCacheKey` 참고) | `fittingImageUrl ?? _mockFittingImageUrl` |
| `fitting_room_screen.dart:1651` | 옷 선택 슬라이드 | `wardrobe`, `slide.item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `fitting_room_screen.dart:1785` | 옷 선택 미리보기 | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `fitting_room_screen.dart:1992` | 옷 선택 미리보기(2) | `wardrobe`, `item.id` 있음 | `cutoutImageUrl??imageUrl` |
| `full_screen_image_viewer.dart:32` | 전체화면 뷰어 | 호출부가 넘긴 `imageUrl` 파라미터 — **호출부별로 collection/id 재확보 필요** | 파라미터 |

(`item_detail_screen.dart:110`은 하드코딩 unsplash placeholder라 제외.)

**막힌 지점**: `fittingImageUrl` 계열(홈·캘린더·기록시트·스크랩)은
현재 화면 모델이 `OutfitHistoryEntry.fittingImageUrl`(URL 문자열)만
들고 `fitting_cache` 문서 id(캐시 키)를 안 들고 다닌다. `fitting_room_
screen.dart:983`만 `FittingJobController.fittingCacheKey`로 캐시
키를 이미 들고 있어 즉시 배선 가능하다 — **나머지는 캐시 키를
저장/전달하도록 데이터 흐름을 넓히는 선행 작업이 필요**하다(예:
`OutfitHistoryEntry`에 `fittingCacheKey` 필드 추가 + 기록 시점에
같이 저장). 이게 안 되면 이 4곳은 서명 URL로 못 옮기고 레거시
URL을 계속 쓰거나(회수 대상에서 영구 제외) 별도 설계가 필요하다.

#### 다운로드 경로 6곳 — `GeminiService._downloadImageBytes*`, Resolver 미경유

| 파일:행 | 트리거 | URL 출처 |
|---|---|---|
| `fitting_job_controller.dart:83` (`analyze` 스트리밍) | 코디 분석(전신 사진+프로필 없음) | `userPhoto?.imageUrl` |
| `fitting_job_controller.dart:109` (`analyze` 폴백) | 스트리밍 실패 폴백 | `userPhoto?.imageUrl` |
| `fitting_job_controller.dart:183` (`_resolveAttributes`) | 속성 캐시 없는 레거시 옷 | `item.imageUrl` |
| `fitting_job_controller.dart:239-240` (`generateFitting`) | 가상 피팅 생성 | `userPhoto.imageUrl` + `clothingItems[].imageUrl` |
| `wardrobe_screen.dart:46` → `agent_planner.dart:781` | 신규 등록 직후 속성 추출 | 등록 시 `imageUrl` |
| `agent_sweeper.dart:95-98` → `agent_planner.dart:781` | 미완료 속성추출 재개 | `item.imageUrl` |

이 6곳은 `item.id`/`collection`을 이미 호출부가 들고 있어(옷장
아이템·사용자 사진 전부 `wardrobe` 문서) 캐시 키 문제 없이 Resolver
경유로 바꿀 수 있다 — 표시 경로보다 설계가 단순하다.

## 10. A-5 설계 초안 (구현 전 — 이 문서는 설계만, 착수는 별도 승인)

Phase B(`imagePath`/`cutoutPath` 백필)는 롤백 대상이 아니었으므로
그대로 유효하다 — A-5는 이 필드를 재백필 없이 그대로 쓴다.

### 3군 분류 (24곳)

**군 (a) — 문서 id를 화면에서 바로 얻는 곳 (19곳)**: `collection`은
전부 고정 문자열(`wardrobe` 또는 `fitting_cache`)이고 `id`는 이미
그 자리의 지역 변수(`item.id`/`photo.id`/`userPhoto.id`)로 존재한다
— 인자 추가나 데이터 흐름 변경 없이 위젯/호출만 바꾸면 된다.

- 다운로드 6곳(전부): `fitting_job_controller.dart:83,109,183,
  239-240`, `wardrobe_screen.dart:46`, `agent_sweeper.dart:95-98`.
- 표시 13곳: `wardrobe_screen.dart:1893`, `home_screen.dart:541,899`,
  `calendar_screen.dart:528`, `calendar_record_sheet.dart:482`,
  `outfit_board.dart:399,661`, `weekly_plan_sheet.dart:150`,
  `fitting_room_screen.dart:623,983,1651,1785,1992`.
  (`983`은 `fitting_cache`지만 `FittingJobController.fittingCacheKey`가
  이미 그 화면 상태에 있어 (a)로 분류 — 인자 전달 불필요.)

**작업량**: 표시 13곳은 그리드(`_WardrobeCard`)와 완전히 동일한
패턴 — `CachedNetworkImage(imageUrl: X)`를
`SignedNetworkImage(collection:'wardrobe', id:item.id,
urlIndex:cutout유무, fallbackUrl:X)`로 기계적 치환. 다운로드 6곳은
`GeminiService.*` 함수들이 URL 대신 `(collection, id)`를 받도록
시그니처를 바꾸고, 함수 내부에서 `ImageUrlResolver.resolve()` →
성공 시 서명 URL 다운로드, 실패(null) 시 기존 URL 필드로 폴백
다운로드 — 표시 위젯의 폴백 패턴과 대칭으로 통일. 총 19곳, 반나절
내외로 추정(패턴이 이미 검증돼 있어 설계 리스크 낮음).

**검증**: 각 지점을 실기기에서 개별적으로 로드해보고 signCount
증가(개별 발화가 아니라 코얼레싱된 배치인지)와 폴백 발화 0을
Resolver 계측으로 확인. 사람이 "화면이 뜬다"만 보고 넘어가지 않고,
아래 §10 관문 체크리스트의 해당 행에 확인 시각을 남긴다.

**군 (b) — id는 구할 수 있으나 인자 전달이 필요한 곳 (1곳)**:
`full_screen_image_viewer.dart:32`의 **`fitting_room_screen.dart:893`
호출부만** — 이 화면은 `FittingJobController.fittingCacheKey`를
이미 들고 있지만, `FullScreenImageViewer` 위젯 자체가 `imageUrl`
파라미터만 받고 `collection`/`id`를 안 받는다. 위젯에 선택적
`collection`/`id` 파라미터를 추가하고, 이 호출부에서만
`collection:'fitting_cache', id: fittingCacheKey`를 전달하도록
바꾼다(`fittingCacheKey`가 null이면— 방금 생성한 결과라 아직
캐시 문서가 없는 경우—기존처럼 `imageBytes`를 직접 쓰거나
`fallbackUrl`로 넘어간다, 캐시 미기록 상태이므로 서명 대상 문서
자체가 없어 당연한 폴백).

**작업량**: 위젯 파라미터 1개 추가 + 호출부 1곳 수정, 매우 작음.

**군 (c) — `OutfitHistoryEntry`에 캐시 키가 없어 선행 작업 필요 (4곳
+ 아래 파생 1곳)**: `home_screen.dart:886`,
`calendar_screen.dart:515`, `calendar_record_sheet.dart:407`,
`scrap_screen.dart:215`, 그리고 `full_screen_image_viewer.dart:32`의
**`scrap_screen.dart:182` 호출부**(군 (b)와 반대로 캐시 키 자체가
없어 인자 전달로 해결이 안 됨).

**[정정 2026-08-06]** 아래 원래 서술("소급 backfill 불가능")은
**틀렸다** — 조사 결과는 §10-1에 있다. 원문은 무엇을 놓쳤는지
보존을 위해 지우지 않고 아래 그대로 두되, 결론은 §10-1을 따른다.
또한 "레거시 폴백으로 남는다"는 서술도 부정확하다 — Phase C가
`fitting_results/`까지 회수하면 레거시 URL 자체가 죽으므로, 백필이
안 되는 경우의 정확한 결과는 "폴백 유지"가 아니라 **"과거 피팅
이력 이미지 소실"**이다(2026-08-06 사고에서 실제로 관측된 것과
같은 메커니즘).

**마이그레이션 필요 여부(원래 결론, 정정 대상)**:
`_buildFittingCacheKey`(`fitting_job_controller.dart:262-269`)는
`sha256('${userPhoto.id}:${정렬된 옷 id들}')`로 캐시 키를 만드는데,
`OutfitHistoryEntry`(`models/outfit_history_entry.dart`)는 옷
아이템 스냅샷(`items`)과 `fittingImageUrl`만 저장하고
**`userPhoto.id`를 저장하지 않는다**(`_logFittingHistorySilently`,
`fitting_job_controller.dart:318-331` 확인). 즉 기존에 이미 저장된
이력 문서로는 캐시 키를 절대 재계산할 수 없다 — 애초에 필요한
입력값(사용자 사진 id)이 기록에 없다.

**권장안(원래 결론, 정정 대상)**: `OutfitHistoryEntry`에
`fittingCacheKey`(String?) 필드를 추가하고, `_logFittingHistorySilently`
호출 시점에 이미 알고 있는 `cacheKey` 값을 같이 저장 — 이후 생성분만
커버되고 과거 이력은 영구 소실 처리한다는 전제였다.

**작업량**: 모델 필드 추가(1) + 호출부 배선(1, `cacheKey`를
`_logFittingHistorySilently`로 전달) + 화면 4곳+파생 1곳의
표시/뷰어 로직에서 "필드 있으면 서명, 없으면 레거시 폴백" 분기
추가. 군 (a)/(b)보다 설계 작업이 더 필요 — 별도 커밋으로 분리.

**검증**: 신규 피팅 생성 → 이력에 `fittingCacheKey` 기록 확인 →
그 이력을 홈/캘린더/스크랩 화면에서 열어 서명 경로로 표시되는지
확인. 과거(필드 없는) 이력은 레거시 폴백으로 여전히 뜨는지(즉
"깨지지 않는지"만) 별도 확인 — 이 쪽은 폴백 발화가 정상이므로
Resolver 계측의 "폴백 0" 기준에서 제외하고 §4의 "설명 가능한 예외"
패턴을 그대로 따른다.

### 10-1. (c)군 처분 — 세 선택지 조사 (2026-08-06, 결정 대기)

착수 전 판단이 하나 남았다. 위 원안의 "과거 이력은 레거시 폴백으로
남는다"는 틀렸다 — Phase C가 `fitting_results/`까지 회수하면 레거시
URL도 죽으므로, 백필이 안 되면 정확한 결과는 **과거 피팅 이력
이미지의 영구 소실**이다. 아래 세 선택지를 조사만 하고 결정은
보류한다.

**실측 데이터** (2026-08-06 조사, `users/*/history` 전수 + `fitting_cache` 전수 대조):

- `type=='fitting'` 이력: 전 사용자 합계 **28건**(uid별 —
  `BDDOIl08...` 8건, `JmllppO9t9NcU0NiaDWrbOnP4ae2` 4건, `yPyw4...`
  16건 — 세 번째 uid는 이전까지 조사에 등장하지 않았던 사용자다).
- `fitting_cache` 총 문서 수: 25건.
- **`fitting_cache` 문서 자체에는 구성 정보(사용자 사진 id·옷 id)가
  없다** — 스키마는 `{imageUrl, ownerUid?, createdAt}`뿐(실측
  확인, `cacheFittingResult` 참고). 즉 "B: 캐시 문서로 매칭"은
  캐시 문서 안의 필드로는 불가능하다.
- **그런데 `fittingImageUrl`(이력에 이미 저장돼 있는 필드) 자체가
  캐시 키를 인코딩하고 있다.** `StorageService.uploadFittingResult`
  가 파일을 `fitting_results/{cacheKey}.jpg`에 올리므로
  (`storage_service.dart:70`), 이 URL의 경로에서 파일명만 떼면
  (`.jpg` 제거) 그게 곧 `fitting_cache` 문서 id다 —
  `signed_url_policy.ts`의 `pathFromDownloadUrl`과 완전히 같은
  역산 방식. **guess가 아니라 구조적으로 보장된 관계다.**
- 28건 전수에 대해 이 역산을 실제로 돌린 결과: **28/28 역산
  성공, 28/28이 실존하는 `fitting_cache` 문서와 일치.** 매칭
  실패·모호성 0건.

**(A) 수용 — 과거 이력 이미지 소실**

| 항목 | 내용 |
|---|---|
| 영향 범위 | 28건(사용자 3명) 전부 — 홈 "최근 착장"·캘린더·스크랩·기록시트에서 열람 불가로 전환 |
| 작업량 | 없음(§10 원안의 필드 추가만, 과거분 손실 감수) |
| 리스크 | 사용자가 이미 본 적 있는 과거 결과물이 조용히 깨짐 — 사전 고지 없으면 "버그처럼" 보일 수 있음 |

**(B) 일회성 백필 — `fittingImageUrl`에서 `fittingCacheKey` 역산**

| 항목 | 내용 |
|---|---|
| 실현 가능성 | **가능, 실측 100%(28/28) 성공** — §10의 "화면에서 유도 불가" 결론은 틀렸다(그 결론은 `userPhoto.id` 저장 여부만 보고 `fittingImageUrl` 자체가 키를 인코딩한다는 걸 놓쳤다) |
| 매칭 정확도 | 추측이 아니라 업로드 시점부터 결정론적으로 고정된 경로 규칙이므로 오매칭 가능성 자체가 없다(다른 이력의 키를 잘못 붙일 수가 없는 구조) |
| 작업량 | `tools/backfill_image_paths`와 같은 규약의 1회성 스크립트 — 전 사용자 `history` 순회 → `fittingImageUrl` 있고 `type=='fitting'`인 문서에 `pathFromDownloadUrl` 역산 → `fitting_cache` 존재 확인(방금 한 실측과 동일) → `fittingCacheKey` 필드 기록. dry-run/manifest/rollback 관례 재사용 가능 |
| 남는 위험 | 지금은 28/28이지만, 스크립트를 실제로 돌리는 시점까지 사이에 생성되는 신규 이력은 별도로 커버해야 함(§10 권장안의 필드가 A-5 구현에 포함되면 자동 해결) |

**[결정 2026-08-06 — (B) 채택, 실행 완료]** `tools/
backfill_fitting_cache_key --apply`로 28건 전량 백필(manifest:
`backfill_20260806_053429.json`). 사용자별 BDDOIl 8 / `JmllppO9...`
(유령 계정) 4 / yPyw4 16 — 실측이 정확히 재확인됨. 쓰기 후 28건
전수 재검증(값이 URL 역산과 일치 + `fitting_cache` 문서 실존)
28/28 통과.

**유령 계정(`JmllppO9t9NcU0NiaDWrbOnP4ae2`) 4건 포함 판단 근거**:
앱에서 조회되지 않는 고아 이력일 가능성이 높지만(wardrobe 0건 —
2026-07-29 uid 전환 사고의 잔재, `docs/session_2026-07-29_summary_2.md`
참고), 이 백필은 필드를 **추가만** 하고 기존 값을 절대 덮어쓰지
않는 순수 추가 작업이라 무해하며, 나중에 이 계정을 정리·병합할
때 이미 `fittingCacheKey`가 채워진 상태로 두는 편이 유리해 굳이
제외하지 않았다.

**(C) `fitting_results/` 를 Phase C 대상에서 제외**

| 항목 | 내용 |
|---|---|
| 효과 | (c)군 4곳+파생 1곳의 마이그레이션·백필 문제 자체가 사라짐 — 이번 Phase C 재착수 범위를 `wardrobe_images/`+`wardrobe_cutouts/`(군 (a)/(b) 20곳)로만 좁힐 수 있음 |
| 노출 위험 | `fitting_results/`의 다운로드 토큰을 영구히 회수하지 않는다는 뜻 — 이 이미지들은 **사용자의 실제 사진(얼굴·체형)이 옷과 합성된 결과물**로, 원본 "전신" 사진과 같거나 그 이상으로 개인식별성이 높다. 이 프리픽스만 예외로 남기면, 이 이니셔티브가 애초에 풀려던 문제(rev 논문 5.13.2/7.1 "발급된 URL은 영구히 유효, 회수 불가")가 **가장 민감한 이미지 카테고리에서만 그대로 재현**된다 — 목표와 정면으로 배치되는 절충 |
| 되돌리기 | 나중에 (c)군 설계가 끝나면 `--prefixes fitting_results/`로 별도 회수 가능(이미 도구가 지원) — 영구 결정은 아님, 다만 그 사이 구간은 노출 상태 |

조사는 여기까지다 — 결정 후 A-5 구현에 반영한다.

### 관문 체크리스트 초안 (Phase C 재착수 전 필수, (c)군 처분 결정 후 확정)

"전 화면 정상"처럼 추상적으로 쓰지 않는다 — 아래 24행을 실기기에서
하나씩 확인하고, 통과 보고에 이 표 자체를 확인 시각과 함께 첨부한다.
(c)군 행의 통과 기준은 위 10-1 결정에 따라 달라진다((A) 선택 시
"과거 이력은 소실 고지 후 제거", (B) 선택 시 "서명 경로로 로드",
(C) 선택 시 이 4행+파생 1행은 이번 Phase C 재착수 범위에서 제외).

**[재감사 2026-08-06 — 24행 → 최종 25행]** 구현 완료 후 목록 자체의
완전성을 재확인했다: (1) `lib/` 전체에서 `CachedNetworkImage(`/
`Image.network(`/`NetworkImage(`/`http.get(` 등 원격 이미지 접근
패턴을 전수 재grep, (2) 남은 raw `CachedNetworkImage(`가 전부
의도된 것인지 확인 — `SignedNetworkImage`와 짝을 이루는 폴백
분기 8곳, 위젯 내부 구현체(`signed_network_image.dart` 자체) 1곳,
`item_detail_screen.dart`의 하드코딩 unsplash placeholder 1곳
(실데이터 아님, 범위 밖), `fitting_room_screen.dart`의 문서화된
드문 예외(§10 표 각주) 1곳 — 전부 설명 가능, 미배선 잔여 없음.
(3) `http`/`dio` 등 바이트 다운로드 경로도 재확인 — `lib/`에서
`http` 패키지를 쓰는 곳은 `gemini_service.dart`(이미 배선)와
`weather_service.dart`(날씨 API, 사용자 이미지와 무관)뿐. (4) 24행
각각이 실제로 `SignedNetworkImage`/리졸버 경유로 배선됐는지 역방향
확인 — 24행 전부 코드와 일치. 다만 그 과정에서 group (a) 작업 중
부수적으로 고친 지점 하나가 원래 24행 목록에 없었다는 게 드러나
25번으로 추가한다(**미배선 잔여가 아니라 이미 고쳐진 것을 뒤늦게
기록하는 것** — 재감사가 놓친 결함이 아니라 목록 누락이었다).

| # | 파일:행 | 군 | 통과 기준 |
|---|---|---|---|
| 1 | `fitting_job_controller.dart:83` | a | 서명 URL로 다운로드 성공 |
| 2 | `fitting_job_controller.dart:110` | a | 서명 URL로 다운로드 성공 |
| 3 | `fitting_job_controller.dart:185` | a | 서명 URL로 다운로드 성공 |
| 4 | `fitting_job_controller.dart:242-244` | a | 서명 URL로 다운로드 성공 |
| 5 | `wardrobe_screen.dart:45` | a | 서명 URL로 다운로드 성공 |
| 6 | `agent_sweeper.dart:95-98` | a | 서명 URL로 다운로드 성공 |
| 7 | `wardrobe_screen.dart:1893`(카드 액션시트 "비슷한 옷") | a | 서명 URL로 표시 |
| 7b | `wardrobe_screen.dart:2026`(그리드 `_WardrobeCard`, A-4 원original) | a | 서명 URL로 표시(이미 배선돼 있던 기준점) |
| 8 | `home_screen.dart:542`(`_RecommendationItemImage`) | a | 서명 URL로 표시 |
| 9 | `home_screen.dart:915`(대표 아이템/캘린더 요약) | a | 서명 URL로 표시 |
| 10 | `calendar_screen.dart:541`(대표 아이템) | a | 서명 URL로 표시 |
| 11 | `calendar_record_sheet.dart:501`(아이템 선택 그리드) | a | 서명 URL로 표시 |
| 12 | `outfit_board.dart:399`(보드 슬롯) | a | 서명 URL로 표시 |
| 13 | `outfit_board.dart:664`(아이템 선택 다이얼로그) | a | 서명 URL로 표시 |
| 14 | `weekly_plan_sheet.dart:150` | a | 서명 URL로 표시 |
| 15 | `fitting_room_screen.dart:624`(전신 사진 슬롯) | a | 서명 URL로 표시 |
| 16 | `fitting_room_screen.dart:985`(피팅 결과 큰 이미지) | a | 서명 URL로 표시 |
| 17 | `fitting_room_screen.dart:1698`(옷 선택 슬라이드) | a | 서명 URL로 표시 |
| 18 | `fitting_room_screen.dart:1835`(풀스크린 슬라이드) | a | 서명 URL로 표시 |
| 19 | `fitting_room_screen.dart:2045`(옷 선택 그리드) | a | 서명 URL로 표시 |
| 20 | `full_screen_image_viewer.dart:42`(fitting_room_screen 호출부) | b | 서명 URL로 표시 |
| 21 | `home_screen.dart:891`(홈 피팅 카드) | c | 서명 URL로 표시(§10-1 (B) 백필 완료) |
| 22 | `calendar_screen.dart:517`(캘린더 피팅 이미지) | c | 서명 URL로 표시 |
| 23 | `calendar_record_sheet.dart:415`(피팅 선택 목록) | c | 서명 URL로 표시 |
| 24 | `scrap_screen.dart:219` + `full_screen_image_viewer.dart:42`(scrap_screen 호출부, `signedCollection`) | c | 서명 URL로 표시 |
| 25(신규) | `fitting_room_screen.dart:1007`(피팅 결과 없을 때 사용자 사진 placeholder) | a | 서명 URL로 표시 — group (a) 작업 중 부수 발견·즉시 수정, 원래 24행 목록에 누락돼 있었음 |

**[갱신 2026-08-06]** §10-1에서 (B)를 채택해 28건 전량 백필 완료 —
(c)군도 "신규만 서명"이 아니라 **전부 서명 경로**가 통과 기준이다.
단, 백필 스크립트 실행 이후 생성되는 신규 피팅은 A-5 구현이
`_logFittingHistorySilently`에 `fittingCacheKey`를 같이 쓰도록
고쳐야 계속 커버된다(§10 권장안).

**[범위 정정 2026-08-06 — (c)군 실제 구현 착수 중 발견]** 위 24번
표는 21/22/24행이 전부 `OutfitHistoryEntry`에서 값을 읽는 것처럼
적었으나 틀렸다. 실제로는 서로 다른 **3개의 독립 Firestore
컬렉션**이 각자 `fittingImageUrl`을 저장한다:
- `users/{uid}/history`(`OutfitHistoryEntry`) — §10-1에서 조사·
  백필한 바로 그것(28건).
- `users/{uid}/calendar`(`OutfitCalendarEntry`) — `home_screen.dart:886`,
  `calendar_screen.dart:515`가 실제로 읽는 컬렉션. `history`와
  완전히 별개라 28건 백필이 이쪽엔 전혀 영향을 안 준다.
- `users/{uid}/scraps`(`ScrapEntry`) — `scrap_screen.dart:215` +
  `full_screen_image_viewer.dart`의 scrap_screen 호출부가 읽는
  컬렉션. 역시 별개.

(`calendar_record_sheet.dart:407`만 실제로 `OutfitHistoryEntry`를
읽는다 — "최근 가상 피팅 결과에서 고르는" 목록이라 원래 표가 맞았다.)

재조사 결과: `calendar`는 32건 중 `fittingImageUrl` 보유 1건,
`scraps`는 1건 — 둘 다 `fitting_results/{cacheKey}.jpg` 경로에서
역산 가능하고 대응 `fitting_cache` 문서도 실존(2/2 성공). 세 가지
전부 조치 완료:
1. `OutfitCalendarEntry`/`ScrapEntry` 모델에도 `fittingCacheKey`
   필드 추가(읽기/쓰기).
2. 쓰기 경로 갱신 — `calendar_record_sheet.dart`(`_selectedFitting.
   fittingCacheKey`를 그대로 복사), `fitting_room_screen.dart`
   스크랩 생성(`FittingJobController.fittingCacheKey` 직접 전달).
   둘 다 캐시 키를 다시 계산하지 않고 이미 알고 있는 값을 그대로
   흘려보낼 뿐이다.
3. `tools/backfill_fitting_cache_key`를 `history`뿐 아니라
   `calendar`/`scraps`까지 순회하도록 일반화 — 2건 추가 백필
   완료(manifest: `backfill_20260806_060257.json`).

교훈: "OutfitHistoryEntry에 캐시 키가 없다"는 원래 조사가 모델
하나만 보고 결론 낸 것과 같은 종류의 실수다(관문을 코드로 재확인
안 하고 넘어가면 반복된다) — 이번엔 구현 중 실제 호출부를 따라가며
발견해 즉시 수정했다.

Phase C(토큰 회수) 재착수는 위 25행(24행 + 재감사로 추가된 25번)이
전부 체크된 뒤에만 한다.

## 11. A-6 — 예외 안전성 + fittingImageUrl 소스 판별 (2026-08-06)

25행 체크리스트 실기기 확인(21개 항목, 사용자 확인 완료) 후 남은
raw `CachedNetworkImage` 8곳을 지점별로 감사하면서, "폴백이라
괜찮다"는 판단 중 Phase C(토큰 회수) 이후에는 성립하지 않는 두
부류를 발견해 처리했다.

**#8 — 배치 실패 시 전체 폴백 (이번 사고의 근본 메커니즘)**:
`ImageUrlResolver._flushPending`이 배치 호출 예외 시 그 배치 전체를
한꺼번에 폴백시키는 구조는 배선 완전성(A-5)과 무관하게 그대로
남아있었다 — 정상 배선돼 있어도 서명 발급이 일시적으로 실패하면
Phase C 이후엔 그게 곧 빈 화면이다. 조치: `FirebaseFunctions`
직접 호출을 `testServerCall`로 주입 가능한 계층으로 분리 → 배치
호출에 짧은 지수 백오프 재시도(최초 포함 최대 3회) 추가 →
`SignedNetworkImage`에 재시도 가능 오류 상태 추가(서명 해석 최종
실패 시 errorWidget에 재시도 트리거, 탭하면 `_resolve()` 재실행).
`test/image_url_resolver_test.dart`(4개)로 재시도 성공·재시도 소진
후 다음 요청에서 재시도됨(굳지 않음)·배치 간 격리·배치 내 원자성을
검증.

**#1/#2 — `fittingImageUrl`이 실제로는 wardrobe URL일 수 있는 경로**:
`home_screen.dart`의 "추천을 캘린더에 기록" 프리필이 대표 옷
아이템의 URL을 `fittingImageUrl` 자리에 저장할 수 있어(현재 데이터
0건, 코드로는 도달 가능), 기존 "cacheKey 있으면 서명·없으면 포기"
로직이 이 경우를 놓쳤다. 조치: `resolveFittingImageTarget()` 신설
— cacheKey 우선, 없으면 URL 경로 프리픽스로 역산
(`fitting_results/` → `fitting_cache`, `wardrobe_images|cutouts/`
→ `wardrobe`+`itemIds.first`, 서버는 항상 Firestore 문서 id로만
서명하므로 3-2 재발급 루프 방지 원칙 유지). `calendar_screen.dart`/
`home_screen.dart`/`calendar_record_sheet.dart`/`scrap_screen.dart`
전부 이 함수로 교체. `test/resolve_fitting_image_target_test.dart`
(7개)로 우선순위·역산·경계조건 검증.

### 8곳 최종 표 (Phase C 생존 여부)

| # | 파일:행 | 필드 | 왜 미배선인가 | Phase C 이후 성립하는가 |
|---|---|---|---|---|
| 1 | `calendar_screen.dart` | `entry.fittingImageUrl` | `resolveFittingImageTarget`이 null일 때만 폴백(cacheKey 없음 **+** URL이 알려진 패턴 아님 **+** itemIds도 없음 — 3중 조건) | 현재 데이터로는 도달 불가 확인(실존 2건 전부 매칭). 남는 건 미지 URL 패턴 같은 극단적 이론상 경우뿐 |
| 2 | `home_screen.dart` | 위와 동일 | 위와 동일 | 위와 동일 |
| 3 | `calendar_record_sheet.dart` | `f.fittingImageUrl`/`_prefillImageUrl` | 위와 동일(+ 스크랩 프리필 미리보기도 동일 로직 적용) | 위와 동일 |
| 4 | `scrap_screen.dart`(그리드) | `entry.fittingImageUrl` | 위와 동일 | 위와 동일 |
| 5 | `full_screen_image_viewer.dart` | 호출부가 넘긴 `signedCollection`/`signedId` | 호출부(`scrap_screen`/`fitting_room_screen`)가 이미 `resolveFittingImageTarget`(scrap) 또는 직접 로직(fitting_room)으로 계산 | scrap 호출부는 1~4와 동일 수준으로 좁혀짐 |
| 6 | `fitting_room_screen.dart:1030` | 라이브 `fittingCacheKey` | uid-null 생성 엣지케이스 — `fitting_cache` 문서 자체가 없어 URL 역산으로도 못 고침(구조적) | **성립하지 않음 — 그러나 배선으로 해결 불가능한 유일한 항목.** 원인이 "서명 안 함"이 아니라 "서명 대상 문서가 없음"이라 URL 판별 확장으로도 못 푼다. 재발 방지 대상 아님(§10 원문 그대로) |
| 7 | `item_detail_screen.dart:110` | 하드코딩 unsplash URL | 우리 Storage/데이터가 아님 | 완전히 성립 — Phase C와 무관 |
| 8 | `signed_network_image.dart` | 위젯 자체 렌더 지점 | 배선 메커니즘 그 자체 | **이번 조치로 성립 범위 확대** — 배치 실패해도 재시도로 흡수, 최종 실패해도 재시도 가능한 상태로 남아 "빈 화면 고정"은 아니다 |

결론: 8곳 중 실질적으로 Phase C 이후 문제가 될 수 있는 건 #6
(구조적으로 고칠 수 없는 알려진 예외) 하나뿐이다. 나머지는 조치로
막혔거나(#1~#5, #8) 애초에 무관하다(#7).

### A-6 축약 관문 (2026-08-06, 실기기)

`SIGNED_URLS=true` 릴리스 재빌드 → `adb install -r` → 3항목:

1. **소스 판별 4개 화면**(홈 피팅 카드·캘린더 피팅 이미지·기록 시트
   피팅 썸네일·스크랩 그리드): 실기기 확인 **통과**.
2. **재시도 UI**(비행기모드로 서명 실패 재현): **실기기 미확인.**
   `CachedNetworkImage`가 URL을 캐시 키로 쓰는데, 이 기기로 이미
   수십 차례 테스트해 대상 이미지가 전부 디스크에 캐시돼 있어
   비행기모드에서도 네트워크를 안 타고 캐시로 렌더링됐다(캐시 히트가
   실패 자체를 가려버림) — 한 번도 안 본 이미지로 재현하려면 별도
   절차(신규 업로드 직후 미조회 상태에서 비행기모드 전환)가
   필요한데 번거로워 생략하기로 사용자가 결정. **대신
   `test/image_url_resolver_test.dart` 4건(실제 서버 실패를
   주입해 재시도·격리·비고착 검증)으로 갈음** — 이건 실기기 검증이
   아니라 단위 테스트 검증이라는 걸 그대로 기록한다.
3. **전체화면 뷰어**(피팅 결과 탭 → 전체화면): 실기기 확인 **통과**.

**signCount/rejectedCount**: 10 → 16(Δ+6), `rejectedCount` 0 — 정상.

**A-5(24/25행 배선) + A-6(예외 안전성 + 소스 판별) 완료로 기록한다
— 단, 항목 2는 실기기가 아니라 단위 테스트로 갈음됐다는 조건부다.**
Phase C 재착수 계획은 다음 단계에서 논의한다.

### 이번 검증 중 발견한 무관 결함 (A-5/A-6 범위 밖, 지금 안 고침)

실기기 재현 중 A-5/A-6과 무관한 기존 결함 2건을 우연히 재현했다 —
`docs/handoff_2026-08-04.md` §9에 "결함 A"(포그라운드 추천 생성
실패 시 재시도 태스크 미생성)·"결함 B"(`callGeminiText` 60초
타임아웃이 실제로는 발동 안 하고 5분+ 무응답)로 기록. Phase C
재착수 판단에는 영향 없음 — 서명 URL 경로와 무관한 별개 코드 경로.

## 12. Phase C 재착수 계획 (2026-08-06)

이전 시도(§9)는 "회수 후에만" 확인했고 그마저 그리드 1곳뿐이었다 —
이번엔 **회수 전에** 기준선을 만들고, 단계마다 멈춰서 확인한다.

### C-0' 선행 조건 (회수 전에만 가능한 것들)

1. **재시도 UI 실기기 확인 — 생략하지 않는다.** 회수 후에는 폴백이
   없어 재시도 UI가 유일한 안전망이므로, 한 번도 실기기에서 안 떠본
   채로 회수하면 오늘 사고의 구조(단위테스트 통과 → 실기기 미확인
   → 회수 → 전면 백지)를 그대로 반복한다. 절차: 온라인에서 새 옷
   등록 → 그 아이템을 화면에 띄우지 않고 이탈(캐시 방지) →
   비행기모드 → 강제종료 → 재실행 → 옷장에서 그 아이템까지 스크롤
   (첫 렌더링, 캐시 없음) → 재시도 아이콘 뜨는지 확인 → 비행기모드
   해제 → 탭 → 복구되는지 확인. 사용자가 직접 조작.
2. **회수 전 25행 체크리스트 통과 기록.** §10 25행을 회수 **전에**
   한 번 돌려 전부 정상임을 기록한다 — 회수 후 같은 목록과 비교할
   기준선. 사용자가 확인.
3. **증거 파일**: 프리픽스별(`wardrobe_images/`, `wardrobe_cutouts/`,
   `fitting_results/`) 대표 3건씩 구 URL과 `statusBefore`를
   `tools/` 영속 경로(JSON, 커밋 제외)에 저장 — C-0 유실 전례가
   있으므로 파일로 남긴다(대화 보고만으로 남기지 않는다).

### C-1' 회수 (단계 분리 유지)

프리픽스 하나씩: **1차 `wardrobe_images/` → 2차 `wardrobe_cutouts/`
→ 3차 `fitting_results/`.** 각 단계마다:

회수(`revoke.py --apply`) → 25행 체크리스트 전수 확인 →
signCount/rejectedCount 확인 → **통과해야 다음 프리픽스로 진행**.

리허설(`--only` 단일 파일 회수→롤백→재회수)은 **1차에서만** 다시
한다 — A-6으로 `ImageUrlResolver`/`SignedNetworkImage` 코드가
바뀌었으므로 롤백 경로가 여전히 정확히 동작하는지 재확인이
필요하다(2·3차는 1차에서 이미 확인된 메커니즘 재사용이므로 생략).

### 중단 규칙 (사전 등록)

25행 중 **한 곳이라도** 깨지면 즉시 그 단계를 롤백하고 원인을
규명한다. **"설명 가능하니 진행"은 금지** — 오늘 사고가 정확히 그
판단에서 났다. `#6`(`fitting_room_screen.dart:1030`, uid-null
엣지케이스)만 알려진 예외이고, 그 외 실패는 전부 중단 사유다.

### C-4 (회수 완료 후)

- `SIGNED_URLS` 기본값 `true`로 전환.
- **신규 업로드 토큰 처리 설계(제안, 미구현)** — 회수는 과거 파일만
  청소하므로 새로 올라가는 파일은 여전히 토큰을 갖고 태어난다
  (2026-08-06 전신 사진 신규 등록 때 실측 확인 — `wardrobe_images/`
  110건 중 신규 1건도 토큰 보유). 이대로 두면 시간이 지날수록 구멍이
  다시 벌어진다. 제안: `StorageService.uploadWardrobeImage/
  uploadWardrobeCutout/uploadFittingResult`가 `ref.getDownloadURL()`
  로 `imageUrl`을 얻는 순간 Firebase Storage가 토큰을 자동 생성하는
  게 근본 원인 — 그 직후 `ref.updateMetadata()`로 커스텀 메타데이터
  (`firebaseStorageDownloadTokens` 포함)를 비워 토큰을 즉시 제거하는
  방안. `imageUrl` 필드 자체는 그대로 저장한다(킬 스위치 off 시
  폴백 표시용) — 다만 그 순간부터 이미 죽은 URL이라는 점만 다르다.
  **구현 전 확인 필요**: `firebase_storage` 패키지의
  `updateMetadata(SettableMetadata(customMetadata: {}))`가 실제로
  기존 커스텀 메타데이터 키를 지우는지(스펙만 보고 단정하지 말 것 —
  A-1 IAM 스파이크처럼 실측으로 확인), 이 추가 호출이 업로드 지연에
  주는 영향.
- 폴백 발화 계측의 의미 변경(Phase A~B "전환 누락 탐지" → Phase C
  이후 "이상 신호") — §5에 이미 있는 원칙을 회수 완료 시점에
  다시 명시.
