# 작업 지시서 — 격식 판정 정책화 및 실측 옷장 A/B 리포트

대상 저장소: `park-jang-sup/ai-fashion-assistant`
관련 논문 절: 5.8.3, 5.8.4, 6.5, 7.1, 7.2-1, 7.2-2, 7.2-11

---

## 0. 배경 (읽고 시작할 것)

`lib/services/outfit_matcher.dart`의 `findForTpo`에 두 개의 알려진 결함이 있다.

**결함 A — 무채색 보너스가 격식 필터를 무력화한다.**

```dart
double score = rank == null ? 0.5 : _formalityFitScore(targetRank, rank);
if (isNeutralColor(attrs.color)) score += 1;
...
final scored = topTwo((s) => s > 0);
```

목표가 포멀(rank 2)이고 아이템이 캐주얼(rank 0)이면 `_formalityFitScore`는 0점을 준다.
그런데 무채색이면 +1이 가산되어 1점이 되고 `s > 0` 필터를 통과한다.
현재 옷장이 블랙·화이트·그레이 편중이므로 사실상 모든 상·하의가 이 경로로 구제된다.
결과적으로 `isFallback`이 실사용에서 발화하지 않고, 부재 인지 배지가 죽은 기능이 된다.
격식 속성이 빈 아이템도 `rank == null → 0.5`로 통과하는 두 번째 구제 경로가 있다.

**결함 B — `hasCore`가 상의·하의만 검사한다.**

```dart
final hasCore = scored.containsKey('상의') && scored.containsKey('하의');
```

아우터·신발만 격식에 안 맞는 경우는 차선으로 분류되지 않고, 해당 아이템이 조합에서
조용히 누락된다. 현실에서는 이 경우가 훨씬 흔하다 — 상의·하의가 하나도 없는 옷장은
사실상 없지만, 격식에 맞는 아우터가 없는 옷장은 매우 흔하다.

**왜 아직 안 고쳤는가.** 수정 자체는 각각 한 줄이다. 그러나 이 계산식은 선제 추천의
핵심 경로라, 변경하면 모든 추천의 후보 구성이 달라진다. 게다가 영향이 한 방향으로만
나타나지 않는다 — 캐주얼 일정에서 포멀 아이템이 배제되면서 반대 방향으로 `hasCore`가
깨져 배지가 과도하게 표시될 수 있다. **어느 쪽으로 기우는지 실측 옷장으로 먼저 측정해야
한다.** 이 작업의 목적은 그 측정 장치를 만드는 것이지, 결함을 고치는 것이 아니다.

---

## 1. 전제 조건

시작 전에 확인할 것.

- `tools/export_for_kaggle/output/items.json`이 로컬에 존재하는가.
  없으면 이 작업의 리포트 부분은 skip으로 빠진다 — 사용자에게 알리고 멈출 것.
  (이 파일은 `.gitignore` 대상. 실제 옷장 데이터라 커밋 금지.)
- `flutter test`가 현재 전량 통과하는가. 통과 상태를 베이스라인으로 삼는다.

기존 검증 자산을 먼저 읽어볼 것 — 이번 작업이 따라야 할 패턴이다.

- `test/color_rule_verification_test.dart` — 전/후 diff 리포트의 기존 구현
- `test/support/wardrobe_fixture.dart` — Firestore 없이 실측 옷장 로드
- `test/support/legacy_matcher.dart` — 옛 로직 재구현본

---

## 2. 작업 1 — 정책 객체 추출 (동작 변화 0)

**파일:** `lib/services/outfit_matcher.dart`

`findForTpo`의 판정 파라미터를 값으로 뽑아, 테스트가 로직을 복제하지 않고
정책만 바꿔 끼울 수 있게 한다.

### 2.1 `TpoMatchPolicy` 추가

```dart
// findForTpo의 격식 판정 파라미터. 기본값(current)은 현행 동작과 완전히
// 동일하다 — 정책을 주입하지 않은 모든 호출부는 한 비트도 달라지지 않는다.
// proposed는 논문 5.8.3/5.8.4의 수정안이며, 실측 옷장 리포트로 영향을
// 확인하기 전까지 프로덕션 기본값이 되어서는 안 된다.
class TpoMatchPolicy {
  // true면 무채색 보너스를 "이미 격식을 충족한 후보"에게만 적용한다(동점 처리용).
  final bool gateNeutralBonus;
  // 이 카테고리가 전부 scored에 있어야 격식 적합으로 본다.
  final Set<String> requiredCategories;
  // 없어도 조합은 성립하지만 부재를 안내해야 하는 카테고리.
  final Set<String> optionalCategories;

  const TpoMatchPolicy({
    this.gateNeutralBonus = false,
    this.requiredCategories = const {'상의', '하의'},
    this.optionalCategories = const {'아우터', '신발'},
  });

  static const current = TpoMatchPolicy();
  static const proposed = TpoMatchPolicy(gateNeutralBonus: true);
}
```

### 2.2 `findForTpo` 시그니처 확장

```dart
static TpoMatchResult findForTpo({
  required List<WardrobeItem> wardrobe,
  required String formalityHint,
  int maxCandidates = 3,
  TpoMatchPolicy policy = TpoMatchPolicy.current,   // 추가
})
```

본문에서 두 곳만 바꾼다.

```dart
// 보너스 가산
if (isNeutralColor(attrs.color) && (!policy.gateNeutralBonus || score > 0)) {
  score += 1;
}

// 핵심 카테고리 판정
final hasCore = policy.requiredCategories.every(scored.containsKey);
```

`relaxed` 분기의 `containsKey('상의') && containsKey('하의')`도 동일하게
`policy.requiredCategories.every(relaxed.containsKey)`로 바꾼다.

### 2.3 `mismatchedCategories` 계산의 하드코딩 제거

현재 `categoryOrder`가 리터럴 리스트로 박혀 있고 주석에 "자동 동기화 없음"이라
적혀 있다. `policy.requiredCategories` + `policy.optionalCategories`에서 유도하되
표시 순서(`상의 → 하의 → 아우터 → 신발`)는 유지할 것. 순서를 보장하려면
`_outfitCategories`를 `Set`이 아닌 `List`로 바꾸거나 별도 순서 상수를 두되,
`_outfitCategories`를 참조하는 다른 지점의 동작이 바뀌지 않는지 확인할 것.

### 2.4 수용 기준 — 이 단계에서 반드시 확인

- `flutter test` 전량 통과. 특히 `test/outfit_matcher_test.dart`와
  `test/color_rule_verification_test.dart`가 **수정 없이** 통과해야 한다.
  이 두 파일을 고쳐서 통과시키는 것은 실패로 간주한다.
- `findForTpo`를 정책 없이 호출하는 기존 호출부(`agent_planner.dart`,
  `findCandidatesForTpo`)의 결과가 리팩터링 전후로 동일한지,
  실측 옷장 fixture로 9개 태그 전부 비교해 확인할 것.

---

## 3. 작업 2 — A/B 리포트 테스트

**파일:** `test/tpo_policy_report_test.dart` (신규)

`test/color_rule_verification_test.dart`의 구조를 그대로 따른다 —
`items.json`이 없으면 파일 전체를 skip하고, `print` 기반 진단 리포트를 낸다
(`// ignore_for_file: avoid_print`).

### 3.1 실행 매트릭스

`TpoTags.all` 9종 전부 × `{current, proposed}` 2가지 정책.
각 태그의 `formalityHint`를 `findForTpo`에 넘긴다.
(포멀 3종 — 결혼식·면접·경조사 — 이 이번 수정의 주 관찰 대상이다.)

### 3.2 출력 항목

**표 1 — 태그별 정책 비교**

| 태그 | 요구격식 | current isFallback | proposed isFallback | current 후보수 | proposed 후보수 | 1번후보 변화 |

**표 2 — proposed에서 새로 채워진 `mismatchedCategories`**

태그별로 어떤 카테고리가 부족으로 잡혔는지. 이게 부재 인지 배지의 실제 문구 재료다.

**표 3 — 무채색 보너스 구제 현황 (핵심 지표)**

각 태그 × 카테고리에 대해:
- `_formalityFitScore`가 0점을 준 아이템 수
- 그중 무채색 보너스로 `s > 0`을 통과한 아이템 수 (= 구제된 수)
- `rank == null`(격식 속성 없음)로 0.5점 받아 통과한 아이템 수

세 번째 열이 두 번째 구제 경로다. 이 수가 크면 게이팅만으로는 부족하다는 신호다.

**표 4 — 역효과 감지**

`current`에서 `isFallback == false`였는데 `proposed`에서 `candidates`가
비거나(`shortfall` 발생) fallback으로 떨어진 태그 목록.
논문이 우려한 "반대 방향으로 `hasCore`가 깨지는" 시나리오가 여기서 잡힌다.

**요약 한 줄**

```
current fallback 발화율: N/9  →  proposed: M/9
```

### 3.3 assert 최소화

이 파일의 목적은 진단이지 회귀 방지가 아니다. 단 하나만 실패로 걸어둘 것:

```dart
// proposed 정책에서 어떤 태그든 candidates가 완전히 비면(=조합 자체 불가)
// 그건 과도한 필터링이므로 즉시 눈에 띄어야 한다.
expect(emptyTags, isEmpty, reason: 'proposed 정책에서 조합 불가 태그: $emptyTags');
```

---

## 4. 작업 3 — 판단은 사람이 한다

**리포트를 보고 정책 기본값을 바꾸지 말 것.** 결과를 출력하고 멈춘 뒤,
아래 판단 기준을 사용자에게 함께 제시할 것.

**수정 목적 달성 신호**
- 포멀 3종에서 `isFallback`이 `false → true`로 바뀌고
- `mismatchedCategories`에 실제 카테고리명이 채워지고
- 표 3의 "구제된 수"가 유의미하게 컸던 것으로 확인됨

**과도 신호 (게이팅 재고 필요)**
- 캐주얼·세미포멀 태그에서도 fallback이 켜짐 (발화율 6/9 이상)
- 어떤 태그에서 `candidates`가 0이 됨
- 1번 후보가 9개 태그 중 7개 이상에서 바뀜 (추천 품질 전면 재검증 필요)

**과도할 경우의 대안** (적용하지 말고 제안만 할 것)
- 보너스를 `+1` 대신 `+0.5`로 낮춰 `_formalityFitScore`의 1점(거리 1)보다 작게 만들기
- 보너스를 점수에 합산하지 않고 동점 시 정렬 tie-breaker로만 사용
- `rank == null`의 0.5점을 0점으로 바꿔 두 번째 구제 경로 차단

---

## 5. 작업 4 — `optionalMissing` (리포트 확인 후에만)

작업 3의 판단이 끝나고 사용자가 진행을 지시하면 착수한다. 그 전에는 시작하지 말 것.

- `TpoMatchResult`에 `List<String> optionalMissing` 추가 (기본 `const []`)
- `policy.optionalCategories` 중 `relaxed`에는 있으나 `scored`에 없는 것을 채운다
- `AgentPlanner.buildFallbackNote`에 분기 추가 — **문구를 구분할 것**
  - `mismatchedCategories` (필수 부족): "…에 맞는 상의·하의가 부족해 차선으로 준비했어요"
  - `optionalMissing` (선택 누락): "…에 어울리는 아우터가 없어 이번 조합에서는 뺐어요"
- `buildFallbackNote`는 순수 함수이므로 `test/agent_planner_fallback_note_test.dart`에
  합성 데이터로 케이스를 추가할 것

---

## 6. 금지 사항

- `lib/` 아래에서 `outfit_matcher.dart` 외 다른 파일을 수정하지 말 것
  (작업 5 단계에서 `agent_planner.dart` 허용)
- Firestore 스키마·`firestore.rules`·`firestore.indexes.json` 변경 금지
- `TpoMatchPolicy.current`를 기본값에서 바꾸지 말 것 (리포트 확인 전까지)
- 기존 테스트 파일을 통과시키려고 수정하지 말 것 — 깨지면 리팩터링이 잘못된 것
- `tools/export_for_kaggle/output/` 아래 파일을 커밋하지 말 것 (실제 옷장 데이터)
- 리팩터링 김에 다른 개선을 끼워넣지 말 것. 이 작업의 가치는 "변화가 정책 하나로
  국한됨"을 보장하는 데 있다

---

## 7. 완료 보고 형식

작업 종료 시 다음을 보고할 것.

1. `flutter test` 결과 (통과 개수 / 베이스라인 대비 변화)
2. 리포트 표 1~4 전문
3. 요약 한 줄 (fallback 발화율 변화)
4. 4절 판단 기준에 비추어 "목적 달성" / "과도" / "판단 불가" 중 어디에 해당하는지와 근거
5. 다음 단계 제안 (작업 4 진행 여부)
