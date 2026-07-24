# OutfitMatcher 알고리즘 명세

`lib/services/outfit_matcher.dart`(`OutfitMatcher` 클래스)를 코드가 아닌
알고리즘 명세로 재구성한 문서. Gemini API 호출 없이 순수 로컬 규칙만으로
동작하는 코디 조합 후보 생성/스코어링 로직이며, Kaggle에서 Python으로
재구현할 수 있도록 입출력, 상수, 절차를 빠짐없이 기술한다.

## 1. 공통 상수

```
outfit_categories = {"상의", "하의", "아우터", "신발"}   # 조합 대상 카테고리(액세서리 제외)
formality_rank = {"캐주얼": 0, "세미포멀": 1, "포멀": 2}
neutral_colors = {"화이트", "블랙", "네이비", "그레이", "베이지", "아이보리", "카키", "그레이지"}
```

옷 하나의 attributes는 6개 필드: `color, style, pattern, formality, fit, tags`.
매칭 로직이 실제로 사용하는 건 `color`와 `formality` 둘뿐이다(`style`/`pattern`/
`fit`/`tags`는 매칭 스코어에 관여하지 않음 — Gemini 프롬프트용 텍스트 요약에만 쓰임).

## 2. 두 아이템 간 호환 점수 `compatibility_score(a, b)`

옷 두 벌의 attributes `a`, `b`를 받아 점수(float, 음수 가능)를 반환한다.

```
score = 0

# 격식 궁합
rank_a = formality_rank.get(a.formality)   # 없으면 None
rank_b = formality_rank.get(b.formality)
if rank_a is not None and rank_b is not None:
    diff = abs(rank_a - rank_b)
    if diff == 0: score += 2
    elif diff == 1: score += 1
    else: score += -1          # 격식 차이 2단계(캐주얼 vs 포멀) → 감점

# 색상 궁합
if a.color in neutral_colors or b.color in neutral_colors:
    score += 2                 # 둘 중 하나라도 무채색이면 무난히 어울림
elif a.color == b.color and a.color != "":
    score += 1                 # 동색 코디
# 그 외(색이 다르고 둘 다 유채색)는 가산점 없음(0)

return score
```

점수가 매길 수 있는 최댓값은 4(격식 완전일치 +2, 무채색 +2), 최솟값은 -1(격식
2단계 차이, 색상 가산점 없음).

## 3. `find_candidate_matches(new_item, existing_items, max_candidates=3)`

**입력**: 방금 등록/기준이 되는 `new_item` 한 벌 + 나머지 옷장 전체.
**목적**: `new_item`과 어울리는 서로 다른 조합 후보를 최대 `max_candidates`개 생성.

1. `new_item.attributes`가 없거나 `new_item.category`가 `outfit_categories`에
   없으면 즉시 빈 리스트 반환(매칭 대상이 아님).
2. **후보 풀 구성**: `existing_items`에서 다음을 모두 만족하는 것만 남긴다.
   - id가 new_item과 다름
   - category가 new_item과 **다름** (같은 카테고리 두 벌은 한 조합에 안 들어감)
   - category가 `outfit_categories`에 포함
   - attributes가 채워져 있음
3. 풀의 각 후보에 대해 `compatibility_score(new_item.attrs, candidate.attrs)`
   계산. **점수가 0 이하인 후보는 버린다**(양수만 유효 후보).
4. 살아남은 후보를 **카테고리별로 그룹화**, 그룹 내에서 점수 내림차순 정렬 후
   **상위 2개까지만** 남긴다(1등=기본 채택, 2등=교체 변형 재료).
5. 카테고리 그룹이 하나도 없으면(전부 0점 이하이거나 풀 자체가 비었으면)
   빈 리스트 반환.
6. **스켈레톤 선정**: 각 카테고리의 1등 점수를 기준으로 카테고리를 내림차순
   정렬해 **상위 3개 카테고리**만 조합의 뼈대로 채택.
7. **기본 조합** `build_combo(replace=None)`: 스켈레톤의 각 카테고리에서
   `replace`와 같은 카테고리면 2등, 아니면 1등 아이템을 뽑는다.
   `combo.items = [new_item] + picked_items`, `combo.local_score = sum(picked scores)`.
8. **교체 변형**: 스켈레톤 카테고리 중 2등 후보가 존재하는 카테고리마다
   `build_combo(replace=그 카테고리)` 하나씩 생성 (한 슬롯만 2등으로 교체).
9. **미니 변형**: `core = {"상의", "하의"}`. 스켈레톤 중 core에 속하는
   카테고리들(`core_picks`)이 있고, 그 개수가 스켈레톤 전체보다 적으면(즉
   아우터/신발 등 core가 아닌 카테고리도 스켈레톤에 있으면), core 카테고리의
   1등만으로 구성된 축소 조합을 변형 목록에 추가한다(아우터/신발을 뺀
   상의+하의만 조합).
10. 변형 목록을 `local_score` 내림차순 정렬.
11. 최종 리스트 = `[기본 조합] + 정렬된 변형들`을 순서대로 순회하며, 아이템
    id 집합(정렬 후 join)이 이미 나온 조합과 같으면 건너뛰고(중복 제거),
    `max_candidates`개가 모이면 중단.

`find_best_match(new_item, existing_items)`는 위 함수를 `max_candidates=1`로
호출해 첫 번째(=기본 조합) 하나만 반환하는 래퍼.

## 4. `find_for_tpo(wardrobe, formality_hint, max_candidates=3)`

**입력**: `new_item` 없이 옷장 전체 + 목표 격식(`formality_hint`, 예:
"캐주얼"/"세미포멀"/"포멀"). 일정 기반 선제 추천/주간 플랜에서 사용.

1. `target_rank = formality_rank.get(formality_hint, 0)`.
2. 옷장의 모든 아이템(attributes 있고 category가 outfit_categories인 것)에
   대해 개별 점수 계산:
   ```
   item_rank = formality_rank.get(item.formality)   # 없으면 None
   if item_rank is None:
       score = 0.5                                   # 격식 미상 → 중립값
   else:
       diff = abs(target_rank - item_rank)
       score = 3 if diff == 0 else (1 if diff == 1 else 0)
   if item.color in neutral_colors:
       score += 1
   ```
   (2번 항목의 `_compatibility_score`와는 다른 별도 함수 `_formality_fit_score`임에 유의.)
3. 카테고리별로 전체 후보를 모아둔다(`all_per_category`).
4. `top_two(keep_fn)`: 카테고리별로 `keep_fn(score)`를 만족하는 것만 걸러
   점수 내림차순 정렬 후 상위 2개만 남기는 헬퍼.
5. `scored = top_two(score > 0)` — "격식 적합" 후보만.
6. `has_core = "상의" in scored and "하의" in scored`.
7. **격식 적합 성공 시** (`has_core`): `_build_combos_from_ranked(scored, max_candidates)`
   호출, `is_fallback = False`.
8. **격식 적합 실패 시**: `relaxed = top_two(항상 True)` (점수 무관, 카테고리별
   상위 2개). `relaxed`에 상의·하의가 모두 있으면 `_build_combos_from_ranked(relaxed, max_candidates)`
   호출, **`is_fallback = True`**(격식은 안 맞지만 차선으로 채운 조합임을 표시).
9. 그래도 상의/하의 중 하나라도 없으면: `candidates = []`, `shortfall` 메시지에
   부족한 카테고리(상의/하의 중 없는 것) 안내 문자열 채워서 반환.

## 5. `_build_combos_from_ranked(ranked_per_category, max_candidates)`

3번(§3)과 로직은 거의 동일하되 "새 옷" 없이 카테고리 랭킹만으로 조합을
만드는 공용 헬퍼 (§4에서만 사용).

1. 카테고리를 **우선순위**로 정렬: 상의=0, 하의=1, 그 외=2, 동순위면 해당
   카테고리 1등 점수 내림차순.
2. 상위 3개 카테고리를 스켈레톤으로 채택.
3. `build_combo(replace)`: §3-7과 동일한 방식(스켈레톤별 1등/2등 선택),
   단 `[new_item, ...]`가 아니라 `picked_items`만으로 조합 구성.
4. 교체 변형: §3-8과 동일(2등 있는 스켈레톤 카테고리마다 하나씩).
5. 미니 변형: `core = 스켈레톤 중 {"상의","하의"}에 속하는 것`. `core`가
   정확히 2개이고 스켈레톤 길이가 2보다 크면(=3번째 카테고리가 있으면),
   core 두 개의 1등만으로 축소 조합 추가.
6. 변형 정렬(local_score desc) → 기본 조합을 맨 앞에 두고 뒤에 이어붙임 →
   아이템 id 집합 중복 제거 → `max_candidates`에서 컷.

## 6. `find_replacement_for(category, wardrobe, reference_attrs, exclude_ids)`

진단-수리 루프(자기평가에서 약점 카테고리를 하나만 교체할 때) 전용.

1. `wardrobe`에서 `category`가 일치하고 attributes가 있고 `exclude_ids`에
   없는 아이템만 후보 풀로 삼는다.
2. 풀이 비어 있으면 `None`.
3. `compatibility_score(reference_attrs, candidate.attrs)` 기준 내림차순
   정렬 후 1등 하나만 반환.

## 7. 재구현 시 유의점

- 점수 함수가 두 개다: 아이템 대 아이템 비교는 `compatibility_score`(§2,
  새 옷 트리거 매칭용), 아이템 대 "목표 격식" 비교는 `_formality_fit_score`
  + 무채색 보너스(§4-2, TPO 매칭용). 서로 다른 스케일이므로 섞어 쓰면 안 됨.
- "카테고리별 상위 2개까지만 남긴다"는 규칙이 두 함수 모두에 있지만
  §3에서는 "점수 > 0"만 통과, §4의 `scored`도 "점수 > 0"이지만 `relaxed`는
  무조건 통과(점수 필터 없음) — 이 차이가 `is_fallback` 판정의 핵심이다.
- 모든 조합 생성 함수의 중복 제거는 "아이템 id를 정렬해 이어붙인 문자열"
  기준이다 — 아이템 구성이 같으면 순서가 달라도 같은 조합으로 취급.
- 상수 값(가중치, 상위 2개, 스켈레톤 3개 등)은 실측 데이터가 아니라 초기
  추정값이라는 점이 원본 코드 주석에도 명시돼 있음 — Kaggle 실험에서 이
  가중치 자체를 재조정하는 것도 유효한 방향이다.
