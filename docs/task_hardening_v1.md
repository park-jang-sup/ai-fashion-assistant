# 작업 지시서 — 보안 하드닝 1~4 (task_hardening_v1)

## 0. 이 작업의 목적과 범위

코드 리뷰(2026-07-31)에서 나온 항목 중 **마이그레이션이 필요 없고 데모 옷장을 깨뜨리지 않는 것**만 골라 4건을 처리한다. 각 항목은 독립적이므로 **1 → 2 → 3 → 4 순서로 하나씩, 커밋도 하나씩** 나눈다. 한 번에 몰아서 커밋하지 말 것 — 이 저장소는 릴리스에서만 터지는 결함을 두 번 겪었고, 그때 A/B/C 단계로 쪼갠 것이 실제로 값을 했다.

### 범위 밖 (건드리지 말 것)

- **Storage 경로 격리(`wardrobe_images/{uid}/...`) 및 `demo_images/` 분리** — 다음 단계다. `demo_wardrobe`가 원본 `imageUrl`을 재사용하는 설계라 지금 경로를 조이면 데모가 깨진다.
- **서버 이전, 평가 하네스, 임베딩 타이브레이크, 축 B** — 전부 이후 작업.
- **App Check 프로바이더 변경** — 릴리스 키스토어 정리와 순서가 얽혀 있어 이번에 하지 않는다.
- **R8/minify, `tflite_flutter` 제거, split-per-abi** — APK 용량은 이번 범위 밖으로 이미 결정됨.
- **상태 관리 라이브러리 도입, 화면 파일 분할, 서비스 인스턴스화** — 별건이다.
- 기존 `TpoMatchPolicy` 기본값, 추천 엔진 로직, 백그라운드 에이전트 로직은 **한 줄도 바꾸지 않는다.**

### 공통 규칙

- 주석은 한국어로, **"무엇을"이 아니라 "왜 이렇게"**를 적는다. 이 저장소의 기존 주석 스타일을 따를 것.
- **새 의존성을 추가하지 않는다.** 지금 있는 것으로 되면 그걸로 한다(`background_agent.dart`가 `shared_preferences` 대신 `path_provider`를 쓴 것과 같은 판단).
- 작업이 끝날 때마다 `flutter analyze`와 `flutter test`를 돌린다. **테스트 140개가 계속 통과해야 한다.** 통과 수가 줄면 그건 완료가 아니다.
- 테스트가 깨지면 테스트를 약화시켜 통과시키지 말고, 왜 깨졌는지 보고할 것.
- 폴백 방향은 항상 **"아무것도 하지 않음"**이다. 실패했을 때 대충 다른 값을 넣는 코드를 새로 만들지 말 것.

---

## 작업 1 — Storage 파일명 난수화 + 프리픽스별 크기·타입 제한

### 왜

`lib/services/storage_service.dart`가 업로드 파일명을 `DateTime.now().millisecondsSinceEpoch`로 만든다. `storage.rules`가 `allow read: if request.auth != null`(소유자 검사 없음)이므로, **인증만 한 사람이면 누구나 파일명을 순회해 남의 옷장 사진을 읽을 수 있다.** 탐색 공간이 하루 8,640만 개라 난수 이름과 비교가 안 된다.

지금 옷장에 올라간 전신 사진 4건은 본인 사진이 아니라 모델 사진이라 당장 유출되는 개인정보는 없다. 하지만 **가상 피팅은 이 앱의 간판 기능이고, 사용자가 자기 전신 사진을 올리는 것이 정상 사용 경로다.** 그 순간 원본 전신 사진이 열거 가능한 자리에 들어간다.

파일명만 바꾸면 마이그레이션이 0이고 데모도 안 깨진다. 덤으로 **갤러리 다중 선택 시 같은 밀리초에 두 장이 올라가 조용히 덮어써지는 충돌**도 함께 사라진다.

### 바꿀 것

**(a) `lib/services/storage_service.dart`**

`uploadWardrobeImage()`와 `uploadWardrobeCutout()`의 파일명을 128비트 난수 hex로 바꾼다. `uuid` 패키지를 새로 넣지 말고 `dart:math`의 `Random.secure()`로 만든다 — 의존성 추가 없이 충분하다.

```dart
// 파일명이 밀리초 타임스탬프였을 때는 (1) 인증만 하면 순회로 남의 사진을
// 읽을 수 있었고 (2) 다중 선택 업로드에서 같은 밀리초 충돌로 덮어써졌다.
// 규칙(storage.rules)에 소유자 검사를 넣는 쪽은 demo_wardrobe가 원본
// imageUrl 재사용에 의존해 데모를 깨뜨리므로, 마이그레이션 0인 파일명
// 난수화를 먼저 한다. 128비트면 충돌·추측 둘 다 실질적으로 불가능하다.
static String _randomFileStem() {
  final rnd = Random.secure();
  return List<int>.generate(16, (_) => rnd.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}
```

**`uploadFittingResult()`의 파일명은 바꾸지 않는다.** 거기 쓰이는 `cacheKey`는 난수가 아니라 "사용자 사진 + 옷 조합"의 SHA-256이고, **같은 조합이면 같은 경로에 덮어써지는 것이 캐시의 의도된 동작**이다. 난수로 바꾸면 캐시가 매번 새 파일을 만들어 기능이 망가진다.

`deleteWardrobeImage()`는 `refFromURL(imageUrl)`로 지우므로 파일명 규칙과 무관하다. **손대지 말 것.**

**(b) `storage.rules`** — 프리픽스별로 크기·타입 제한을 넣는다.

```
match /wardrobe_images/{fileName} {
  allow read: if request.auth != null;
  allow write: if request.auth != null && isValidImage(10);
}
match /wardrobe_cutouts/{fileName} {
  allow read: if request.auth != null;
  allow write: if request.auth != null && isValidImage(20);
}
match /fitting_results/{fileName} {
  allow read: if request.auth != null;
  allow write: if request.auth != null && isValidImage(10);
}
```

> **실측 후 정정(2026-07-31):** 콘솔에서 `wardrobe_cutouts/` 15건을 확인한 결과
> 실제 크기는 50KB~368KB였다. 알파 PNG는 투명 영역이 잘 압축돼 예상보다 훨씬 작다.
> 상한을 **20MB → 5MB**로 내린다(관측 최댓값의 약 14배 여유). 표본이 전부 제품
> 사진이라 사용자 직접 촬영본은 더 클 수 있어 4배보다 넉넉하게 잡는다.

상한을 프리픽스마다 다르게 두는 이유를 주석으로 남길 것: `wardrobe_screen.dart`의 `pickImage`가 `imageQuality: 80~85, max 1440~1600`으로 이미 압축하므로 JPEG는 대체로 1MB 미만이지만, **`uploadWardrobeCutout`은 알파 채널이 있는 무손실 PNG라 같은 해상도에서도 몇 MB가 나온다.** 전역 상한을 JPEG 기준으로 조이면 컷아웃 업로드만 조용히 실패하고, 그건 릴리스에서 실제 사진을 찍어봐야 드러난다.

### ⚠ 함정 — 삭제가 막힌다

**Firebase Storage 규칙에는 `create`/`update`/`delete` 구분이 없고 `read`/`write`뿐이다. 그리고 삭제 요청에서는 `request.resource`가 null이다.** 그래서 `allow write: if ... && request.resource.size < X`라고 쓰면 **`deleteWardrobeImage()`가 전부 실패한다.** 옷 삭제 기능이 통째로 죽는다.

헬퍼를 이렇게 만들어 삭제를 통과시킬 것:

```
function isValidImage(maxMb) {
  // 삭제 요청에는 request.resource가 없다 — null 체크가 없으면
  // deleteWardrobeImage()가 전부 permission-denied로 죽는다.
  return request.resource == null
      || (request.resource.size < maxMb * 1024 * 1024
          && request.resource.contentType.matches('image/.*'));
}
```

### 검증

1. `flutter analyze` / `flutter test` 140개 통과.
2. **규칙은 로컬 에뮬레이터로 먼저 확인한다.** 이 저장소는 `firebase.json`에 에뮬레이터 설정이 있고 `main.dart`에 `--dart-define=USE_EMULATOR=true` 경로가 있다.
3. 실기기 릴리스 빌드에서 **반드시 다음 4가지를 직접 해볼 것**: 옷 등록(JPEG) → 배경 제거 컷아웃 업로드(PNG) → **옷 삭제** → 가상 피팅 1회. 삭제를 빼먹으면 위 함정을 놓친다.
4. Firebase 콘솔 Storage에서 새로 올라간 파일명이 hex인지 눈으로 확인.

### 커밋

`fix: Storage 파일명 난수화 + 프리픽스별 크기·타입 제한`

---

## 작업 2 — Firestore 규칙 두 곳

### 왜

**(a) `wardrobe` update가 `ownerUid` 변경을 막지 않는다.**

```
allow update, delete: if request.auth != null
                      && resource.data.ownerUid == request.auth.uid;
```

`resource`(수정 전)만 보고 `request.resource`(수정 후)를 안 본다. 내 문서의 `ownerUid`를 남의 uid로 바꿔서 **상대 옷장에 아이템을 밀어 넣을 수 있다.** D단계에서 만든 격리가 update 경로로 우회된다.

**(b) `fitting_cache` write에 소유자 검사가 없다.** 키를 아는 사람이 캐시 문서를 덮어써서, 다음 조회 때 다른 이미지가 뜨게 만들 수 있다. 키가 SHA-256이라 실현 가능성은 낮지만, write를 막는 근거가 "만들 수 없다"가 아니라 **"만들었다면 그건 자기 것이다"**여야 하는데 그걸 검사할 필드가 없다.

### 바꿀 것

**(a) `firestore.rules`의 `/wardrobe/{itemId}`** — update와 delete를 분리한다.

```
allow update: if request.auth != null
              && resource.data.ownerUid == request.auth.uid
              && request.resource.data.ownerUid == resource.data.ownerUid;
allow delete: if request.auth != null
              && resource.data.ownerUid == request.auth.uid;
```

**⚠ 반드시 분리할 것.** Firestore도 **삭제 요청에서는 `request.resource`가 null**이라, `allow update, delete`에 묶어둔 채 `request.resource.data.ownerUid`를 검사하면 **옷 삭제가 전부 막힌다.** 작업 1의 Storage 함정과 같은 모양이다.

**(b) `firestore.rules`의 `/fitting_cache/{cacheKey}`**

```
allow get: if request.auth != null;
allow list: if false;
allow create: if request.auth != null
              && request.resource.data.ownerUid == request.auth.uid;
allow update: if request.auth != null
              && resource.data.ownerUid == request.auth.uid
              && request.resource.data.ownerUid == request.auth.uid;
allow delete: if false;
```

`get`을 열어두는 것은 그대로 유지한다 — doc id가 SHA-256이라 열거가 안 되고, `list: if false`가 이미 있다.

**(c) `lib/services/firestore_service.dart`의 `cacheFittingResult`** — `ownerUid`를 쓰도록 시그니처에 uid를 추가한다.

```dart
static Future<void> cacheFittingResult(
    String cacheKey, String imageUrl, String ownerUid) async {
  await _db.collection(_fittingCacheCol).doc(cacheKey).set({
    'imageUrl': imageUrl,
    'createdAt': FieldValue.serverTimestamp(),
    'ownerUid': ownerUid,
  });
}
```

**(d) 호출부 `lib/services/fitting_job_controller.dart`의 `_cacheFittingResultSilently`** — uid를 넘긴다. 같은 파일 안에서 이미 `FirebaseAuth.instance.currentUser?.uid`를 여러 번 쓰고 있으니 그 패턴을 그대로 따를 것. **uid가 null이면 캐시 저장을 조용히 건너뛴다**(폴백 = 아무것도 하지 않음). 이 함수는 원래 실패해도 무시하는 부가 작업이므로 예외를 새로 던지지 말 것.

### ⚠ 기존 캐시 문서

이미 만들어진 `fitting_cache` 문서들에는 `ownerUid` 필드가 없다. 새 `allow update` 규칙은 `resource.data.ownerUid == request.auth.uid`를 요구하므로 **그 문서들은 갱신이 안 된다**(읽기는 `get`이 열려 있어 계속 된다).

의미 있는 영향은 "이미 캐시된 조합을 `forceRegenerate`로 다시 생성했을 때 캐시 갱신만 조용히 실패"하는 것뿐이고, 그 경로는 원래 실패를 무시하는 구조다. **따로 마이그레이션하지 말고 이대로 둔다.** 이 판단을 규칙 주석에 남길 것.

### 검증

1. `flutter analyze` / `flutter test` 140개 통과.
2. 에뮬레이터에서: 자기 옷 수정 성공 / `ownerUid`를 다른 값으로 바꾸는 update 실패 / **옷 삭제 성공**(함정 확인) / 가상 피팅 후 `fitting_cache` 문서에 `ownerUid`가 붙는지 확인.

### 커밋

`fix: wardrobe update의 ownerUid 변조 차단 + fitting_cache 소유자 검사`

---

## 작업 3 — 표기 정리 3종

전부 문자열 수정이라 한 커밋으로 묶어도 된다. **로직은 건드리지 않는다.**

### (a) 브랜드 표기 통일 → `DOT`

| 파일 | 현재 | 변경 |
|---|---|---|
| `android/app/src/main/AndroidManifest.xml:18` | `android:label="ai_fashion_assistant"` | `android:label="DOT"` |
| `lib/main.dart:120` | `title: 'StyleAI'` | `title: 'DOT'` |
| `lib/screens/login_screen.dart:82` | `'DOT.'` | `'DOT'` |
| `lib/screens/settings_screen.dart:186` | `applicationName: 'DOT.'` | `applicationName: 'DOT'` |

지금 한 빌드 안에 이름이 세 개다. **심사위원이 APK를 설치하면 런처 아이콘 아래에 `ai_fashion_assistant`가 뜬다.**

- 주석 안의 `"DOT." 레퍼런스 디자인` 표현(`home_screen.dart:15`, `settings_screen.dart:18`)은 과거 디자인 이름을 가리키는 서술이므로 **바꾸지 않는다.**
- **팀명 `D.O.T(디오티)`는 그대로 유지한다.** 저장소에 나오면 손대지 말 것.
- `applicationId`/`namespace`(`com.fashionai.ai_fashion_assistant`)는 **절대 바꾸지 않는다.** 바꾸면 Firebase 등록·설치 기기의 앱 동일성이 깨진다.

### (b) 데모 시드 로딩 문구

`lib/screens/wardrobe_screen.dart:823`에 `'118벌을 준비하고 있어요, 잠시만 기다려 주세요'`가 하드코딩되어 있다. 실제 데모 옷장은 **119벌**이다.

**119로 고치지 말고, 숫자를 문구에서 빼라.** `'데모 옷장을 준비하고 있어요, 잠시만 기다려 주세요'`로 바꾼다. 결과 스낵바가 이미 `seedDemoWardrobe()`의 실제 반환값으로 정확한 수를 보여주므로, 로딩 문구에 숫자를 박아둘 이유가 없다 — 지금 틀린 이유가 정확히 사람이 두 곳의 숫자를 손으로 맞춰야 했기 때문이다.

`lib/services/firestore_service.dart`의 주석에도 118이 3곳 있다(`seedDemoWardrobe`·`clearDemoWardrobe` 근처). **주석의 숫자도 "119" 대신 "데모 옷장 전량"처럼 수를 안 박는 표현으로** 고칠 것. 배치 상한 500과 비교하는 맥락이라 정확한 수가 필요 없다.

### (c) 프롬프트 성별 전제 제거

`lib/services/gemini_service.dart`의 프롬프트 3곳(대략 625·668·713행)이 이렇게 시작한다:

```
당신은 세련된 중년 남성을 위한 전문 패션 스타일리스트입니다.
```

`UserProfile`에는 **성별 필드 자체가 없다**(키·몸무게·퍼스널컬러·체형·허리·가슴·선호스타일 7개뿐). 그래서 값을 흘려보내는 방식은 지금 불가능하고, **이번 범위는 문장을 중립으로 바꾸는 것까지**다.

```
당신은 전문 패션 스타일리스트입니다.
```

- `gemini_service.dart` 전체에서 `남성`·`여성`·`중년` 등 대상 사용자를 좁히는 표현을 **grep으로 전수 확인**하고 같이 정리할 것. 자기 평가(`OutfitSelfEvaluator`)용 프롬프트도 대상이다.
- **출력 형식 지시([점수]/[분위기점수]/[분위기] 규칙, 40자 제한 등)는 한 글자도 바꾸지 않는다.** 파싱이 그 형식에 의존한다.
- `UserProfile`에 성별 필드를 **추가하지 말 것.** 별건이고 UI·Firestore·프롬프트가 같이 움직여야 한다.

### (d) firestore.rules의 demo_wardrobe 주석 정정

`firestore.rules`의 `match /demo_wardrobe/{itemId}` **바로 위 주석 4줄**(대략 73~76행)이
사실과 다르다. 현재 문구:

    // imageUrl/cutoutImageUrl은 원본 wardrobe 문서 값을 그대로 재사용한다 —
    // storage.rules가 wardrobe_images/wardrobe_cutouts를 request.auth != null
    // read로 열어두고 있어 인증된 다른 계정에서도 로드된다는 성질에 기댄다.
    // Storage를 사용자별로 조이면 데모 이미지도 함께 깨진다.

**실측으로 반증됐다.** 매칭되는 `match` 블록이 아예 없어 기본 거부인 **버킷 루트**의
파일을, 그 다운로드 URL로 **로그아웃 상태 브라우저**에서 열었더니 정상 표시됐다.
Firebase Storage의 다운로드 토큰(`?alt=media&token=`)은 보안 규칙을 우회한다.

즉 데모 이미지가 로드되는 이유는 `storage.rules`의 read 규칙이 아니라
Firestore에 저장된 절대 다운로드 URL이다. **Storage 경로를 uid별로 조여도
데모는 깨지지 않는다.**

이 주석을 위 사실에 맞게 다시 쓰고, 근거(로그아웃 브라우저 실측)를 함께 남겨라.
같은 잘못된 전제로 다시 설계하지 않게 하는 것이 목적이므로 근거를 빼지 말 것.

**주석만 고친다. `allow` 규칙은 한 줄도 바꾸지 않는다.**
데모의 읽기 전용 성질(`allow read: if request.auth != null; allow write: if false;`)은
그대로 유지한다. Storage 경로 격리는 이 지시서의 범위 밖이다.

### 검증

`flutter analyze` / `flutter test` 140개 통과 + 릴리스 빌드 설치 후 **런처 아이콘 이름이 `DOT`인지 확인**(라벨은 재설치해야 반영된다). 가상 피팅 1회 돌려 응답 파싱이 여전히 정상인지 확인.

### 커밋

`chore: 브랜드 표기 DOT 통일, 데모 로딩 문구 숫자 제거, 프롬프트 성별 전제 제거`

---

## 작업 4 — CI (analyze + test)

### 왜

`.github`가 없다. 지금 테스트 수·파일 수를 사람이 손으로 세고 있고, 그래서 문서마다 93/132/137/140으로 흔들렸다. 워크플로 하나면 **매 푸시마다 자동으로 확정되는 사실**이 된다.

### 바꿀 것

`.github/workflows/ci.yml` 생성:

```yaml
name: CI
on:
  push:
  pull_request:

jobs:
  analyze-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: <로컬과 동일한 버전으로 고정>
          channel: stable
      - run: cp lib/config/env.example.dart lib/config/env.dart
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
```

### ⚠ 함정 1 — `env.dart`가 없어서 analyze가 깨진다

`lib/config/env.dart`는 `.gitignore` 대상(Gemini 키)이라 CI 체크아웃에 존재하지 않는다. `gemini_service.dart`가 이걸 import하므로 **`flutter analyze`가 즉시 실패한다.**

`lib/config/env.example.dart`를 **새로 만들어 커밋**한다(빈 문자열 상수). 위 워크플로의 `cp` 단계가 이걸 `env.dart`로 복사한다. 실제 키는 여전히 저장소에 안 들어간다.

`.gitignore`의 `lib/config/env.dart` 줄은 **그대로 두고**, example 파일이 무시되지 않는지 확인할 것.

### ⚠ 함정 2 — CI의 테스트 수는 로컬과 다르다

`test/tpo_policy_report_test.dart`와 `test/color_rule_verification_test.dart`가 `tools/export_for_kaggle/output/items.json` 존재 여부로 등록을 가른다. 이 파일은 `.gitignore` 대상이라 **CI에는 없다** → `skip:` 경로로 떨어진다.

즉 **CI의 통과 수가 로컬 140과 다르게 나오는 것이 정상이다.** 실패가 아니다. 이 사실을 워크플로 주석이나 README에 남겨서, 나중에 숫자를 인용할 때 헷갈리지 않게 할 것.

### ⚠ 함정 3 — analyze의 기존 info 1건

로컬 `flutter analyze`에 info 1건이 이미 있다. CI가 이것 때문에 실패하면 두 가지 중 하나를 고른다:

1. 그 info를 실제로 고친다 (선호)
2. 못 고칠 사정이 있으면 워크플로에 `flutter analyze --no-fatal-infos`

**어느 쪽을 골랐는지와 이유를 보고할 것.** 조용히 2번으로 넘어가지 말 것.

### 검증

푸시해서 실제로 초록불이 뜨는 것까지 확인한다. **로컬에서 통과한다는 것은 검증이 아니다** — 이 작업의 목적 자체가 로컬과 CI의 차이를 드러내는 것이다.

### 커밋

`ci: flutter analyze + test 워크플로 추가`

---

## 사용자만 할 수 있는 일 (Claude Code가 하지 말 것)

1. **`firebase deploy --only firestore:rules,storage:rules`** — 배포 전에 반드시 `firebase use`로 활성 프로젝트를 확인한다. 이 저장소는 전역 캐시의 다른 프로젝트로 오배포된 사고 전례가 있다.
2. **릴리스 APK 빌드 + `adb install -r`** — `uninstall` 금지. 로컬 발화 카운터 파일·WorkManager 예약·익명 식별자가 날아가고, 진행 중인 F′.3 발화 표본(t0 = 2026-07-31 09:09:13)이 리셋된다.
3. **실기기 검증 4종**(작업 1) 및 런처 라벨 확인(작업 3).

## 보고 형식

각 작업이 끝날 때마다 다음을 보고할 것:

- 바꾼 파일 목록과 각각의 한 줄 요약
- `flutter analyze` 결과, `flutter test` 통과 수
- **지시서와 다르게 판단한 지점이 있으면 그 이유** — 특히 위 함정 5개 중 실제로 밟은 것이 있으면 반드시 명시
- 사용자가 실기기에서 확인해야 할 항목

-전부 완료-(끝난 작업)