"""자기 평가(OutfitSelfEvaluator) 점수 분포/변별력 모니터.

lib/는 전혀 건드리지 않는다. Firestore users/{uid}/recommendations를 읽기만
하고 아무 것도 쓰지 않는다(read-only). 필요할 때마다 다시 실행해 점수
변별력이 회귀하지 않았는지 확인하는 용도의 상시 도구 — 자세한 내용은
README.md 참고.

서비스 계정 키는 반드시 환경변수(GOOGLE_APPLICATION_CREDENTIALS) 또는
--credentials로 넘긴 "로컬 경로"로만 참조한다(tools/export_for_kaggle/
export.py와 동일 관례). 이 스크립트는 그 파일을 읽기만 할 뿐 어디에도
복사/출력하지 않는다.

사용법:
    export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json
    python tools/score_distribution_report/score_distribution_report.py

    # 또는
    python tools/score_distribution_report/score_distribution_report.py \
        --credentials /path/to/serviceAccount.json

주의(수리 전/후 판정의 한계): OutfitSelfEvaluator.run은 candidateScores에
"원본 후보 점수, (수리 시도 시) 수리 후 점수"를 평가 순서대로 그냥 이어
붙인다. 수리가 첫 후보에서 일어난 뒤 수리가 실패해 다음 후보까지 평가되면
[원본0, 수리0, 원본1]처럼 수리 쌍이 앞쪽에 오고, 두 번째 후보에서 수리가
일어나면 [원본0, 원본1, 수리1]처럼 뒤쪽에 온다 — repairAttempted 불리언
하나만으로는 어느 인덱스 쌍이 수리 쌍인지 배열 길이가 3 이상일 때 특정할
수 없다. 그래서 이 스크립트는 candidateScores 길이가 정확히 2인(=원본과
수리 결과만 있는, 유일하게 모호하지 않은) 문서만 "수리 전/후" 비교에 쓰고,
길이가 다른 건 "모호 케이스"로 별도 집계만 한다.
"""
from __future__ import annotations

import argparse
import os
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

SCRIPT_DIR = Path(__file__).resolve().parent
# lib/services/outfit_self_evaluator.dart의 OutfitSelfEvaluator.threshold와
# lib/services/agent_planner.dart의 AgentPlanner._lowScoreFloor가 이 값을
# 공유한다(2026-07 정리 — 전엔 _lowScoreFloor만 60으로 따로 놀아서 도달
# 불가능한 임계값이었다). 이 스크립트는 Python이라 그 상수를 직접 import할
# 수 없으니, lib 쪽 값이 바뀌면 이 상수도 함께 갱신해야 한다.
THRESHOLD = 70


def init_firebase(credentials_path: str | None) -> None:
    cred_path = credentials_path or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not cred_path:
        print(
            "서비스 계정 키 경로가 없습니다. GOOGLE_APPLICATION_CREDENTIALS 환경변수를 "
            "설정하거나 --credentials로 넘겨주세요. (키 파일을 이 저장소 안에 두지 마세요)",
            file=sys.stderr,
        )
        sys.exit(1)
    cred_path = os.path.expanduser(cred_path)
    if not os.path.isfile(cred_path):
        print(f"서비스 계정 키 파일을 찾을 수 없습니다: {cred_path}", file=sys.stderr)
        sys.exit(1)
    if SCRIPT_DIR in Path(cred_path).resolve().parents or Path(cred_path).resolve() == SCRIPT_DIR:
        print(
            "서비스 계정 키를 이 저장소 안에 두지 마세요 — 저장소 밖의 안전한 경로를 "
            "사용하세요.",
            file=sys.stderr,
        )
        sys.exit(1)

    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)


def bucket_label(score: int) -> str:
    if score >= 95:
        return "95-100"
    lo = (score // 5) * 5
    return f"{lo}-{lo + 4}"


def range_bucket(rng: int) -> str:
    if rng == 0:
        return "0(전부 동일)"
    if rng <= 5:
        return "1-5"
    if rng <= 10:
        return "6-10"
    if rng <= 20:
        return "11-20"
    return "21+"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", help="서비스 계정 키 JSON 로컬 경로")
    parser.add_argument("--limit", type=int, default=30, help="최근 몇 건을 볼지 (기본 30)")
    args = parser.parse_args()

    init_firebase(args.credentials)
    db = firestore.client()

    # collection_group 쿼리는 별도 인덱스가 필요할 수 있어, 대신
    # export_for_kaggle/export.py의 export_history()와 동일하게 유저별로
    # 순회한 뒤 파이썬에서 정렬 — 개인 프로젝트 규모라 비용 문제 없음.
    users = list(db.collection("users").stream())
    all_recs: list[dict] = []
    for user_doc in users:
        for rec_doc in user_doc.reference.collection("recommendations").stream():
            data = rec_doc.to_dict() or {}
            created_at = data.get("createdAt")
            if not isinstance(created_at, datetime):
                created_at = datetime.min.replace(tzinfo=timezone.utc)
            all_recs.append({"createdAt": created_at, "data": data})

    all_recs.sort(key=lambda r: r["createdAt"], reverse=True)
    recent = all_recs[: args.limit]
    print(f"전체 추천 문서: {len(all_recs)}건 (계정 {len(users)}개), 최근 {len(recent)}건으로 분석")
    if not recent:
        print("문서가 없습니다 — 종료합니다.")
        return

    all_scores: list[int] = []
    ranges: list[int] = []
    all_equal_count = 0
    comparable_count = 0
    dead_zone_count = 0
    scored_doc_count = 0

    repair_attempted_count = 0
    repair_unambiguous_count = 0
    repair_changed_count = 0
    repair_ambiguous_count = 0

    for rec in recent:
        d = rec["data"]
        raw_scores = d.get("candidateScores") or []
        scores = [int(s) for s in raw_scores]
        if not scores:
            continue
        scored_doc_count += 1
        all_scores.extend(scores)

        if len(scores) >= 2:
            comparable_count += 1
            rng = max(scores) - min(scores)
            ranges.append(rng)
            if rng == 0:
                all_equal_count += 1

        best = max(scores)
        if 60 <= best <= 69:
            dead_zone_count += 1

        if d.get("repairAttempted"):
            repair_attempted_count += 1
            if len(scores) == 2:
                repair_unambiguous_count += 1
                if scores[0] != scores[1]:
                    repair_changed_count += 1
            else:
                repair_ambiguous_count += 1

    print("\n=== 표1: 전체 candidateScores 히스토그램 (5점 단위) ===")
    hist = Counter(bucket_label(s) for s in all_scores)
    for lo in range(0, 95, 5):
        label = f"{lo}-{lo + 4}"
        print(f"  {label}: {hist.get(label, 0)}")
    print(f"  95-100: {hist.get('95-100', 0)}")
    print(f"  총 점수 개수: {len(all_scores)}개 (candidateScores 비어있지 않은 문서 {scored_doc_count}건)")

    print("\n=== 표2: 추천 1건 내 후보 간 점수 차이(max-min) 분포 ===")
    range_hist = Counter(range_bucket(r) for r in ranges)
    for key in ["0(전부 동일)", "1-5", "6-10", "11-20", "21+"]:
        print(f"  {key}: {range_hist.get(key, 0)}")
    pct_equal = (all_equal_count / comparable_count * 100) if comparable_count else 0.0
    print(
        f"  후보 2개 이상 비교 가능한 문서: {comparable_count}건, "
        f"그중 전부 동일: {all_equal_count}건 ({pct_equal:.1f}%)"
    )

    print(f"\n=== 표3: {60}~{69} 데드존(threshold={THRESHOLD} 바로 아래) 비율 ===")
    pct_dead = (dead_zone_count / scored_doc_count * 100) if scored_doc_count else 0.0
    print(
        f"  {dead_zone_count} / {scored_doc_count}건 ({pct_dead:.1f}%) "
        f"— 추천당 최종 채택 점수(=max(candidateScores)) 기준"
    )

    print("\n=== 표4: repairAttempted=true 건의 수리 전/후 점수 변화 ===")
    print(f"  repairAttempted=true 문서: {repair_attempted_count}건")
    print(f"  전/후 쌍이 명확한 문서(candidateScores 길이==2): {repair_unambiguous_count}건")
    if repair_unambiguous_count:
        pct_changed = repair_changed_count / repair_unambiguous_count * 100
        print(f"    그중 점수가 바뀐 건: {repair_changed_count}건 ({pct_changed:.1f}%)")
    else:
        print("    (해당 없음 — 분모 0)")
    print(
        f"  전/후 쌍을 특정할 수 없는 모호 케이스(길이 1 또는 3+): {repair_ambiguous_count}건 "
        "— 파일 상단 주석 참고, 판단하지 않고 집계만 함"
    )


if __name__ == "__main__":
    main()
