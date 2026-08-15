# 복구 가이드 — Blaze 해제 후 원상 복구용 (2026-08-15 기준)

Blaze(종량제) 플랜을 해제하면 일부 기능(Cloud Functions, Cloud Scheduler, Secret Manager 등)이
비활성화되고 콘솔/API에서 관련 설정을 다시 조회하기 어려워질 수 있다. 이 문서는 **저장소에
없고 Firebase/GCP 콘솔에만 존재하는 것**을 모아, 프로젝트를 처음부터 재구성할 수 있게 하는 것이
목적이다. 저장소에 이미 있는 것은 "저장소에 있음"이라고만 적고 값은 반복하지 않는다.

프로젝트 ID: **`ai-fashion-assistant-personal`** (project number `838064162852`), 리전:
**`asia-northeast3`**(서울) — Cloud Functions·Cloud Scheduler 전부 이 리전.

---

## 1. Secret Manager — `GEMINI_API_KEY`

- 코드 측 참조: `functions/src/index.ts:31` `defineSecret("GEMINI_API_KEY")`. 값 자체는 이 문서를
  포함해 저장소 어디에도 없다(있어서도 안 된다).
- **등록 절차만 기록**(값은 기록하지 않음):
  ```
  firebase functions:secrets:set GEMINI_API_KEY --project ai-fashion-assistant-personal
  ```
  프롬프트가 뜨면 Gemini API 키 값을 입력한다. 이후 이 시크릿을 사용하는 함수를 배포하면
  자동으로 바인딩된다(`defineSecret`을 쓰는 함수의 `runWith`/params 설정에 이미 반영됨 — 코드
  변경 불필요).
- **이게 없으면**: `defineSecret`을 참조하는 모든 함수(Gemini 호출 관련 — `callGeminiText`,
  가상 피팅 등)가 배포 시점 또는 호출 시점에 시크릿 미존재로 실패한다.

## 2. Cloud Scheduler

`onSchedule`로 선언된 함수는 Firebase가 배포 시 Cloud Scheduler 잡 + Pub/Sub 토픽을 자동
생성한다 — 잡을 수동으로 만들 필요는 없고, **함수를 재배포하면 스케줄러 잡도 함께 재생성된다.**
다만 이름·주기는 기록해 둔다(콘솔에서 사라지면 코드만 보고는 "이런 주기 작업이 있었는지" 자체를
놓칠 수 있으므로).

| 함수(export명) | 주기 | 리전 | timeZone | 소스 |
|---|---|---|---|---|
| `scheduledProactiveCheck` | `every 3 hours` | asia-northeast3 | 미지정 | `functions/src/index.ts:1388-1389` |
| `sweepStorageTokens` | `every 24 hours` | asia-northeast3 | 미지정 | `functions/src/index.ts:1494-1495` |

**주의(§6-1 관련 — 이 세션에서 규명):** `every N hours`처럼 기간 기반 스케줄은 함수를
재배포할 때마다 내부 타이머가 리셋된다. 재배포가 잦은 개발 단계에서 `sweepStorageTokens`
같은 장주기 작업이 "24시간째 한 번도 안 돈다"처럼 보이는 것은 실제 장애가 아니라 이 리셋
때문일 수 있다 — 재배포 직후라면 먼저 이 가능성부터 배제한다(`task_hardening_v2.md` §6-1,
`docs/DOT_paper_rev9.md` §7.1 참고).

- **이게 없으면**: 백그라운드 알림 발화(`scheduledProactiveCheck`)와 만료 Storage 토큰 정리
  (`sweepStorageTokens`)가 전혀 돌지 않는다 — 둘 다 사용자가 앱을 실행하지 않아도 서버가
  자율적으로 도는 것이 핵심 설계이므로, 이 잡이 없으면 그 자율성 자체가 사라진다.

## 3. Firestore 복합 인덱스

**저장소에 이미 있음** — `firestore.indexes.json`(repo root), 2개 정의:
`recommendations`(dismissed ASC + createdAt DESC), `wardrobe`(ownerUid ASC + createdAt DESC).
`firebase.json`의 `firestore.indexes` 필드가 이 파일을 가리킨다.

- **복구 절차**: `firebase deploy --only firestore:indexes` — 콘솔에서 손으로 다시 만들 필요
  없음.
- **이게 없으면**: 위 두 필드 조합으로 쿼리하는 화면(추천 목록 필터링, 옷장 최신순 조회 등)이
  "인덱스가 필요합니다" 오류로 실패한다.

## 4. FCM (Firebase Cloud Messaging)

- Android/iOS 설정 파일 모두 **저장소에 이미 있음**(git 추적 확인):
  `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`. 프로젝트를
  Firebase 콘솔에서 다시 만들고 같은 패키지명/번들ID로 앱을 재등록하면 이 파일들을 그대로
  재사용할 수 있다(단, 프로젝트를 아예 새로 만드는 경우 앱 ID·API 키가 바뀌므로 파일도
  다시 받아야 한다 — 기존 프로젝트를 Blaze만 재활성화하는 경로라면 파일 재사용 가능).
- **iOS APNs 키는 저장소에 없다** — Firebase 콘솔 → 프로젝트 설정 → Cloud Messaging → Apple
  앱 구성에서 APNs 인증 키를 등록해야 iOS 푸시가 동작한다. 이 프로젝트는 지금까지 실기기
  검증이 전부 Android였고(§9 검증 로그, `docs/task_agent_cadence_v1.md` 등), iOS APNs 키가
  실제로 등록되어 있는지는 **확인되지 않았다** — 복구 시 iOS 푸시를 쓰려면 먼저 콘솔에서
  등록 여부부터 확인한다.
- **이게 없으면**: `scheduledProactiveCheck`가 만드는 알림이 기기에 전혀 도달하지 않는다
  (Android는 google-services.json만 있으면 동작, iOS는 APNs 키까지 필요).

## 5. Firebase App Check — 현재 상태와 이유

**현재 상태 확인 경로**: Firebase 콘솔 → 왼쪽 메뉴 "빌드(Build)" 그룹 → App Check. 이 문서
작성 시점 기준 **미등록**이다 — `com.fashionai.ai_fashion_assistant`(Android) 앱이 위 화면에
목록으로 뜨지 않는다. 클라이언트는 `activate()`를 호출하지만(`main.dart:57`) 서버
어디에도 `enforceAppCheck`가 없어 강제되지 않는다 — 즉 설계상 미강제가 아니라 등록 자체가
안 된 상태다.

**보류 이유** (`task_hardening_v2.md` §3-1-3의 판정 그대로): 배포 방식(사이드로드 vs Play
스토어 경유)이 정해지지 않은 상태에서는 App Check를 강제로 전환할 경로를 확정할 수 없다 —
잘못 켜면 모든 서버 함수 호출(텍스트 분석, 가상 피팅 등)이 일제히 거부되어 앱이 전면 정지한다.
대안으로 검토했던 "디버그 토큰 콘솔 수동 등록"은 무결성을 검증하지 않는 허용 목록에 불과해
기각됐다(같은 절 근거 2). 복구 후 App Check를 다시 다루려면 먼저 배포 방식부터 정하고
`task_hardening_v2.md` §3-1-3~§3-1-4를 읽는다.

- **이게 없으면(현재 상태 기준)**: 없어도 지금 당장 아무것도 깨지지 않는다 — 애초에
  강제하지 않는 상태이기 때문이다. 나중에 강제 전환을 시도할 때 앱이 미등록 상태이면
  App Check 검증 자체가 실패해 강제 전환 즉시 앱이 정지한다는 점만 유의한다.

## 6. Google Sign-In (OAuth)

- Android OAuth 클라이언트 정보는 **저장소에 이미 있음** —
  `android/app/google-services.json`의 `oauth_client` 배열: `client_type: 1`(Android)
  항목에 패키지명 + `certificate_hash`(SHA-1 지문)가, `client_type: 3`(Web용, 서버 인증 코드
  교환에 쓰는 클라이언트)이 함께 있다.
- 등록된 SHA-1은 **디버그 키스토어** 기준이다(`android/app/build.gradle.kts:40` — release
  빌드도 `signingConfigs.getByName("debug")`를 그대로 쓴다. 즉 이 프로젝트는 릴리스도 디버그
  서명이다, 사이드로드 배포 패턴과 일치). 디버그 키스토어는 보통 `~/.android/debug.keystore`에
  있으며 머신마다 다를 수 있다 — **이 키스토어 파일 자체는 저장소에 없고 백업도 없다.**
- **이게 없으면**: 새 머신/새 디버그 키스토어로 빌드하면 SHA-1이 바뀌어 Google Sign-In이
  `DEVELOPER_ERROR`(또는 이와 유사한 코드)로 즉시 실패한다. 복구 절차: 새 키스토어의 SHA-1을
  `keytool -list -v -keystore ~/.android/debug.keystore`로 뽑아 Firebase 콘솔 → 프로젝트 설정
  → 이 Android 앱 → SHA 인증서 지문에 추가하고, `google-services.json`을 다시 받아 교체한다.

## 7. 서비스 계정 / IAM

Cloud Functions 코드는 `admin.initializeApp()`를 인자 없이 호출한다(`functions/src/index.ts`
부근) — 명시적 서비스 계정 키 파일을 쓰지 않고, Cloud Functions 실행 환경이 기본 제공하는
**기본 서비스 계정**(App Engine 기본 서비스 계정 또는 Compute 기본 서비스 계정, 프로젝트
생성 시점의 GCP 기본값에 따라 다름)의 자격 증명을 암묵적으로 사용한다. 이 계정에 부여된
정확한 IAM 역할 목록은 저장소에서 확인할 수 없다 — **콘솔에서 직접 확인해야 한다**
(IAM 및 관리자 → IAM, `...@appspot.gserviceaccount.com` 또는
`...-compute@developer.gserviceaccount.com` 검색). **[2026-08-15 확인]** 로컬
Firestore 덤프에 쓰는 어드민 SDK 키로 Cloud Resource Manager API
(`projects:getIamPolicy`)를 직접 호출해 자동화를 시도했으나 403(권한 부족)으로
실패했다 — 이 키는 Firestore 관리 용도로만 발급되어 있어 프로젝트 IAM 조회 권한이
없다. 즉 이 목록은 스크립트로 대신할 수 없고, Blaze 해제 전 지금 콘솔에 직접
접속해 확인하거나 최소한 화면을 캡처해 두는 것이 유일한 방법이다.

로컬 스크립트(Firestore 덤프 등)에서 쓰는 별도 자격 증명은 이 서비스 계정과 다르다 —
`GOOGLE_APPLICATION_CREDENTIALS` 환경변수가 가리키는
`ai-fashion-assistant-personal-firebase-adminsdk-fbsvc-....json` 키 파일(로컬에만 있음, 저장소
밖)이며, 이 문서 작성 시점 기준 로컬 머신에 존재함을 확인했다.

- **이게 없으면**: Cloud Functions 자체는 새로 배포하면 GCP가 기본 서비스 계정을 자동
  연결하므로 이 계정이 "사라지는" 시나리오는 사실상 없다. 다만 기본 역할이 프로젝트
  생성 시점 정책에 따라 달라질 수 있어(예: 최신 GCP 프로젝트는 기본 서비스 계정에 자동으로
  Editor 역할을 주지 않음), 복구 후 Firestore/Storage 접근이 거부되면 이 역할 부여부터
  확인한다.

## 8. 복구 순서

1. **Blaze 재활성화** — Cloud Functions·Cloud Scheduler는 Blaze 필수.
2. **Secret Manager 등록** — §1의 `firebase functions:secrets:set GEMINI_API_KEY`. 함수
   배포보다 먼저 해야 배포 시 시크릿 바인딩이 즉시 성립한다.
3. **함수 배포** — `firebase deploy --only functions` (TypeScript 코드베이스 `default` +
   Python 코드베이스 `bgremoval` 둘 다, `firebase.json`의 `functions` 배열 참고). 이 시점에
   Cloud Scheduler 잡(§2 표의 2개)이 자동 생성된다.
4. **Firestore 인덱스 배포** — `firebase deploy --only firestore:indexes`(§3).
5. **앱 빌드** — Android는 §6의 SHA-1이 콘솔에 등록되어 있는지 먼저 확인(새 키스토어라면
   먼저 추가) 후 빌드. App Check는 §5의 보류 상태를 그대로 유지(강제 전환 안 함)한 채
   진행해도 앱은 정상 동작한다.

이 순서를 벗어나면(예: 함수 배포 전 시크릿 미등록) 배포 자체가 실패하거나, 배포는 되어도
런타임에 시크릿 미존재로 실패한다.
