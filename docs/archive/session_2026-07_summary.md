

# 작업 정리 (2026-07 세션)

commit `c4704db` 이후 진행된 작업 내역 정리. 아래 내용은 모두 `origin/main`에 커밋·push 완료된 상태(로컬/원격 차이 없음).

## 1. 코디 이력 축적 (에이전트 장기 기억)

- `users/{uid}/history` 서브컬렉션에 코디 사용 이력 축적.
- 저장 시점: 분석 완료, 피팅 이미지 생성 완료, 코디보드 편집 완료(✓) 탭 시.
- 모델: `OutfitHistoryEntry` (type, items, score, createdAt, fittingImageUrl) + `HistoryItemSnapshot`.
- `FirestoreService.addHistoryEntry` / `addHistoryEntrySilently` / `getRecentHistorySilently(uid, {limit})` 추가.
- **버그 수정**: `getRecentHistorySilently`가 실제로는 analyze() 프롬프트에 연결되어 있지 않았던 것을 발견, 연결 완료. 프롬프트에 히스토리 텍스트가 실제로 포함되는지 디버그 로그로 확인.

## 2. 능동 추천 (새 옷 등록 시 자동 코디 추천)

- 새 옷장 아이템 등록 시: 로컬 매칭(API 호출 없음) → 매칭 성공 시 Gemini 1회 호출로 추천 코디 생성 → Firestore 저장 → 홈 화면 카드 노출.
- `lib/services/outfit_matcher.dart` (신규): `OutfitMatcher.findBestMatch()` — formality-rank 근접도 + 무채색 보너스로 로컬 스코어링, API 호출 없음.
- `lib/models/recommendation_entry.dart` (신규): `RecommendationEntry` (id, itemIds, itemSummaries, colorScore, summaryText, triggerItemId, createdAt, dismissed).
- `FirestoreService.addRecommendation(Silently)`, `recommendationStream(uid)`, `dismissRecommendation` 추가.
- **버그 수정**: Firestore 복합 인덱스 누락(`dismissed==false` + `orderBy createdAt`)으로 `FAILED_PRECONDITION` 발생 → 콘솔에서 인덱스 생성으로 해결.
- **환경 이슈**: 파이프라인이 결과 없이 끝나는 문제 → 원인은 코드 버그가 아니라 Gemini API 과부하("high demand") 오류였음을 단계별 디버그 로그로 확인. 이 문제가 반복되면서 최종적으로 "Gemini 모델 폴백" 기능 도입의 직접적 동기가 됨.

## 3. 조용한 catch 블록 로그 보강

- `_extractAndCacheAttributes()`의 로그 없는 `catch (_) {}`에 `debugPrint('[속성추출] 실패: $e')` 추가 (동작은 그대로, 로그만 추가).
- 동일 패턴으로 다른 무로그 catch 블록도 전수 점검 후 로그 추가: `[프로필조회]`, `[히스토리저장]`, `[히스토리조회]`, `[피팅캐시저장]`, `[피팅캐시조회]`, `[스크랩조회]` 등.

## 4. "AI 코디 분석하기" + "AI 가상 피팅 이미지 생성" 원클릭 통합

- `fitting_room_screen.dart`에 `_analyzeAndFit()` 추가: 사용자 사진이 있으면 `Future.wait([_analyze(), _generateFitting()])`로 두 API를 병렬 실행, 없으면 분석만 실행.
- **중요 버그 발견 및 수정**: `FittingJobController`의 `analyze()`/`generateFitting()`가 원래 하나의 `isBusy` 플래그로 재진입을 막고 있어서, 두 작업을 동시에 실행하면 둘 중 하나가 조용히 no-op 되는 동시성 버그가 있었음. `isAnalyzing`/`isGeneratingFitting`으로 플래그를 분리해서 해결 — 이 수정이 없었으면 원클릭 통합 버튼의 "피팅 이미지 생성" 절반이 항상 조용히 실패했을 것.

## 5. 로딩 UX 개편 (전체 화면 오버레이 제거)

- `_buildAnalyzingOverlay()` / `_shouldBlockWithOverlay` 완전히 제거. 분석 중에도 옷 슬롯 조작 가능.
- 결과 카드 안에서 분석 영역과 피팅 이미지 영역이 각각 독립적으로 로딩 상태(회전 문구) 표시 — 먼저 끝난 쪽이 바로 보임.
- 로딩 문구를 `lib/constants/style_tips.dart` (`analysisStyleTips`, `fittingStyleTips`, `allStyleTips`)로 분리, 공유 카운터로 두 영역이 각자 독립적으로 인덱싱.
- 피팅 캐시 뱃지 펼치기/접기 토글 추가 (기본 접힘).

## 6. 홈 화면 실 데이터 연동

- 하드코딩된 목업 "최근 착장" 제거 → `getRecentHistorySilently(uid, limit: 30)`에서 `type == fitting && fittingImageUrl != null` 필터링해 최신 8개 표시. 데이터 없으면 빈 상태 안내 + "AI 피팅 하러 가기" 버튼.
- AI 팁 배너: `allStyleTips`에서 랜덤 1개 문구, State 생성 시 1회만 선택.
- "AI 피팅" 카드 sublabel: `'쇼핑 매치 추천'` → `'가상 피팅·코디 분석'`로 수정 (반영 누락 재확인 후 수정).
- **버그 수정**: `FittingJobController`가 신규 생성(캐시 미스) 시에는 `fittingImageUrl`을 세팅하지 않고 캐시 히트일 때만 세팅하던 문제 발견 → `_cacheFittingResultSilently`를 인스턴스 메서드로 전환해 신규 생성 후에도 `fittingImageUrl` 세팅 + `notifyListeners()` 하도록 수정. (스크랩/최근 착장 기능 모두에 필요한 전제조건이었음)

## 7. 가상 피팅 스크랩 기능

- `lib/models/scrap_entry.dart` (신규): `ScrapEntry` (id, fittingImageUrl, itemIds, itemSummaries, createdAt).
- `firestore.rules`에 `users/{uid}/scraps/{scrapId}` 규칙 추가, **사용자 승인 후** `firebase deploy --only firestore:rules`로 배포 완료.
- `FirestoreService.addScrap`/`deleteScrap` — 명시적 사용자 액션이므로 에러를 삼키지 않고 그대로 던짐 (스낵바로 노출). `isScrapped()`는 `String?` 반환(스크랩 문서 id 또는 null), `scrapStream(uid)` 추가.
- `fitting_room_screen.dart`에 북마크 아이콘 UI 추가, `_toggleScrap()`으로 추가/삭제.
- `lib/screens/scrap_screen.dart` (신규): 2열 그리드 뷰, 썸네일 탭 시 전체화면 확대(`FullScreenImageViewer` 공용 위젯으로 추출해 재사용), 길게 눌러 삭제.
- `lib/widgets/full_screen_image_viewer.dart` (신규): 기존 fitting_room_screen 안에 있던 `_FullScreenImageViewer`를 공용 위젯으로 추출.
- `settings_screen.dart`: 동작하지 않던 "다크 모드" 항목 제거, "내 스크랩" 항목으로 교체.
- **버그 수정**: `_syncScrapStatus()`에서 `permission-denied` 예외가 처리되지 않고 그대로 터지는 걸 실기기 로그로 발견 → try/catch + `[스크랩조회] 실패: $e` 로그 추가. 근본 원인은 `scraps` 컬렉션 규칙이 로컬 파일에만 있고 실제 배포되지 않았던 것 — 배포 후 해결.

## 8. Gemini 모델 폴백 (재시도 정책 중앙화)

- `gemini_service.dart`: 기존에 3곳에 흩어져 중복 구현되어 있던 재시도 로직을 `GeminiService.withTextModelFallback<T>()` 하나로 중앙화.
  - 1차 모델 `gemini-3.5-flash` 실패(타임아웃 또는 재시도 가능한 에러) 시 `gemini-2.5-flash`로 폴백.
- `extractAttributes`, `extractSizeFromChart`, `analyzeOutfitFromAttributes`, `analyzeOutfitFromAttributesStream`에 `{String? model}` 파라미터 추가.
- **버그 수정**: `wardrobe_screen.dart`의 속성 추출 재시도가 원래 `TimeoutException`만 잡고 `GeminiApiException`(예: 503 과부하)은 못 잡던 잠재 버그 발견 → 중앙화 과정에서 함께 수정. 능동 추천 파이프라인의 Gemini 호출은 원래 재시도가 전혀 없었는데 이번에 추가됨.
- 이미지 생성(`generateFittingImage`)은 기존 범용 `_withRetry<T>` 그대로 유지(모델 폴백 대상 아님).

## 9. 홈 화면 추천 카드 오버플로 수정

- 증상: 추천 코디 카드의 4개 아이템(상의/하의/신발/아우터) 썸네일 Row에서 "RIGHT OVERFLOWED BY 2.0 PIXELS".
- 원인: 고정폭 64px 썸네일 4개 + 각 8px 우측 패딩이 카드 가용 폭을 살짝 초과.
- 수정: 각 썸네일을 `Expanded`로 감싸고 `width: double.infinity`로 변경 (아이템 개수가 4개로 고정되어 있어 Expanded 방식 채택, `height: 64`는 유지).
- `flutter analyze` 통과 확인, 실기기에서 새 4개 조합 추천이 재생성된 로그(`[RECOMMEND]` 전 구간 정상, Gemini 점수 85, Firestore 저장 성공)에서 "OVERFLOW" 문자열 없음 확인.

## 10. Gemini 모델명 하드코딩 현황 (전수 조사)

`lib/` 전체에서 `gemini-`로 시작하는 모델명은 `lib/services/gemini_service.dart` 한 파일에만 존재.

**실제 호출에 쓰이는 모델 (3개)**
| 상수 | 모델명 | 용도 |
|---|---|---|
| `_textModel` | `gemini-3.5-flash` | 기본 텍스트 모델 (속성 추출/사이즈 OCR/코디 분석/스트리밍) |
| `textModelFallback` | `gemini-2.5-flash` | 1차 모델 실패 시 폴백 |
| `_imageModel` | `gemini-3.1-flash-image` | 가상 피팅 이미지 생성 |

**주석 처리되어 미사용 (2곳)**
- 과거 `gemini-3-flash-preview` 시도 이력 설명 주석 (응답 잘림 문제로 3.5-flash로 되돌림)
- `// static const _imageModel = 'gemini-3-pro-image';` — 예전 이미지 모델, 현재 3.1-flash-image로 교체되어 비활성

## 현재 git 상태

`c4704db` 이후 작업은 아래 4개 커밋으로 분리되어 전부 `origin/main`에 push 완료됨 (로컬/원격 동일, 워킹 트리 클린).

| 커밋 | 내용 |
|---|---|
| `a8cc19f` | 가상 피팅 스크랩(북마크) 기능 추가 (`firestore.rules`, `firestore_service.dart`, `fitting_room_screen.dart`, `settings_screen.dart`, `scrap_entry.dart`, `scrap_screen.dart`, `widgets/full_screen_image_viewer.dart`, `fitting_job_controller.dart`의 `fittingImageUrl` 세팅 수정분) |
| `4105f21` | Gemini 텍스트 모델 폴백 정책 중앙화 (`gemini_service.dart`, `wardrobe_screen.dart`, `fitting_job_controller.dart`의 `withTextModelFallback` 호출부 교체분) |
| `e414346` | 홈 화면 추천 카드 오버플로 수정 (`home_screen.dart`) |
| `345769b` | 이 정리 문서(`docs/session_2026-07_summary.md`) 추가 |

`fitting_job_controller.dart`는 스크랩용 변경과 폴백용 변경이 한 파일에 섞여 있어 `git add -p`로 훅 단위로 나눠 `a8cc19f`/`4105f21`에 각각 배분함.

## 지켜야 할 작업 원칙 (재확인)

- Firebase 규칙 배포 등 공유/원격 인프라에 영향을 주는 작업은 실행 전 반드시 사용자 승인 필요.
- 사용자가 직접 트리거한 액션(스크랩 추가/삭제 등)의 에러는 조용히 삼키지 않고 스낵바로 노출.
- 코드 변경 후 항상 `flutter analyze` 실행, 가능하면 실기기에서 실제 동작 확인.
