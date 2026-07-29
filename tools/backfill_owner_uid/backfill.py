"""wardrobe 컬렉션의 기존 문서(다중 사용자 격리 이전, ownerUid 필드 없음)에
ownerUid를 채워 넣는다. docs/task_multi_user.md D.2 규약.

기본 동작은 ownerUid 필드가 이미 있는 문서는 값이 무엇이든 절대 건드리지
않는 것이다 — 그래서 재실행해도 안전하다(대상은 매번 "없는 문서"만 다시
집계된다). --force를 주면 이미 값이 있는 문서도 덮어쓴다(예: 잘못된
uid로 백필된 뒤 재배정이 필요할 때) — 이 경우 재실행 안전성이 깨지므로
호출부에서 명시적으로 선택해야 한다.

서비스 계정 키는 --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS 환경변수로만
받고, 이 저장소 안의 경로는 거부한다. 기본 동작은 dry-run — 실제로 쓰려면
--apply와 --owner-uid를 함께 명시해야 하고, 그때는 대상 프로젝트 id를 사람이
직접 입력해야 진행된다(tools/migrate_to_personal/migrate.py와 동일한 확인 방식).

마지막에 ownerUid가 없는 문서 수를 다시 세어 0이 아니면 실패로 종료한다 —
백필에서 누락된 문서는 그 옷이 화면에서 영원히 사라진다는 뜻이라, 사람이 로그를
안 봐도 스크립트가 스스로 확인해야 한다.

사용법:
    # 1. dry-run — 아무것도 안 씀, 대상 수와 샘플만 확인
    python backfill.py --credentials ~/secrets/personal-adminsdk.json

    # 2. 확인 후 실제 백필
    python backfill.py --credentials ~/secrets/personal-adminsdk.json \
        --apply --owner-uid <uid>

    # 3. 이미 값이 있는 문서까지 새 uid로 재배정(--force)
    python backfill.py --credentials ~/secrets/personal-adminsdk.json \
        --apply --owner-uid <새 uid> --force
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

# Windows 콘솔이 cp949 등 레거시 코드페이지면 한글/em-dash 출력에서
# UnicodeEncodeError가 날 수 있다 — --help(조기 종료)도 영향받으므로
# argparse 실행보다 먼저, 모듈 로드 시점에 강제한다.
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent

WARDROBE_COL = "wardrobe"
BATCH_LIMIT = 400  # Firestore 배치 쓰기 최대 500건, 여유를 둔다.


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


USERS_COL = "users"


def resolve_owner_uid(db, explicit_owner_uid: str | None) -> tuple[str | None, str, list[str]]:
    """부여할 ownerUid와 "어떻게 결정했는지" 설명을 반환한다.

    --owner-uid가 명시되면 그 값을 그대로 쓴다(가장 안전 — 사람이 확인한 값).
    명시되지 않으면 users 컬렉션(문서 id == uid)을 훑어 후보를 모으는데,
    문서가 정확히 1개일 때만 "그 uid"로 자동 결정한다. 0개거나 2개 이상이면
    자동 결정하지 않고 None을 반환한다 — 후보가 여럿인데 하나를 임의로 골라
    엉뚱한 사용자의 옷장을 만들어버리는 사고를 막기 위함이다.

    반환값: (결정된 uid 또는 None, 설명 문자열, users 문서 id 목록)
    """
    user_ids = [doc.id for doc in db.collection(USERS_COL).stream()]

    if explicit_owner_uid:
        return (
            explicit_owner_uid,
            "명시적으로 --owner-uid로 지정됨(users 컬렉션 문서 수와 무관)",
            user_ids,
        )

    if len(user_ids) == 1:
        return (
            user_ids[0],
            f"users 컬렉션에 문서가 1개뿐이라 자동 결정: {user_ids[0]}",
            user_ids,
        )

    if len(user_ids) == 0:
        return (
            None,
            "users 컬렉션에 문서가 없어 자동 결정 불가 — --owner-uid를 직접 지정하세요",
            user_ids,
        )

    return (
        None,
        f"users 컬렉션에 문서가 {len(user_ids)}개라 자동 결정 위험(후보 여럿) — "
        f"--owner-uid를 직접 지정하세요",
        user_ids,
    )


def find_missing_owner_uid(db) -> list:
    """ownerUid 필드가 없는 wardrobe 문서만 반환한다. 있는 문서는 값과 무관하게
    건드리지 않으므로, 이 함수의 결과가 기본(non-force) 모드의 "진짜 대상"이다."""
    missing = []
    for doc in db.collection(WARDROBE_COL).stream():
        data = doc.to_dict() or {}
        if "ownerUid" not in data:
            missing.append(doc)
    return missing


def find_mismatched_owner_uid(db, expected_uid: str) -> list:
    """ownerUid가 없거나 expected_uid와 다른 wardrobe 문서를 반환한다.
    --force 적용 후 "전부 재배정됐는지"를 검증할 때 쓴다."""
    mismatched = []
    for doc in db.collection(WARDROBE_COL).stream():
        data = doc.to_dict() or {}
        if data.get("ownerUid") != expected_uid:
            mismatched.append(doc)
    return mismatched


def find_target_docs(db, force: bool) -> list:
    """이번 실행에서 ownerUid를 쓸 대상 문서 목록.

    force가 아니면 find_missing_owner_uid와 동일(있는 문서는 건드리지 않음).
    force면 wardrobe 전체가 대상이다 — 이미 다른 값이 기록된 문서까지
    덮어쓰겠다는 뜻이므로 호출부가 --force로 명시했을 때만 이 경로를 탄다."""
    if force:
        return list(db.collection(WARDROBE_COL).stream())
    return find_missing_owner_uid(db)


def print_samples(target: list, sample_count: int, force: bool) -> None:
    print(f"=== 샘플 (최대 {sample_count}건) ===")
    if not target:
        print("  (대상 없음)")
    for doc in target[:sample_count]:
        data = doc.to_dict() or {}
        created_at = data.get("createdAt")
        if force:
            current = data.get("ownerUid", "(없음)")
            print(f"  itemId={doc.id} createdAt={created_at} 현재ownerUid={current}")
        else:
            print(f"  itemId={doc.id} createdAt={created_at}")
    print("========================\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--credentials",
        help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용",
    )
    parser.add_argument("--apply", action="store_true", help="실제로 반영한다(기본은 dry-run)")
    parser.add_argument("--owner-uid", help="백필할 ownerUid 값 (--apply 시 필수)")
    parser.add_argument(
        "--force",
        action="store_true",
        help="이미 ownerUid가 있는 문서도 덮어쓴다(기본은 없는 문서만 대상 — 재실행 안전성이 깨지니 신중히)",
    )
    parser.add_argument("--sample-count", type=int, default=5, help="dry-run 시 출력할 샘플 개수")
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print("\n=== wardrobe ownerUid 백필 ===")
    print(f"프로젝트: {project_id}")
    print(f"모드: {mode_label}")
    print("==============================\n")

    app = firebase_admin.initialize_app(cred)
    db = firestore.client(app=app)

    # ── 부여할 ownerUid 결정 (dry-run/apply 공통 — 항상 먼저 보여준다) ──
    resolved_uid, resolution_reason, user_ids = resolve_owner_uid(db, args.owner_uid)
    print("=== 부여 예정 ownerUid ===")
    print(f"users 컬렉션 문서 수: {len(user_ids)}")
    if len(user_ids) > 1:
        shown = ", ".join(user_ids[:10])
        more = f" 외 {len(user_ids) - 10}건" if len(user_ids) > 10 else ""
        print(f"  후보: {shown}{more}")
    print(f"결정 방식: {resolution_reason}")
    print(f"부여할 ownerUid: {resolved_uid if resolved_uid else '(결정 불가 — --owner-uid 직접 지정 필요)'}")
    print("==========================\n")

    if args.apply and not args.owner_uid:
        print(
            "--apply 시 --owner-uid가 필요합니다. 자동 후보를 찾았더라도 사람이 "
            "직접 확인한 값을 --owner-uid로 명시해야 반영됩니다.",
            file=sys.stderr,
        )
        sys.exit(1)

    if args.force:
        print(
            "!! --force: 이미 ownerUid가 있는 문서도 이번 값으로 덮어씁니다 "
            "(재실행 안전성이 깨지는 모드).\n"
        )

    if args.apply:
        force_note = " (--force: 기존 값 있는 문서 포함)" if args.force else ""
        answer = input(
            f"프로젝트 {project_id}의 wardrobe 문서에 ownerUid={args.owner_uid}를 기록합니다{force_note}.\n"
            f"진행하려면 대상 프로젝트 id를 입력하세요 [{project_id}]: "
        ).strip()
        if answer != project_id:
            print("입력이 대상 프로젝트 id와 일치하지 않습니다 — 중단합니다.", file=sys.stderr)
            sys.exit(1)

    target = find_target_docs(db, args.force)
    total_target = len(target)
    if args.force:
        already_set = sum(1 for doc in target if "ownerUid" in (doc.to_dict() or {}))
        print(f"[wardrobe] 대상 문서(전체, --force): {total_target}건 "
              f"(그중 기존 ownerUid 덮어쓰는 문서 {already_set}건)\n")
    else:
        print(f"[wardrobe] ownerUid 없는 문서: {total_target}건\n")

    if not args.apply:
        print_samples(target, args.sample_count, args.force)
        print("dry-run입니다. 결과를 확인한 뒤 --apply --owner-uid <uid>로 다시 실행하면 실제로 반영됩니다.")
        return

    if total_target == 0:
        print("백필할 문서가 없습니다 — 이미 완료된 상태로 보입니다.")
    else:
        written = 0
        batch = db.batch()
        batch_count = 0
        for doc in target:
            batch.update(doc.reference, {"ownerUid": args.owner_uid})
            batch_count += 1
            written += 1
            if batch_count >= BATCH_LIMIT:
                batch.commit()
                print(f"  ... {written}/{total_target}건 커밋")
                batch = db.batch()
                batch_count = 0
        if batch_count > 0:
            batch.commit()
        print(f"백필 완료: {written}건 기록")

    # ── 검증 ──
    # --force면 "전체가 이번 uid로 재배정됐는지"까지 확인한다(더 엄격).
    # 아니면 기존과 동일하게 "ownerUid 없는 문서가 0건인지"만 확인한다 —
    # 다른 사용자의 기존 ownerUid를 그대로 둔 것도 정상이기 때문.
    print("\n=== 검증 ===")
    if args.force:
        mismatched = find_mismatched_owner_uid(db, args.owner_uid)
        print(f"백필 후 ownerUid != {args.owner_uid} 인 문서: {len(mismatched)}건")
        if mismatched:
            print("실패 — 다음 문서가 재배정되지 않았습니다:", file=sys.stderr)
            for doc in mismatched[:20]:
                print(f"  ! {doc.id}", file=sys.stderr)
            sys.exit(1)
        print("검증 통과 — 전체 문서가 이번 ownerUid로 재배정됨")
    else:
        still_missing = find_missing_owner_uid(db)
        print(f"백필 후 ownerUid 없는 문서: {len(still_missing)}건")
        if still_missing:
            print("실패 — 다음 문서에 ownerUid가 기록되지 않았습니다:", file=sys.stderr)
            for doc in still_missing[:20]:
                print(f"  ! {doc.id}", file=sys.stderr)
            sys.exit(1)
        print("검증 통과 — 누락 0건")


if __name__ == "__main__":
    main()
