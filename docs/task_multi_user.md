# 작업 지시서 — 다중 사용자 격리와 실사용자 배포

대상 저장소: `park-jang-sup/ai-fashion-assistant`
목표: 두 번째 사용자를 받을 수 있게 만들고, 실사용자에게 배포해 데이터를 수집한다.

**이 작업의 목적은 "안전"이 아니라 "측정"이다.** 지금 `wardrobe`가 전역
컬렉션이라 두 번째 사용자가 첫 번째 사용자의 옷장을 그대로 본다. 즉 사용자를
한 명도 더 받을 수 없다. 실사용 데이터를 모으려면 이것부터 풀어야 한다.

**단계는 D → F → E 순이다. E가 마지막인 것은 의도적이다**(사유는 E단계 서두).

---

## 0. 배포 순서가 이 작업의 핵심이다

코드보다 **배포 순서**에서 사고가 난다. 순서를 틀리면 옷장 113벌이 화면에서
사라지거나, 백필 자체가 불가능해진다.

```
1. 복합 인덱스 배포 → 콘솔에서 "Enabled" 확인까지 대기
2. 백필 스크립트 dry-run → 결과 검토 → --apply
3. 앱 릴리스 (where 필터 포함)        ← 이 시점에도 규칙은 아직 옛것
4. 규칙 배포
```

각 단계의 이유:

- **인덱스가 먼저인 이유** — `where(ownerUid) + orderBy(createdAt)`는 복합
  인덱스가 필요하다. 없으면 쿼리가 `FAILED_PRECONDITION`으로 실패한다.
  인덱스 빌드에는 시간이 걸리므로 가장 먼저 밀어두고 기다린다.
- **백필이 규칙보다 먼저인 이유** — 규칙을 먼저 바꾸면 `ownerUid`가 없는
  기존 문서는 읽기도 쓰기도 막힌다. **백필 자체가 불가능해진다.**
- **앱이 규칙보다 먼저인 이유** — 규칙을 먼저 배포하면 구버전 앱(필터 없는
  쿼리)이 `permission-denied`로 죽는다. 앱을 먼저 올리면 이미 필터를 쓰고
  있으므로 규칙 배포가 무손상으로 지나간다.

### 배포 전 필수 확인

```bash
firebase use          # 활성 프로젝트가 .firebaserc 기본값과 같은지 확인
```

이전에 CLI 전역 캐시가 다른 프로젝트를 가리켜 **오배포한 사고가 있었다.**
`firebase deploy` 치기 전에 매번 확인할 것.

---

# D단계 — Firestore 사용자 격리 (하루)

## D.1 복합 인덱스 추가

`firestore.indexes.json`에 항목을 추가한다. 기존 `recommendations` 인덱스와
같은 형식이다.

```json
{
  "collectionGroup": "wardrobe",
  "queryScope": "COLLECTION",
  "fields": [
    { "fieldPath": "ownerUid", "order": "ASCENDING" },
    { "fieldPath": "createdAt", "order": "DESCENDING" }
  ]
}
```

```bash
firebase deploy --only firestore:indexes
```

**콘솔 → Firestore → 색인에서 상태가 "사용 설정됨"이 될 때까지 기다린다.**
빌드 중에 쿼리를 날리면 실패한다.

> 참고: 지금까지 이 프로젝트는 "신규 복합 인덱스 없음"을 유지해 왔다. 이번엔
> 불가피하다 — 사용자별 필터와 최신순 정렬을 동시에 하려면 방법이 없다.
> 논문 2.2절에 이 성질이 기술돼 있다면 갱신 대상이다.

## D.2 백필 스크립트 — `tools/backfill_owner_uid/`

`tools/migrate_to_personal/migrate.py`의 규약을 그대로 따를 것.

- 서비스 계정 키는 `--credentials` 또는 `GOOGLE_APPLICATION_CREDENTIALS`로만
  받고, **저장소 안의 경로는 거부**한다
- **기본 동작은 dry-run.** 실제 쓰기는 `--apply` 명시 필요
- `--apply` 시 대상 프로젝트 id를 사람이 직접 입력해야 진행

동작:

1. `wardrobe` 전체를 순회
2. `ownerUid` 필드가 **없는** 문서만 대상으로 집계 (있으면 건드리지 않음 — 재실행 안전)
3. dry-run이면 대상 수와 샘플 5건을 출력하고 종료
4. `--apply`면 `--owner-uid <uid>` 로 받은 값을 배치로 기록
5. **마지막에 검증**: `ownerUid`가 없는 문서 수를 다시 세어 **0이 아니면 실패로 종료**

5번이 중요하다. 백필에서 누락된 문서는 그 옷이 **영원히 화면에서 사라진다는
뜻**이고, 사용자는 이유를 알 수 없다. 스크립트가 스스로 확인해야 한다.

`--owner-uid`에 넣을 값은 현재 사용 중인 익명 계정의 uid다. 앱 설정 화면이나
Firebase 콘솔 → Authentication에서 확인할 수 있다.

## D.3 모델과 서비스 수정

### `lib/models/wardrobe_item.dart`

```dart
// 이 옷을 소유한 사용자. 레거시 문서(백필 이전)에는 없을 수 있어 nullable.
// 화면에서 쓰지는 않지만, 쿼리 필터와 쓰기 시 기록을 위해 모델에 둔다.
final String? ownerUid;
```

`fromFirestore`에서 읽고, `toFirestore`에서 null이 아닐 때만 쓴다.

### `lib/services/firestore_service.dart`

**`wardrobeStream()`에 필터 추가.** 인자로 uid를 받는다 — 서비스가
`FirebaseAuth`를 직접 참조하지 않게 해서 호출부가 명시적으로 넘기게 한다.

```dart
static Stream<List<WardrobeItem>> wardrobeStream(String uid) {
  return _db
      .collection(_wardrobeCol)
      .where('ownerUid', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      ...
}
```

**`addWardrobeItem`에 `required String ownerUid` 추가**하고 문서에 기록한다.

**`getWardrobeItemSilently` / `tryClaimExtractionAttemptSilently` /
`deleteWardrobeItem` / `updateWardrobe*`는 doc id 직접 접근이라 쿼리 변경이
필요 없다.** 규칙이 소유자 검사를 하므로 남의 문서에는 접근이 거부된다.

### 호출부

`wardrobeStream()` 호출 지점 전부를 찾아 uid를 넘긴다. `grep -rn
"wardrobeStream" lib/`로 확인할 것. 백그라운드 경로(`agent_planner.dart`)도
포함되며, 거기서는 이미 복원된 uid를 갖고 있다.

**uid를 못 구하는 위치에서는 스트림을 만들지 말고 빈 상태로 둘 것.** 인증이
아직 복원되지 않았는데 빈 문자열이나 임의 값으로 조회하면 "옷장이 비었다"는
잘못된 화면이 뜬다.

## D.4 규칙 변경

```
// 옷장 — 본인 것만. ownerUid가 없는 문서(백필 누락)는 읽히지 않는다.
match /wardrobe/{itemId} {
  allow read: if request.auth != null
              && resource.data.ownerUid == request.auth.uid;
  allow create: if request.auth != null
                && request.resource.data.ownerUid == request.auth.uid;
  allow update, delete: if request.auth != null
                        && resource.data.ownerUid == request.auth.uid;
}
```

`create`와 `update/delete`를 나눈 이유: 생성 시점에는 `resource`가 없고
`request.resource`만 있다. 하나로 묶으면 생성이 항상 거부된다.

### `fitting_cache` — 마이그레이션 없이 해결

```
// doc id가 "사용자 사진 + 옷 조합"의 SHA-256이라 열거만 막으면 충분하다.
// 키를 아는 본인만 접근할 수 있고, 키는 자기 사진에서 파생되므로 남이
// 만들어낼 수 없다. 코드가 doc id 직접 접근만 하므로 list는 필요 없다.
match /fitting_cache/{cacheKey} {
  allow get, write: if request.auth != null;
  allow list: if false;
}
```

**지금 상태에서는 인증된 아무나 `fitting_cache` 전체를 나열해 다른 사람의
가상 피팅 결과 URL을 얻을 수 있다.** 사용자가 한 명일 때는 무의미했지만
배포 직후부터는 실제 문제가 된다. `allow list: if false` 한 줄이면 막히고,
데이터 이동이 전혀 필요 없다.

## ✅ D단계 관문

1. 백필 dry-run 결과와 `--apply` 후 검증(누락 0건) 출력
2. `flutter analyze` / `flutter test` 통과
3. **릴리스 APK**로 실기기 설치 → 기존 옷장 113벌이 **그대로 보인다**
4. 새 옷을 한 벌 등록 → 문서에 `ownerUid`가 기록된다
5. 규칙 배포 후에도 3·4가 그대로 동작한다
6. 백그라운드 실행이 계속 정상 동작한다(설정 화면의 `lastRunAt` 갱신 확인)

**3번이 이 단계의 전부다.** 여기서 옷장이 비어 보이면 즉시 멈추고 백필 상태를
확인할 것.

---

# F단계 — 실사용자 배포 (반나절)

D단계 관문 통과 직후 시작한다. **배포가 빠를수록 데이터 수집 기간이 길어진다.**

## F.1 Firebase App Distribution

Play Console 등록($25)은 필요 없다. App Distribution은 무료이고 이미 쓰는
Firebase 프로젝트 안에 있다.

- 콘솔 → App Distribution → 테스터 그룹 생성
- 릴리스 APK 업로드, 테스터 이메일 등록
- 테스터는 초대 메일 → 링크 설치

## F.2 참가자 안내와 동의 — 생략하지 말 것

**다른 사람의 옷 사진과 생활 데이터를 수집하는 작업이다.** 최소한 다음을
문서로 만들어 설치 전에 전달하고, 구두 또는 메시지로 동의를 받는다.

- 수집 항목: 등록한 옷 사진, 카테고리·색상·격식 속성, 추천 채택 여부, 캘린더 일정 태그
- 이용 목적: 추천 알고리즘 개선 및 공모전 제출 자료의 **통계 산출**
- 공개 범위: **개별 데이터는 공개하지 않고 집계 수치만 사용**
- 보관 기간과 삭제 요청 방법
- 사진은 본인 옷만 등록하고 타인이 식별되는 사진은 올리지 말 것

이건 절차상의 부담이 아니라 **사업계획서에 그대로 들어갈 항목**이다.
"개인정보 처리 방침 수립 및 동의 절차 운영"은 실현가능성 근거가 된다.

## F.3 수집할 지표를 미리 정한다

숫자를 본 뒤에 기준을 정하면 원하는 결론에 맞추게 된다. 배포 전에 확정할 것.

| 지표 | 산출 방법 |
|---|---|
| 사용자별 옷장 커버리지 | 추천에 등장한 고유 itemId / 등록한 총 옷 수 |
| 추천 채택률 | `userChoice == accepted` / 응답이 있는 추천 수 |
| 등록 규모 | 사용자별 옷 수, 속성 추출 성공률 |
| 백그라운드 발화 간격 | `agent_meta`의 `lastInvokedAt` 시계열 |
| 알림 도달 | 알림 발송 수 대비 앱 진입 |

`tools/user_study_report/`에 집계 스크립트를 두되, **개별 사용자를 식별하는
출력은 만들지 말 것.** uid는 순번으로 치환하고 사진은 다루지 않는다.

## ✅ F단계 관문

1. 본인 외 **최소 1명**이 설치해 옷을 등록하고, **서로의 옷장이 보이지 않는다**
2. 집계 스크립트가 사용자 2명 이상의 지표를 낸다
3. 안내문 전달과 동의 확인 기록

1번이 D단계의 실전 검증이다. 단위 테스트로는 절대 확인할 수 없다.

---

# E단계 — 계정 승격 (반나절, D·F 이후)

## 왜 마지막인가

익명 인증만으로도 다중 사용자는 성립한다. 계정 승격이 해결하는 것은
**"앱을 지웠다 깔아도 데이터가 남는가"**인데, 3~4주 스터디에서 재설치하는
참가자는 드물다. 즉 **배포를 막을 이유가 아니다.**

그리고 `linkWithCredential`은 uid를 **바꾸지 않으므로**, 이미 사용 중인
참가자에게 나중에 업데이트로 배포해도 데이터가 그대로 승계된다. 배포를
늦추는 것보다 먼저 내보내고 나중에 붙이는 쪽이 수집 기간에서 이득이다.

## E.1 의존성

```yaml
dependencies:
  google_sign_in: ^6.2.1   # SDK 제약에 맞춰 조정, 충돌 시 먼저 보고할 것
```

Firebase 콘솔 → Authentication → 로그인 방법에서 **Google 사용 설정**,
`android/app` 에 SHA-1 지문 등록, `google-services.json` 갱신.

## E.2 교체가 아니라 승격이다

**가장 흔한 실수가 "구글 로그인 화면을 새로 만드는 것"이다.** 그러면 새 uid로
로그인되어 기존 데이터가 전부 고아가 된다.

```dart
// 기존 익명 uid를 유지한 채 구글 계정을 연결한다. uid가 바뀌지 않으므로
// 데이터 마이그레이션이 0이다.
final credential = GoogleAuthProvider.credential(
  idToken: googleAuth.idToken,
  accessToken: googleAuth.accessToken,
);
await FirebaseAuth.instance.currentUser!.linkWithCredential(credential);
```

예외 처리:

- `credential-already-in-use` — 그 구글 계정에 이미 다른 uid가 붙어 있다.
  "기존 계정으로 로그인하시겠습니까? 현재 기기의 데이터는 유지되지 않습니다"로
  안내하고, 동의 시에만 `signInWithCredential`로 전환한다. **묻지 않고 전환하면
  안 된다.**
- `provider-already-linked` — 이미 연결됨. 조용히 성공 처리.

## E.3 진입점은 두 곳이다

**설정 화면에 "계정 연동" 항목을 반드시 추가할 것.** 이미 익명으로 쓰고 있는
사용자는 로그인 화면을 다시 보지 않는다. 로그인 화면만 고치면 **기존 참가자
전원이 해당되지 않는다.**

- `settings_screen.dart` — 미연동이면 "Google 계정 연동", 연동됐으면 이메일 표시
- `login_screen.dart` — 지금 "Google로 계속하기" 버튼이 `_signInAnonymously`에
  연결된 자리표시자다. 실제 구글 흐름으로 교체한다

카카오·네이버 버튼은 그대로 "준비 중"으로 둔다(E.4 참조).

## ✅ E단계 관문

1. 익명 상태에서 연동 → **uid가 그대로**이고 옷장이 유지된다
2. 앱 삭제 후 재설치 → 같은 구글 계정으로 로그인 → 옷장과 이력이 복원된다
3. 이미 다른 uid에 연결된 구글 계정으로 시도 → 안내가 뜨고 사용자가 선택한다
4. 연동을 하지 않은 사용자도 기존과 동일하게 앱을 쓸 수 있다

**2번이 이 단계의 전부다.** 실기기에서 실제로 지웠다 깔아 확인할 것.

---

## 범위 밖 — 이번에 하지 않는 것

### Storage 경로 분리

`wardrobe_images/{fileName}`은 전역이지만 **이번 범위에서 건드리지 않는다.**

이미지는 Firestore 문서에 저장된 다운로드 URL로만 접근된다. 그 URL은
추측 불가능한 토큰을 포함하고, URL을 얻으려면 Firestore 문서를 읽어야 한다.
D단계로 Firestore가 격리되면 **실질적인 접근 경로가 함께 막힌다.**

반면 경로를 옮기면 기존 문서의 `imageUrl`이 전부 무효가 되어 백필이 한 번 더
필요해진다. 얻는 것에 비해 위험이 크다. 신규 업로드만 `wardrobe_images/{uid}/`로
바꾸는 것은 나중에 별도로 검토한다.

### 카카오·네이버 로그인

Firebase 기본 제공자가 아니라 **커스텀 토큰 발급 서버가 필요하다.**
Cloud Functions 도입이 딸려오므로 이번 범위 밖이다. 구글 하나로 충분하다.

### 임베딩 벡터 분리

옷장 문서에 512차원 벡터가 들어 있어 읽기 1회당 약 1MB가 오간다. 사용자가
늘면 Firestore 전송 한도(월 10GiB)에 먼저 닿는 항목이다. **다만 참가자 20명
규모에서는 여유가 있으므로** 이번엔 하지 않고, 사용량을 모니터링한다.

---

## 금지 사항

- **`linkWithCredential` 대신 `signInWithCredential`을 쓰지 말 것.**
  uid가 바뀌어 기존 데이터가 전부 고아가 된다.
- **백필 전에 규칙을 배포하지 말 것.** 백필 자체가 불가능해진다.
- **인덱스 빌드 완료 전에 앱을 릴리스하지 말 것.** 쿼리가 실패한다.
- 백필 스크립트를 `--apply` 기본값으로 만들지 말 것.
- `wardrobeStream()`에 빈 문자열이나 임의 uid를 넘기지 말 것. uid가 없으면
  스트림을 만들지 않는다.
- `firebase deploy` 전에 `firebase use` 확인을 건너뛰지 말 것.
- 참가자 데이터를 개별 식별 가능한 형태로 출력하거나 공유하지 말 것.
- 각 단계의 관문을 통과하기 전에 다음 단계를 시작하지 말 것.

---

## 완료 보고 형식

**D단계**
1. `flutter analyze` / `flutter test` 결과
2. 백필 dry-run 출력과 `--apply` 후 검증 결과(누락 0건)
3. 변경 파일 목록
4. 관문 1~6 각각의 통과 여부. 실패 항목은 어디서 어떻게 막혔는지
5. 규칙 배포 시 `firebase use` 확인 결과

**F단계**
1. App Distribution 테스터 수와 설치 확인 수
2. **다른 사용자의 옷장이 보이지 않음**을 확인한 방법과 결과
3. 안내문 전문과 동의 확인 방식
4. 집계 스크립트의 첫 출력(사용자 식별자는 순번으로)

**E단계**
1. 관문 1~4 각각의 통과 여부
2. 재설치 후 복원 확인 화면
3. `credential-already-in-use` 경로를 실제로 재현했는지
