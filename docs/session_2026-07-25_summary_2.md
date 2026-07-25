# 작업 정리 (2026-07-25 세션 2 — CLIP 임베딩 A단계 + 궁합 규칙 보강(전체) + 스파이크 정리 + Firebase 개인 프로젝트 이관(iOS 포함) + 궁합 규칙 실기기 검증)

`docs/session_2026-07-25_summary.md`(세션 1, CLIP 임베딩 채택+백필)를 이어받아
브랜치 `feature/clip-embedding-spike` 위에서 계속 작업. 이번 세션은 전부
커밋/push 완료된 상태 — 미완료 워킹트리 변경 없음. 세션 막바지에 팀
Firebase에서 개인 Firebase로 실제 이관을 끝내고, 그 위에서 궁합 색상
규칙까지 실기기로 실검증(유채색 옷 여러 벌 등록)해 결론을 냈다. **세션
맨 끝에 `feature/clip-embedding-spike`를 `main`으로 통합하고 원본
저장소(`origin`) 리모트를 아예 제거**했다(§8) — 다음 세션부턴 `main`
브랜치, `personal` 리모트 하나로만 작업하면 된다.

## 1. CLIP 임베딩 통합 A단계 — 같은 카테고리 내 유사 옷 검색

- 목표: 백필된 `embedding` 필드를 앱이 처음으로 읽어 쓰는 좁은 범위(RAG/궁합
  매칭은 의도적으로 제외, "옷↔옷 유사도"만).
- `lib/models/wardrobe_item.dart`: `embedding`(nullable `List<double>`)
  필드 추가, `fromFirestore()`에서 `embedding.vector` 파싱.
- `lib/services/embedding_service.dart`(신규): `cosineSimilarity()`(스파이크
  코드 포팅, null/길이불일치 방어), `findSimilarItems()`(같은 category만,
  embedding 있는 것만, 자기 자신 제외, top-N).
- 검증: `lib/debug/similarity_check.dart` + `main.dart`의
  `--dart-define=RUN_SIMILARITY_CHECK=true` 진입점(스파이크와 같은 패턴,
  실제 구현은 별도 파일로 분리해 `main.dart`는 깨끗하게 유지).
  `SIMILARITY_CHECK_ITEM_ID`로 단건 상세 출력도 가능.
- 실기기(SM S918N) 검증 결과: 전체 옷장 103벌 중 embedding 있음 99벌(백필
  기록과 일치), **카테고리 불일치 0건**(99개 헤더 × 최대 5개 결과 전수
  교차검사), 검정 슬랙스류가 검정/차콜끼리 묶이는 것 육안 확인. (첫 로그
  캡처 시 필터링 실수로 결과 줄이 안 보였던 해프닝 있었음 — `adb logcat -d`
  직접 덤프로 복구, 앱 코드 자체는 문제없었음.)
- 커밋: `ab77929`(feat, 파싱+검색 로직), `45ce92d`(debug, 검증 진입점을
  `lib/debug/`로 분리한 이유 포함).

## 2. 궁합 규칙 조사 + 보강 (findCandidateMatches 경로)

### 조사 결과(수정 전)
- `OutfitMatcher._compatibilityScore`가 실제로 쓰는 속성은 **color와
  formality 둘뿐**(matcher_spec.md와 코드가 정확히 일치 확인).
- color는 Gemini가 매번 새로 생성하는 자유 텍스트 — 고정 축(밝기/웜쿨/채도)
  없음.
- **버그 발견**: `_neutralColors`에 '회색'뿐 아니라 **'차콜'도 빠져있었음**
  (원본엔 화이트/블랙/네이비/그레이/베이지/아이보리/카키/그레이지 8개뿐).
  실옷장에 차콜이 매우 흔해서 영향 범위가 컸음.
- Gemini 자기평가 프롬프트의 `[색상조화]`는 "1~100점" 한 줄뿐 — 루브릭
  전혀 없이 완전히 "알아서 판단".

### 설계 → 구현
- `lib/services/color_taxonomy.dart`(신규): 색상 라벨 →
  `{family, brightness, temperature, isNeutral}` 정규화. 3단 매칭(정확
  매칭 → 부분 문자열 매칭 → 중립 폴백). 24개 관측/예상 라벨 커버, family
  8종(wine/red/orange/yellow/green/blue/pink/brown), 색상군 궁합 매트릭스
  포함(brown은 서브뉴트럴처럼 대부분 +1).
- `OutfitMatcher._colorScore`: 무채색 와일드카드(+2, 이제 회색/차콜 포함) →
  같은 family+밝기 같음(-1, 단 pattern 다르면 0으로 완화) → 같은
  family+밝기 다름(톤온톤 +1) → 다른 family+밝기 같음(톤인톤 +1) → 다른
  family+밝기 다름(매트릭스 조회 -1/0/+1).
- `_paletteAdjustment`: 조합 내 유채색 4벌(3벌 초과)이면 -1,
  `findCandidateMatches`에만 적용(`findForTpo`/`_buildCombosFromRanked`는
  스케일이 달라 이번엔 제외).
- Gemini 프롬프트에 같은 원칙을 2~3줄 루브릭으로 동기화(무채색 와일드카드,
  유채색 3개 이하, 톤온톤/톤인톤).
- **커밋을 실제로 분리**: `19442a4`(fix, 회색/차콜 버그수정만 — family/매트릭스
  없이 무채색 판정만 교체) → `747e9a9`(feat, family/매트릭스/톤온톤/팔레트
  추가). 워킹트리를 fix 상태로 임시 축소해 커밋하고 다시 복원해 feat
  커밋하는 방식으로, 진짜로 분리된 git diff를 만듦.

### 검증 — 실옷장(103벌) + 합성 데이터 이중 검증
- `test/color_taxonomy_test.dart`: 정규화 테이블 단위 검증(24라벨 exact +
  substring 케이스), 매트릭스 대칭성 등 38개 assertion.
- `test/color_rule_verification_test.dart` + `test/support/{wardrobe_fixture,
  legacy_matcher}.dart`: 실옷장 기반 전/후 diff. `items.json`(gitignore
  대상)이 로컬에 없으면 자동 skip하도록 가드 처리.
  - `findForTpo` 전/후 완전 동일 확인(당시엔 손 안 댔으므로 회귀 없음 —
    이후 §3에서 findForTpo 자체를 고치면서 이 assert는 diff 리포트로
    교체됨).
  - 버그수정(회색/차콜)만으로 1번 후보 변경: **10건**.
  - 새 색상 규칙(매트릭스/톤온톤 등)으로 1번 후보 변경: **0건** — 버그가
    아니라 이 옷장이 무채색 편중이라 규칙이 끼어들 기회 자체가 적었던 것
    (색상 점수 분포 2834쌍 중 2786쌍이 무채색 와일드카드 +2).
  - 유채색-유채색 쌍 중 감점(-1) 비율 10.4%(30% 경고선 밑, 과하지 않음).
    팔레트 감점은 0/261(이 데이터셋에선 사실상 잠자는 규칙).
- `test/color_rule_synthetic_test.dart`(커밋 `1b72219`): 위 "0건"이 버그인지
  데이터 특성인지 구분하기 위해 통제된 유채색으로 8개 시나리오(톤온톤/
  깔맞춤감점/패턴완화/톤인톤/매트릭스 감점·보너스/팔레트/통합) 전부 의도한
  점수 그대로 통과. 특히 통합 시나리오에서 브라운 트리거 기준 "규칙 전
  exact-color 매치(로컬 9.0)가 이김 → 규칙 후 톤온톤 카멜(로컬 11.0)이
  역전"을 실제로 재현해, 유채색이 늘면 규칙이 진짜로 작동함을 입증.

## 3. findForTpo/outfit_reason의 회색·차콜 버그 마저 수정 (커밋 `5e125ce`)

§2에서 의도적으로 남겨뒀던 잔존 이슈 — `findForTpo`와
`lib/constants/outfit_reason.dart`가 여전히 옛 `_neutralColors`(회색/차콜
없음)를 참조하던 것을 이번 세션 안에서 마저 고쳤다.

- `OutfitMatcher._neutralColors`/`neutralColors` getter를 삭제하고 공개
  래퍼 `isNeutralColor(color) => ColorTaxonomy.resolve(color).isNeutral`로
  통일. `findForTpo`의 무채색 보너스, `outfit_reason.dart`의 색상 관계
  판단 둘 다 이걸 쓰도록 교체 — **isNeutral 판정 소스만 바꾸고 다른 로직은
  전혀 안 건드림**.
- 영향 범위가 경로마다 다름:
  - `findForTpo`: 점수·후보 구성에 실제로 영향(회색/차콜이 무채색
    보너스를 받아 카테고리별 2·3번 슬롯 후보가 바뀜). 실옷장 검증 결과
    캐주얼/세미포멀/포멀 3개 격식 전부 후보 구성이 바뀌었지만 1번 후보는
    이 옷장에서는 동일, `isFallback` 플립도 관측 안 됨.
  - `outfit_reason.dart`: 매칭 결과(추천)엔 영향 없고 설명 문구만 정확해짐
    (예: 차콜+회색 조합 설명이 "판단 보류(null)" → "둘 다 활용도 높은
    기본 톤이라 실패 없는 조합이에요"로).
- 검증: `test/support/legacy_matcher.dart`에 `legacyFindForTpo`(옛
  neutralColors 세트로 재구현) 추가해 실제 `findForTpo`와 diff — 3개
  격식 전부에서 diff에 관련된 색상이 반드시 회색/차콜을 포함하는지 assert
  (그 외 로직이 안 샜음을 확인). `test/outfit_reason_test.dart`(신규)로
  텍스트 샘플 4건 전/후 비교.
- `test/color_rule_verification_test.dart`의 "항목4"는 원래 "findForTpo
  전/후 완전 동일" assert였는데, 이번엔 의도적으로 바꾸는 거라 그 가정이
  깨짐 — diff 리포트 방식으로 교체.

## 4. `lib/spike/` 정리 (커밋 `fb237e7`)

- CLIP은 서버사이드로 확정됐고, 조사 결과 `embed()`가 `[1, outputDim]`
  벡터 출력을 하드코딩해서 배경제거 세그멘테이션 모델(`[1,H,W,C]` 마스크
  출력)에 애초에 재활용 불가 — **코드는 삭제, 검증된 사실만 문서 보존**.
- 삭제: `lib/spike/` 전체(3파일), `main.dart`의 `RUN_EMBEDDING_SPIKE`
  분기+import, `pubspec.yaml`의 `assets/spike_models/` 등록, 모델 파일
  (13MB).
- 유지: `pubspec.yaml`의 `tflite_flutter` 의존성(release 안정성 검증 완료,
  배경제거 ONNX→TFLite 교체 후보 — 지금 빼면 다음 스파이크 때 안정성
  검증을 처음부터 다시 해야 함).
- 신규 `docs/tflite_background_removal_spike_notes.md`: release 안정성
  검증 수치(콜드스타트 4회×20반복×3장=240회 크래시 0), asset 로딩 우회
  패턴(`rootBundle.load`+`Interpreter.fromBuffer`), 현재 ONNX 배경제거가
  release에서 죽는 이유(JNI 크래시 상세, `onnxruntime-android` 1.23.0
  버그로 확정, `wardrobe_screen.dart:160-180` 링크), 다음 스파이크가 새로
  짜야 할 부분(세그멘테이션 출력/후처리, 모델 후보 조사 자체가 안 됨).
- `flutter analyze` 클린, `flutter build apk --debug` 성공, 전체 테스트
  스위트(56개) 통과 확인.

## 5. Firebase 팀(eb206) → 개인(personal) 프로젝트 이관 (커밋 `9ca1a1a`)

옷장 데이터만 개인 Firebase 프로젝트로 옮기는 작업. 이력(`users`/
`recommendations` 등)은 이관 대상이 아니었음.

### 조사
- `wardrobe`는 uid 하위가 아니라 **최상위 전역 컬렉션**(모든 로그인
  사용자가 공유). 이미지 필드는 `imageUrl`(필수)+`cutoutImageUrl`(선택)
  둘뿐, 값은 **절대 다운로드 URL**(`getDownloadURL()` 결과, 토큰 포함) —
  Storage 경로만 저장하고 조합하는 방식이 아니라서 이관 시 URL을 통째로
  새로 만들어야 함.
- Storage 경로: `wardrobe_images/{timestamp}.jpg`,
  `wardrobe_cutouts/{timestamp}.png` — 파일명이 문서 id가 아니라 타임스탬프
  라 URL 자체를 파싱하지 않으면 어떤 파일이 어느 옷인지 알 방법이 없음.
- 프로젝트 id/버킷이 하드코딩된 곳 5곳: `.firebaserc`, `firebase.json`,
  `lib/firebase_options.dart`, `android/app/google-services.json`,
  `ios/Runner/GoogleService-Info.plist` — 전부 `flutterfire configure`로
  갈아끼워지는 대상.

### 이관 스크립트 — `tools/migrate_to_personal/migrate.py`(신규)
- 안전 원칙: 소스(팀)는 항상 read-only(코드 안에서 `source_db`/
  `source_bucket`엔 읽기 메서드만 호출되고 쓰기는 전부 `dest_db`/
  `dest_bucket`에만 — grep으로 리뷰 가능하게 설계), dry-run 기본,
  `--apply` 시 "SOURCE {id}(읽기) → DEST {id}(쓰기)"를 출력하고 대상
  프로젝트 id를 직접 입력해야 진행, 서비스 계정 키는
  `--source-credentials`/`--dest-credentials`로만 받고 저장소 내부 경로면
  거부.
- 핵심 기술: `export.py`의 `storage_path_from_url()` 재사용해 다운로드
  URL → 오브젝트 경로 추출 → 원본 화질 그대로 다운로드 → 대상 Storage
  같은 경로에 업로드하며 `firebaseStorageDownloadTokens` 메타데이터에
  새 UUID 세팅 → 같은 형식(`?alt=media&token=...`)의 새 URL 조립 → 실제
  GET 요청으로 200+image/* 검증.
- 견고성: 이미지 필드를 이름으로 못박지 않고 값 자체가 Storage URL로
  파싱되는지로 판별(`discover_image_fields`) — 필드 구성이 문서마다
  달라도 놓치지 않음. `imageUrl`(필수) 실패는 문서 전체를 실패 처리,
  `cutoutImageUrl`(선택) 실패는 그 필드만 빼고 계속. 문서 id를 소스와
  동일하게 유지해 재실행 시 이미 이관된 문서는 자동 스킵(resumable).
- 실제 실행 완료: 옷장 이관 성공, 실기기(SM S918N)에서 옷장 104벌 읽기+
  이미지 로드+익명 로그인 전부 정상 동작 확인.

### 이관 후 발견한 잔존 문제 2건
1. **iOS 설정 절반만 갱신됨** — `flutterfire configure`가 android/dart는
   personal로 갱신했는데 `firebase.json`의 ios 블록과
   `GoogleService-Info.plist`는 여전히 eb206. 게다가 Xcode 프로젝트의
   실제 번들 id(`com.yujaehyuk.fashionai.test3462`)는 `firebase_options.dart`
   와는 일치하지만 `GoogleService-Info.plist`(구버전 번들 id)와는 또 다름
   — 세 소스가 다 다른 값을 가진 상태. **iOS는 지금 안 써서 의도적으로
   보류, 다음 작업.**
2. **Firestore 복합 인덱스 누락** — 실기기 테스트 중 홈 화면 "오늘의 추천
   코디" 카드가 빈 상태로 뜨는 버그 발견. 원인 추적 결과
   `recommendationStream()`(`users/{uid}/recommendations`,
   `where('dismissed', ==false) + orderBy('createdAt')`)이 요구하는 복합
   인덱스가 personal 프로젝트에 없어서 쿼리가 `FAILED_PRECONDITION`으로
   조용히 실패(`StreamBuilder`가 `snapshot.hasError`를 안 봐서 그냥 "빈
   추천" UI로 보임 — 콘솔 에러가 안 보이는 이유). AI 비서 활동 내역은
   별개 컬렉션(`agent_logs`, where 없이 orderBy만)이라 정상 표시돼서
   비대칭이 생겼던 것.
   - 저장소에 `firestore.indexes.json` 자체가 없었음(`firebase.json`에도
     `indexes` 키 미등록) — 신규 생성 + `docs/firestore_indexes_notes.md`
     (인덱스-쿼리 대응표, JSON은 주석 불가라 별도 문서로 관리) 추가.
   - `firestore_service.dart` 전체 쿼리(where+orderBy 조합, 다중 orderBy,
     collectionGroup) 전수 감사 — **이 인덱스 하나만 필요**했고 나머지는
     전부 단일필드/같은필드range 패턴이라 안전함을 확인.
   - 배포 전 안전점검에서 **`.firebaserc`는 personal인데 `firebase use`
     (CLI 활성 프로젝트)는 여전히 eb206으로 나오는 불일치 발견** —
     `.firebaserc`를 텍스트 에디터로 직접 고치면 CLI의 별도 로컬 캐시가
     안 갱신되는 게 원인으로 추정. `--project ai-fashion-assistant-personal`
     명시로 우회해서 안전하게 배포 완료, 콘솔에서 인덱스 "사용 설정됨"
     확인 후 홈 화면 정상 동작 재확인함.

### 커밋 전 보안 점검(문제 없음 확인)
- personal 저장소(`park-jang-sup/ai-fashion-assistant`) Private 추정
  (`gh` CLI 없어서 `curl` 비인증 API 요청 → 404로 간접 확인, 100%
  확신하려면 콘솔 육안 확인 권장).
- 서비스 계정 키 파일 스테이징/저장소 내 존재 0건, `.gitignore`에
  `**/*serviceAccount*.json`/`**/*service-account*.json`/
  `**/*firebase-adminsdk*.json` 전부 등록 확인.
- `tools/migrate_to_personal/`에 하드코딩된 실경로/실키 없음(README/
  docstring의 예시 placeholder만).

## 6. 궁합 색상 규칙 실기기 검증 + purple family 보강 (커밋 `69287c4`)

Firebase 이관 후, §2~§3에서 구현한 색상 궁합 규칙이 실옷장·실기기에서
진짜로 작동하는지 유채색 옷을 직접 여러 벌 등록해가며 확인했다. 사전에
`findCandidateMatches`에 관찰 전용 디버그 로그(`[색상]`/`[궁합]`/
`[순위변경]`, `kDebugMode` 가드, 실제 스코어링 로직은 안 건드림)를 임시로
심고 `adb logcat`으로 직접 캡처하는 방식으로 진행했다.

### 검증 결과
- **정규화 테이블**: 실기기에서 관측된 21개 고유 라벨 전부 의도대로 매핑
  성공(실패 0) — 딱 하나 예외가 "퍼플"이었고, 이게 아래 purple family
  추가로 이어짐.
- **색상 규칙이 실제 추천 경로를 타는 것 확인**: 브라운/옐로우 아우터
  등록 시 매트릭스(`brown-yellow=+1`, `brown-blue=+1`, `yellow-brown=+1`
  등)와 톤온톤/톤인톤/같은계열 깔맞춤 감점이 로그로 정확히 관측됨 —
  테스트에서만 확인했던 규칙이 실데이터에서도 그대로 재현됨.
- **`[순위변경]`은 이 옷장에서 구조적으로 발생 안 함**: 브라운/옐로우/
  퍼플/카키/아이보리 등 총 8회 등록 중 단 한 번도 카테고리 1위가 안
  바뀜. 원인은 버그가 아니라 스케일 설계 — 유채색 보너스 최댓값(+1,
  톤온톤/톤인톤/매트릭스)이 무채색 와일드카드(+2)보다 항상 작아서, 경쟁
  카테고리에 무채색이 하나라도 있으면 항상 무채색이 이긴다. 이 옷장은
  상의/하의/신발 전 카테고리에 무채색이 풍부해서 뒤집힐 여지가 없었음.
  `test/color_rule_synthetic_test.dart`의 통합 시나리오(§2)에서 이미
  "유채색 옷장이면 실제로 순위가 바뀐다"를 별도로 증명해뒀으므로, 이번
  "0건"은 데이터 특성 확인으로 결론지음(규칙 자체를 더 손볼 필요 없음).
- **카키/아이보리 등록은 애초에 검증에 부적합했음** — 이 두 색은
  `isNeutral=true`라 자기 자신이 무채색 와일드카드를 트리거해서 family
  규칙이 개입할 여지가 구조적으로 없음(등록 후에 알게 됨, 재시도 없이도
  이유는 로그로 바로 설명 가능했음).
- **네트워크 플레이키니스**: 검증 도중 기기 wifi가 간헐적으로
  끊겨(`UnknownHostException: firestore.googleapis.com`) Firestore/Gemini
  호출이 실패하고 파이프라인이 안 도는 것처럼 보인 적 있었음. `findCandidateMatches`
  자체(로컬 계산, `[색상]`/`[궁합]` 로그)는 네트워크 없이도 동작하므로
  이 부분 검증엔 영향 없었지만, "왜 로그가 안 찍히지" 진단할 때 `adb shell ping`
  으로 네트워크 상태부터 확인하는 게 빨랐음.

### purple family 추가
"퍼플" 아우터가 정규화 테이블에 없어 tier3 폴백(family=null,
isNeutral=false, 원본 문자열 완전 일치만 보는 구버전 방식)으로 조용히
저하되는 걸 실사용 중 발견 — 크래시는 없었지만(안전한 설계) 커버리지
갭이었음.

- 라벨 4개 추가: 퍼플/보라/바이올렛(중간 밝기)/라벤더(밝음).
  temperature는 warm/cool로 못박지 않고 neutral — 퍼플은 레드기/블루기에
  따라 웜쿨이 갈리는 대표색이라 하나로 정하면 톤인톤 규칙에서 억지
  매칭이 생기기 때문.
- 매트릭스에 purple 9번째 family로 추가: blue/pink(인접색)·brown(기존
  서브뉴트럴 우대 정책과 일관)은 +1, yellow(보색이지만 톤다운 여지)는 0,
  근거 약한 나머지(wine/red/orange/green)도 0 — "확실한 것만 값, 애매하면
  0" 원칙.
- `test/color_taxonomy_test.dart`에 라벨 exact-match/temperature/substring/
  매트릭스/대칭성 테스트 전부 반영, 67개 테스트 통과.

### 디버그 로그 처리
검증용 `[색상]`/`[궁합]`/`[순위변경]` 로그는 **한 번도 커밋되지 않고**
워킹트리에서만 존재하다 검증 종료 후 제거됨 — 제거 후 `outfit_matcher.dart`
가 직전 커밋(`5e125ce`)과 완전히 동일해져서 "로그 제거" 커밋 자체가
불필요했음(add+remove가 저장소 히스토리에 흔적을 안 남김).

## 7. iOS Firebase 설정 마무리 (커밋 `8a2d19b`)

§5에서 발견해 "다음 작업"으로 미뤄뒀던 iOS 잔여 설정을 마저 정리했다.

- `flutterfire configure -p ai-fashion-assistant-personal --platforms=ios
  -i com.yujaehyuk.fashionai.test3462 -f -y`(논인터랙티브 플래그로 실행,
  `flutterfire` 실행파일은 PATH에 없어서
  `~/AppData/Local/Pub/Cache/bin/flutterfire.bat` 전체 경로로 호출)를
  돌렸더니 personal 프로젝트의 iOS 앱(이미 등록돼 있었음)은 찾아내고
  `lib/firebase_options.dart`는 정상 갱신했지만, **`GoogleService-Info.plist`
  쓰기와 `firebase.json`의 ios 블록 갱신은 에러 없이 조용히 건너뜀** —
  macOS 전용 Xcode 프로젝트 조작 도구가 Windows 환경엔 없어서로 추정
  (`--ios-out` 명시해도 동일).
- 우회: `flutterfire`가 아니라 **`firebase apps:sdkconfig ios <appId>
  --project ai-fashion-assistant-personal`**(firebase-tools 자체 명령)로
  실제 plist 내용을 XML 그대로 받아와 `ios/Runner/GoogleService-Info.plist`
  에 직접 썼다. `firebase.json`의 ios 블록/`dart.configurations`도 같은
  값으로 수동 반영(후자는 `--platforms=ios` 스코프 때문에 android 항목이
  한 번 지워졌다가 복원됨 — 다행히 `firebase_options.dart`의 실제 android
  `FirebaseOptions` 코드 블록 자체는 안 지워짐, `firebase.json`은 flutterfire
  CLI의 북마크 메타데이터일 뿐이라 앱 런타임엔 영향 없음).
- 최종 확인 4개 소스 전부 일치: `firebase.json`(ios) / `firebase_options.dart`
  (ios) / `GoogleService-Info.plist` / Xcode 실제 빌드 설정
  (`PRODUCT_BUNDLE_IDENTIFIER`) — 전부 `project=personal`,
  `bundle=com.yujaehyuk.fashionai.test3462`.
- 새 plist엔 예전 것에 있던 `CLIENT_ID`/`REVERSED_CLIENT_ID`가 없음 — 이 앱은
  Google 로그인 없이 익명 로그인만 쓰므로(`login_screen.dart`가
  `signInAnonymously()`만 호출) 정상, 문제 아님.
- **iOS 실기기 테스트는 이 작업과 별개로 여전히 불가능** — 개발 환경이
  Windows라 Xcode 자체가 없음(`flutter doctor`에 iOS 툴체인 항목이 아예
  안 뜸, iOS 빌드는 macOS 전용). 설정만 미리 맞춰뒀으니 Mac 환경이
  생기면 바로 빌드/실행 가능한 상태.

## 8. 저장소 구조 정리 — `main` 통합, `origin` 리모트 제거

세션 마지막에 저장소 리모트 구조 자체를 정리했다. `origin`은
`Yujaehyuk3462/ai-fashion-assistant`(원래 팀/원본 저장소, 다른 사람 소유)
였고, `personal`은 본인 소유 `park-jang-sup/ai-fashion-assistant`. 이제
그쪽과 같이 작업하는 게 아니라 완전히 개인 작업으로 전환했다는 판단 하에:

- `feature/clip-embedding-spike`(이번 세션 전체 작업이 쌓인 브랜치)를
  **`personal`의 `main`으로 fast-forward 통합**(커밋 `64cb43e`, 병합
  충돌 0건 — `personal/main`이 feature 브랜치의 직계 조상이라 순수
  fast-forward였음).
- 로컬 `main`도 같은 지점으로 fast-forward하고, 추적(upstream) 대상을
  `origin` → `personal/main`으로 변경. 이후 `git remote remove origin`으로
  **`origin` 리모트 자체를 로컬에서 제거** — 이제 이 저장소엔 `personal`
  하나뿐이라 실수로 원본 저장소에 push할 경로가 물리적으로 없음(GitHub의
  Yujaehyuk3462 저장소 자체엔 전혀 영향 없음, 로컬 git 설정만 지운 것).
- 주의했던 점: 처음엔 로컬 `main`이 `origin/main`보다 뒤처진 줄 알았으나
  실제로는 **반대**(로컬 `main`이 origin에 아직 안 올라간 커밋 3개를
  더 갖고 있었음) — `git log A..B` 방향을 헷갈리면 정반대로 착각하기
  쉬우니 `--is-ancestor`로 실제 조상관계를 직접 확인하는 게 안전함.
- 앞으로는 **`main` 브랜치 하나로만 작업** — `feature/clip-embedding-spike`
  는 `main`과 동일 지점이 된 뒤 실제로 삭제까지 완료(로컬
  `git branch -d`, `personal` 원격 `git push personal --delete`). 삭제 전
  `git merge-base --is-ancestor feature/clip-embedding-spike main`으로
  브랜치가 `main`에 완전히 포함됨(유실 커밋 0개)을 재확인한 뒤 진행. 이제
  로컬/원격 모두 `main` 브랜치 하나만 남음.

## 지켜야 할 작업 원칙 (재확인 + 이번 세션에서 새로 확인된 것)

- (신규) 실데이터(gitignore 대상 export 등)에 의존하는 검증 테스트는
  파일 존재 체크로 자동 skip 가드를 넣을 것 — 안 그러면 다른 클론/CI에서
  hard fail. `test/fixtures/`도 `.gitignore`에 추가(실제 wardrobe item id
  포함이라 로컬 전용 유지).
- (신규) "버그수정 vs 신규기능" 커밋을 정말로 분리하고 싶으면, 코드를
  fix 상태로 임시 축소 → 커밋 → 다시 전체 복원 → 커밋하는 방식으로 실제
  분리된 git diff를 만들 수 있다(메시지만 다르게 쓰는 가짜 분리가 아님).
- (신규) 백그라운드 모니터링용 로그 필터(grep 등)를 짤 때 들여쓰기된
  상세 결과 줄까지 패턴에 포함시킬 것 — 헤더 태그만 매칭하면 본문이
  통째로 걸러진다(이번에 한 번 겪음, `adb logcat -d`로 복구).
- (신규) **`.firebaserc`를 손으로 고치는 것만으로는 부족하다** — `firebase
  use`(인자 없이)로 CLI가 실제로 인식하는 활성 프로젝트를 항상 따로
  확인하고, 배포 명령엔 `--project`를 명시하는 걸 기본 습관으로 삼을 것
  (이번에 실제로 불일치를 겪음).
- (신규) Firestore 프로젝트를 이관할 땐 규칙(`firestore.rules`/
  `storage.rules`)뿐 아니라 **복합 인덱스도 코드(`firestore.indexes.json`)
  로 관리**해야 한다 — 콘솔에서 수동으로 만든 인덱스는 이관 시 안 따라옴.
- (신규) 실기기 로그로 규칙/로직을 검증할 땐, 관찰용 디버그 로그를
  `kDebugMode` 가드로 심고 **검증 끝나면 커밋 없이 그대로 제거**하는
  패턴이 깔끔하다 — 히스토리에 임시 코드 흔적이 안 남는다.
- (신규) 새로 등록한 아이템이 백그라운드 파이프라인 로그에 안 찍히면,
  코드 버그보다 **네트워크 끊김**(기기 wifi 플레이키니스)부터 의심하고
  `adb shell ping <host>`로 확인하는 게 빠르다 — 실제로 이번에 그랬음.
- (신규) **`flutterfire configure`는 Windows에서 iOS 파일 쓰기를 조용히
  건너뛸 수 있다**(에러 없음, 로그에도 티가 안 남) — iOS 설정을 진짜로
  갱신했는지는 `ios/Runner/GoogleService-Info.plist`가 실제로 바뀌었는지
  git diff로 꼭 확인할 것. 안 됐으면 `firebase apps:sdkconfig ios <appId>`
  로 직접 받아와 수동 반영하는 우회로가 있다.
- (기존) Firebase 규칙 배포 등 공유 인프라 변경은 사용자 승인 필요, 코드
  변경 후 항상 `flutter analyze`, 서비스 계정 키는 환경변수/인자로만
  참조하고 저장소 내부 경로는 거부 — 전부 이번 세션에도 계속 지켜짐.

## 다음 세션 시작 시 할 일

1. ~~iOS Firebase 설정 마무리~~ — §7에서 완료(4개 소스 전부 personal로
   일치). 남은 건 **Mac 환경 확보**뿐 — 이 저장소를 Mac에서 clone해서
   `flutter run -d <iOS 기기>` 하면 바로 될 상태.
2. **CLIP 임베딩 RAG 통합**(B단계) — `getRelevantHistorySilently`의
   태그+아이템겹침 기반 관련도 점수를 임베딩 유사도로 보강/교체할지 설계.
   이번 세션엔 손대지 않음.
3. **신규 옷 등록 시 서버사이드 임베딩 생성 경로** — Vertex AI multimodal
   embeddings vs Replicate 중 택일 필요, 아직 미정. 지금은 백필된 99벌
   외엔 embedding이 안 생김(신규 등록분은 계속 null).
4. 배경제거 TFLite 교체 스파이크 — `docs/tflite_background_removal_spike_notes.md`
   참고해서 세그멘테이션 모델 조사부터 새로 시작.
5. (선택, 급하지 않음) personal 프로젝트에서 Firebase App Check API가
   비활성 상태(콘솔에서 활성화 필요) — 지금은 placeholder 토큰 폴백으로
   앱 동작엔 영향 없음.
6. ~~실사용 중 유채색 비중이 늘면 색상 매트릭스 값 재검증~~ — §6에서
   실기기 검증 완료(regex/매트릭스 정상 작동 확인, purple 갭도 메움).
   완료된 항목이라 제거. 다만 이 옷장은 여전히 무채색 편중이라
   `[순위변경]`류 "1번 후보가 실제로 바뀌는" 케이스는 아직 실사용으로는
   못 봤음 — 유채색 비중이 자연히 늘어나면 그때 다시 볼 만함(급하지 않음).

## 참고 파일 위치

- 유사 옷 검색: `lib/services/embedding_service.dart`,
  `lib/debug/similarity_check.dart`
- 색상 궁합 규칙: `lib/services/color_taxonomy.dart`(9개 family, purple
  포함), `lib/services/outfit_matcher.dart`, `lib/constants/outfit_reason.dart`
- 관련 테스트: `test/color_taxonomy_test.dart`,
  `test/color_rule_verification_test.dart`,
  `test/color_rule_synthetic_test.dart`, `test/outfit_reason_test.dart`,
  `test/support/`
- 배경제거 스파이크 메모: `docs/tflite_background_removal_spike_notes.md`
- Firebase 이관 도구: `tools/migrate_to_personal/`
- Firestore 인덱스: `firestore.indexes.json`,
  `docs/firestore_indexes_notes.md`
