"""F'.3 지표 집계 — docs/task_demo_ready_v2.md 규약.

사용자가 한 명(본인)이어도 사업계획서에 넣을 수치는 산출 가능하다는 전제로,
Firestore를 직접 읽어 다음을 계산한다:

  - 옷장 규모·구성(총 벌 수, 카테고리별 분포, 격식 분포)
  - 속성 추출 성공률(attributes != null 비율)
  - 임베딩 보유율(embedding != null 비율)
  - 추천 채택률(userChoice == accepted / 응답 있는 추천)
  - 백그라운드 발화 간격(agent_meta.invocationLog의 시계열)

`isDemo: true`인 wardrobe 문서는 모든 집계에서 전부 제외한다 — 데모 시드가
심사위원 자신의 옷장 수치를 오염시키면 안 되기 때문이다(F'.1.4의
isDemo 플래그가 존재하는 이유 중 하나).

**옷장 커버리지(표9)는 이 스크립트가 계산하지 않는다.** 그 계산은
OutfitMatcher(실제 매칭 엔진)를 그대로 태워야 해서 Dart 쪽
test/tpo_policy_report_test.dart가 이미 하고 있다. 이 스크립트를 돌리기
전에 tools/export_for_kaggle/export.py를 --owner-uid로 필터링해 다시
내보내면(이 스크립트가 그 필터와 isDemo 제외를 export.py에도 함께
추가했다) `flutter test test/tpo_policy_report_test.dart`가 표9를 그
데이터로 재출력한다.

서비스 계정 키는 --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로만
받고, 이 저장소 안의 경로는 거부한다(다른 tools/* 스크립트와 동일 규약).
읽기 전용 스크립트라 --apply 개념이 없다 — 항상 안전하게 재실행 가능하다.

사용법:
    python report.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <본인 uid>
"""
from __future__ import annotations

import argparse
import os
import statistics
import sys
from collections import Counter
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent

WARDROBE_COL = "wardrobe"
USERS_COL = "users"
RECOMMENDATIONS_COL = "recommendations"
AGENT_META_COL = "agent_meta"
AGENT_META_BACKGROUND_DOC = "background"


def _reject_repo_path(resolved: Path, hint: str) -> None:
    if REPO_ROOT in resolved.parents or resolved == REPO_ROOT:
        print(
            f"서비스 계정 키를 이 저장소 안에 두지 마세요 ({hint}) — "
            f"저장소 밖의 안전한 경로를 쓰세요.",
            file=sys.stderr,
        )
        sys.exit(1)


def _load_credentials(cred_path_str: str | None) -> credentials.Certificate:
    if cred_path_str:
        resolved = Path(os.path.expanduser(cred_path_str)).resolve()
        if not resolved.is_file():
            print(f"서비스 계정 키 파일을 찾을 수 없습니다: {resolved}", file=sys.stderr)
            sys.exit(1)
        _reject_repo_path(resolved, "--credentials")
        return credentials.Certificate(str(resolved))

    env_path_str = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if env_path_str:
        resolved = Path(os.path.expanduser(env_path_str)).resolve()
        if not resolved.is_file():
            print(
                f"GOOGLE_APPLICATION_CREDENTIALS가 가리키는 파일을 찾을 수 없습니다: {resolved}",
                file=sys.stderr,
            )
            sys.exit(1)
        _reject_repo_path(resolved, "GOOGLE_APPLICATION_CREDENTIALS")
        return credentials.Certificate(str(resolved))

    print(
        "서비스 계정 키가 없습니다. --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS "
        "환경변수로 지정하세요.",
        file=sys.stderr,
    )
    sys.exit(1)


def report_wardrobe(db, owner_uid: str) -> None:
    print("\n=== 옷장 규모·구성 (isDemo 제외) ===")
    category_counts: Counter = Counter()
    formality_counts: Counter = Counter()
    total = 0
    attrs_count = 0
    embedding_count = 0

    for doc in db.collection(WARDROBE_COL).where("ownerUid", "==", owner_uid).stream():
        data = doc.to_dict() or {}
        if data.get("isDemo"):
            continue
        total += 1
        category_counts[data.get("category", "(없음)")] += 1
        attrs = data.get("attributes")
        if attrs is not None:
            attrs_count += 1
            formality = attrs.get("formality") if isinstance(attrs, dict) else None
            formality_counts[formality or "(없음)"] += 1
        if data.get("embedding") is not None:
            embedding_count += 1

    print(f"총 벌 수: {total}건")
    print("카테고리별 분포:")
    for cat, count in sorted(category_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {cat}: {count}건")
    print("격식 분포(attributes 보유 아이템 기준):")
    for formality, count in sorted(formality_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {formality}: {count}건")
    if total:
        print(f"속성 추출 성공률: {attrs_count}/{total} ({attrs_count / total:.1%})")
        print(f"임베딩 보유율: {embedding_count}/{total} ({embedding_count / total:.1%})")
    else:
        print("속성 추출 성공률/임베딩 보유율: 대상 없음(총 벌 수 0)")


def report_recommendation_acceptance(db, owner_uid: str) -> None:
    print("\n=== 추천 채택률 ===")
    recs = list(
        db.collection(USERS_COL).document(owner_uid).collection(RECOMMENDATIONS_COL).stream()
    )
    responded = 0
    accepted = 0
    for doc in recs:
        data = doc.to_dict() or {}
        choice = data.get("userChoice")
        if choice is None:
            continue
        responded += 1
        if choice == "accepted":
            accepted += 1

    print(f"전체 추천: {len(recs)}건")
    print(f"응답 있는 추천: {responded}건")
    if responded:
        print(f"채택률: {accepted}/{responded} ({accepted / responded:.1%})")
    else:
        print("채택률: 응답 있는 추천 없음")


def report_invocation_intervals(db, owner_uid: str) -> None:
    print("\n=== 백그라운드 발화 간격 (agent_meta.invocationLog) ===")
    doc = (
        db.collection(USERS_COL)
        .document(owner_uid)
        .collection(AGENT_META_COL)
        .document(AGENT_META_BACKGROUND_DOC)
        .get()
    )
    data = doc.to_dict() or {}
    log = data.get("invocationLog") or []
    invoke_count = data.get("invokeCount")
    skip_count = data.get("skipCount")

    print(f"invokeCount(uid+meta 읽기 성공 기준): {invoke_count}")
    print(f"skipCount(빈도 가드에 걸려 스킵): {skip_count}")
    print(f"invocationLog 기록 건수: {len(log)}건")

    if len(log) < 2:
        print("간격 산출 불가 — invocationLog가 2건 미만이다.")
        return

    # at은 전부 기기 시계(이 문서의 다른 시각 필드도 마찬가지 — 서버 시각
    # 검증 수단이 없다). 간격은 이 배열 내부 at끼리만 계산한다.
    timestamps = sorted(entry["at"] for entry in log if entry.get("at") is not None)
    gaps_hours = [
        (b - a).total_seconds() / 3600 for a, b in zip(timestamps, timestamps[1:])
    ]
    skipped_count = sum(1 for entry in log if entry.get("skipped") is True)
    print(f"skipped:true 기록: {skipped_count}건 / skipped:false 기록: {len(log) - skipped_count}건")
    print(f"발화 간격(시간) — 중앙값: {statistics.median(gaps_hours):.2f}, "
          f"최소: {min(gaps_hours):.2f}, 최대: {max(gaps_hours):.2f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--credentials",
        help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용",
    )
    parser.add_argument("--owner-uid", required=True, help="집계 대상 uid(본인 uid)")
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    print("\n=== F'.3 지표 집계 ===")
    print(f"프로젝트: {project_id}")
    print(f"대상 uid: {args.owner_uid}")
    print("=======================")

    app = firebase_admin.initialize_app(cred)
    db = firestore.client(app=app)

    report_wardrobe(db, args.owner_uid)
    report_recommendation_acceptance(db, args.owner_uid)
    report_invocation_intervals(db, args.owner_uid)

    print(
        "\n옷장 커버리지(표9)는 별도 단계다 — "
        "tools/export_for_kaggle/export.py --owner-uid <uid>로 다시 내보낸 뒤 "
        "flutter test test/tpo_policy_report_test.dart로 재계산할 것."
    )


if __name__ == "__main__":
    main()
