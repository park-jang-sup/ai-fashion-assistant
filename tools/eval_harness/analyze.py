"""7-b 라벨 분석 — 사전 등록(docs/handoff_2026-08-04.md §3, 2026-08-05 확정)
검정을 그대로 수행한다. 기준(모수 21쌍 전체, 양측 부호검정 p<0.10 그리고
방향 >=70%)은 라벨을 보고 나서 바꾸지 않는다.

입력(전부 로컬, .gitignore 대상 — 이 스크립트와 같은 디렉터리):
  pairs.json      Task A가 낸 discordant 21쌍(정책 정보 없음)
  policy_map.json 각 쌍의 itemA/itemB가 어느 정책인지(라벨링 UI는 안 읽음)
  labels.json     라벨링 도구가 낸 사람 선택

출력: stdout 마크다운. 결과 수치는 문서(인수인계)로 옮겨 적는다 — 이 파일
자체는 데이터를 담지 않으므로 커밋 대상이다(계산 방법이 저장소에 없어서
7-a 코사인 실측을 역산해야 했던 함정 28의 재발 방지가 이 스크립트의 존재
이유다).

사용법:
    python tools/eval_harness/analyze.py
"""
from __future__ import annotations

import json
import sys
from math import comb
from pathlib import Path

HARNESS_DIR = Path(__file__).resolve().parent
PAIRS_PATH = HARNESS_DIR / "pairs.json"
POLICY_MAP_PATH = HARNESS_DIR / "policy_map.json"
LABELS_PATH = HARNESS_DIR / "labels.json"

# §4 "주시 항목" — 샌들 한 벌(신발 22벌 중 시각상 유일하게 다른 아이템).
SANDAL_ITEM_ID = "t16mhpuSrkQq4KvRxiqx"

# 사전 등록(§3) 그대로 — 여기서 바꾸지 않는다.
ALPHA = 0.10
DIRECTION_THRESHOLD = 0.70
REGISTERED_N = 21
REGISTERED_MIN_WINS = 15


def load_json(path: Path):
    if not path.is_file():
        print(f"[중단] {path} 없음")
        sys.exit(1)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def two_sided_exact_sign_test_p(successes: int, n: int) -> float:
    """양측 정확 이항검정(p=0.5 귀무가설). 정규 근사를 쓰지 않는다 — n이 작다.

    관측된 pmf보다 크지 않은(=관측치보다 같거나 더 극단적인) 모든 k의 pmf를
    합산하는 표준적인 양측 정확검정 정의를 쓴다.
    """
    if n == 0:
        return float("nan")
    pmf = [comb(n, k) * (0.5**n) for k in range(n + 1)]
    p_obs = pmf[successes]
    total = sum(p for p in pmf if p <= p_obs + 1e-12)
    return min(total, 1.0)


def min_wins_for_alpha(n: int, alpha: float = ALPHA) -> tuple[int | None, float | None]:
    """이 n에서 양측 정확검정 p<alpha를 만족하는 최소 승수(및 그 p값).
    기준(alpha) 자체는 안 바꾼다 — n이 skip 때문에 줄었을 때 그 n에서의
    임계 승수만 다시 계산하는 것이다(§A-3-2)."""
    for k in range(n // 2 + 1, n + 1):
        p = two_sided_exact_sign_test_p(k, n)
        if p < alpha:
            return k, p
    return None, None


def main() -> None:
    # Windows 콘솔이 cp949 등 레거시 코드페이지면 한글/이모지 출력에서
    # UnicodeEncodeError가 난다(backfill.py와 같은 문제, 같은 대응).
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")

    pairs_doc = load_json(PAIRS_PATH)
    policy_map = load_json(POLICY_MAP_PATH)
    labels_doc = load_json(LABELS_PATH)

    pairs = {p["pairId"]: p for p in pairs_doc["pairs"]}
    registered_ids = set(pairs.keys())

    print("# 7-b 라벨 분석 (사전 등록 기준)")
    print()
    print(f"- pairs.json: {len(pairs)}쌍")
    print(f"- labels.json sessionId: `{labels_doc.get('sessionId')}`")
    print(f"- labels.json 라벨 수: {len(labels_doc.get('labels', []))}")
    print()

    # ── §A-2: 검증 게이트 — 분석보다 먼저 ──────────────────────────
    print("## §A-2 검증 게이트")
    print()
    gate_failed = False

    label_entries = labels_doc.get("labels", [])
    label_pair_ids = [e["pairId"] for e in label_entries]

    # 게이트 1 — pairId 일치(누락·중복·미지의 id 없음)
    dup_ids = {pid for pid in label_pair_ids if label_pair_ids.count(pid) > 1}
    missing_ids = registered_ids - set(label_pair_ids)
    unknown_ids = set(label_pair_ids) - registered_ids
    gate1_ok = not dup_ids and not missing_ids and not unknown_ids
    print(f"1. pairId 일치: {'통과' if gate1_ok else '**실패**'}")
    print(f"   - 중복: {sorted(dup_ids) or '없음'}")
    print(f"   - 누락(pairs.json에는 있는데 labels.json에 없음): {sorted(missing_ids) or '없음'}")
    print(f"   - 미지(labels.json에만 있음): {sorted(unknown_ids) or '없음'}")
    if not gate1_ok:
        gate_failed = True

    # 게이트 2 — choice 값 검증
    valid_choices = {"itemA", "itemB", "skip"}
    bad_choices = [
        (e["pairId"], e.get("choice")) for e in label_entries if e.get("choice") not in valid_choices
    ]
    gate2_ok = not bad_choices
    print(f"2. choice 값 검증: {'통과' if gate2_ok else '**실패**'}")
    print(f"   - itemA/itemB/skip 외 값: {bad_choices or '없음'}")
    if not gate2_ok:
        gate_failed = True

    # 게이트 3 — sessionId 단일 여부. labels.json 스키마 자체가 파일당
    # sessionId 하나이므로 "여럿"은 여러 labels.json을 합칠 때만 발생할 수
    # 있는데, 이번 입력은 파일 하나뿐이라 구조적으로 항상 하나다. 다만
    # **이름 자체("test"를 포함하는지)는 별개 문제라 여기서 그대로 노출한다**
    # — 게이트 통과 여부와는 무관하지만 사람이 반드시 봐야 하는 사실이다.
    session_id = labels_doc.get("sessionId")
    print(f"3. sessionId 단일 여부: 통과 (`{session_id}` 1개)")
    if session_id and "test" in session_id.lower():
        print(
            f"   - **⚠️ sessionId에 'test' 문자열이 포함됨(`{session_id}`).** "
            "라벨링 도구 동작 확인용 시험 라벨일 가능성이 있다 — 이 분석을 "
            "7-b 최종 결과로 쓸지는 이 스크립트가 판단하지 않는다. 사람이 "
            "확정해야 한다."
        )

    # 게이트 4 — skip 건수·유효 n
    skip_ids = [e["pairId"] for e in label_entries if e.get("choice") == "skip"]
    valid_n = len(label_entries) - len(skip_ids)
    print(f"4. skip 건수: {len(skip_ids)}건 {skip_ids or ''}")
    print(f"   - **유효 n = {valid_n}**(이후 모든 검정은 이 n을 기준으로 한다)")
    print()

    if gate_failed:
        print("**게이트 실패 — 분석을 중단한다.** 위 실패 항목을 먼저 해결해야 한다.")
        return

    # ── §A-3: 정책 결합과 주검정 ─────────────────────────────────
    print("## §A-3 정책 결합과 주검정")
    print()

    def resolve_choice(entry) -> str | None:
        """이 라벨이 가리키는 정책. skip이면 None."""
        choice = entry["choice"]
        if choice == "skip":
            return None
        return policy_map[entry["pairId"]][choice]

    resolved = [
        (e["pairId"], resolve_choice(e), e["choice"], e.get("elapsedMs")) for e in label_entries
    ]
    non_skip = [r for r in resolved if r[1] is not None]
    recovery_wins = sum(1 for r in non_skip if r[1] == "embeddingRecovery")
    current_wins = sum(1 for r in non_skip if r[1] == "current")
    assert recovery_wins + current_wins == valid_n

    p_value = two_sided_exact_sign_test_p(recovery_wins, valid_n)
    direction = recovery_wins / valid_n if valid_n else float("nan")

    print(f"- recovery 승: {recovery_wins} / current 승: {current_wins} (유효 n={valid_n})")
    print(f"- 양측 정확 이항검정(부호검정) p = {p_value:.4f}")
    print(f"- recovery 방향 비율 = {direction:.4f} ({direction * 100:.1f}%)")
    print()

    reg_p = two_sided_exact_sign_test_p(REGISTERED_MIN_WINS, REGISTERED_N)
    print(
        f"- 사전 등록 기준값 확인: n={REGISTERED_N}에서 {REGISTERED_MIN_WINS}승이면 "
        f"p={reg_p:.4f} ({'<0.10 충족' if reg_p < ALPHA else '>=0.10 미충족'})"
    )
    if valid_n != REGISTERED_N:
        k, p_at_k = min_wins_for_alpha(valid_n, ALPHA)
        print(
            f"- **skip으로 유효 n이 {REGISTERED_N}→{valid_n}로 줄어, 이 n에서 "
            f"p<{ALPHA} 충족의 최소 승수를 재계산**: {k}승"
            f"{f'(p={p_at_k:.4f})' if k is not None else ''}. "
            "기준(p<0.10, 방향>=70%) 자체는 그대로다 — 임계 승수만 n에 맞춰 다시 잰 것이다."
        )
    print()

    if p_value < ALPHA and direction >= DIRECTION_THRESHOLD:
        verdict = "사전 등록 기준 충족"
    elif p_value < ALPHA:
        verdict = "부분 충족 — 사전 등록상 나아짐 아님"
    else:
        verdict = "미충족"
    print(f"**결론: {verdict}**")
    print()

    # ── §A-4: 층위별 분해 (검정 아님 — 관측 보고) ──────────────────
    print("## §A-4 층위별 분해 (검정 미수행 — 관측 보고)")
    print()

    # 4-1: 신발 vs 비신발
    def is_shoes(pair_id: str) -> bool:
        return pairs[pair_id]["isShoes"]

    shoes_non_skip = [r for r in non_skip if is_shoes(r[0])]
    nonshoes_non_skip = [r for r in non_skip if not is_shoes(r[0])]
    shoes_recovery = sum(1 for r in shoes_non_skip if r[1] == "embeddingRecovery")
    nonshoes_recovery = sum(1 for r in nonshoes_non_skip if r[1] == "embeddingRecovery")
    print("### 4-1. 신발 vs 비신발 (검정 미수행)")
    print()
    print(
        f"- 신발: recovery {shoes_recovery} / current {len(shoes_non_skip) - shoes_recovery} "
        f"(유효 n={len(shoes_non_skip)})"
    )
    print(
        f"- 비신발: recovery {nonshoes_recovery} / current "
        f"{len(nonshoes_non_skip) - nonshoes_recovery} (유효 n={len(nonshoes_non_skip)})"
    )
    if len(shoes_non_skip) and len(nonshoes_non_skip):
        shoes_dir = shoes_recovery / len(shoes_non_skip)
        nonshoes_dir = nonshoes_recovery / len(nonshoes_non_skip)
        gap = abs(shoes_dir - nonshoes_dir)
        print(f"- 방향 비율: 신발 {shoes_dir:.2f} vs 비신발 {nonshoes_dir:.2f} (차이 {gap:.2f})")
    print()

    # 4-2: 신발 9건 내적 일관성
    print("### 4-2. 신발 내적 일관성 (검정 미수행)")
    print()
    shoe_pair_ids = [pid for pid in pairs if pairs[pid]["isShoes"]]
    shoe_item_sets = {
        pid: frozenset([pairs[pid]["itemA"]["id"], pairs[pid]["itemB"]["id"]]) for pid in shoe_pair_ids
    }
    distinct_sets = set(shoe_item_sets.values())
    if len(distinct_sets) == 1:
        common_set = next(iter(distinct_sets))
        print(
            f"- 신발 {len(shoe_pair_ids)}쌍 전부 같은 두 아이템 {sorted(common_set)}으로 "
            "구성됨 — 일관성 검사가 성립한다."
        )
        # 각 쌍에서 "실제로 고른 아이템 id"로 환산(itemA/itemB, current/recovery
        # 라벨과 무관하게 순수 이미지 id로 비교).
        chosen_ids = []
        for pid, resolved_policy, raw_choice, _ in resolved:
            if pid not in shoe_pair_ids:
                continue
            if raw_choice == "skip":
                continue
            item_id = pairs[pid][raw_choice]["id"]
            chosen_ids.append((pid, pairs[pid]["tag"], item_id, resolved_policy))
        id_counts: dict[str, int] = {}
        for _, _, item_id, _ in chosen_ids:
            id_counts[item_id] = id_counts.get(item_id, 0) + 1
        print(f"- 라벨된 신발쌍 {len(chosen_ids)}건의 선택 분포: {id_counts}")
        for pid, tag, item_id, resolved_policy in chosen_ids:
            print(f"  - {pid}({tag}): {item_id} 선택 (정책={resolved_policy})")
        if len(id_counts) <= 1 and chosen_ids:
            print("  - **완전히 일관됨** — 라벨된 모든 신발쌍에서 같은 아이템을 골랐다.")
        elif len(id_counts) > 1:
            print("  - **일관되지 않음** — 태그에 따라 다른 아이템을 골랐다.")
    else:
        print(
            "- 신발 쌍 구성이 태그마다 달라 이 일관성 검사는 성립하지 않는다. "
            "억지로 다른 지표를 만들지 않는다."
        )
    print()

    # 4-3: 샌들 확인
    print("### 4-3. 샌들 확인 (§4 주시 항목, 검정 미수행)")
    print()
    sandal_pairs = [
        pid for pid, p in pairs.items() if SANDAL_ITEM_ID in (p["itemA"]["id"], p["itemB"]["id"])
    ]
    if not sandal_pairs:
        print(f"- 샌들({SANDAL_ITEM_ID})은 discordant 21쌍 어디에도 등장하지 않는다.")
    else:
        for pid in sandal_pairs:
            p = pairs[pid]
            role = policy_map[pid]
            sandal_side = "itemA" if p["itemA"]["id"] == SANDAL_ITEM_ID else "itemB"
            sandal_policy = role[sandal_side]
            label_entry = next((e for e in label_entries if e["pairId"] == pid), None)
            print(
                f"- {pid}({p['tag']}): 샌들이 {sandal_side}({sandal_policy}) — "
                f"라벨 결과: {label_entry['choice'] if label_entry else '(라벨 없음)'}"
            )
            if sandal_policy == "embeddingRecovery" and p["tag"] in {"면접", "결혼식", "경조사"}:
                print(f"  - **포멀 태그({p['tag']})에서 recovery가 샌들을 골랐다.**")
    print()

    # 4-4: elapsedMs 분포
    print("### 4-4. elapsedMs 분포 (검정 미수행, 해석 없음)")
    print()
    elapsed = sorted(
        (e.get("elapsedMs"), e["pairId"]) for e in label_entries if e.get("elapsedMs") is not None
    )
    if elapsed:
        values = [v for v, _ in elapsed]
        n = len(values)
        median = values[n // 2] if n % 2 == 1 else (values[n // 2 - 1] + values[n // 2]) / 2
        print(f"- 중앙값: {median}ms")
        print(f"- 최소: {elapsed[0][0]}ms ({elapsed[0][1]})")
        print(f"- 최대: {elapsed[-1][0]}ms ({elapsed[-1][1]})")
        print(f"- 전체 정렬: {elapsed}")
    else:
        print("- elapsedMs 데이터 없음")
    print()

    # ── §A-5: 부검정 자리 표시 ──────────────────────────────────
    print("## §A-5 부검정")
    print()
    print(
        "사전 등록의 부검정(회수 승리가 그룹 내부 코사인 분산이 낮은 그룹에 "
        "몰리는지)은 **분산 공변량 리포트가 아직 없어 수행 불가**다."
    )


if __name__ == "__main__":
    main()
