"""wardrobe/demo_wardrobe 문서에 imagePath/cutoutPath 필드를 백필한다
(다운로드 URL의 `/o/{encodedPath}`에서 경로를 역산). docs/
task_signed_urls_v1.md Phase B 규약.

fitting_cache는 대상에서 write를 하지 않는다 — 그 컬렉션의 경로는
문서 id에서 결정론적으로 나온다(`fitting_results/{id}.jpg`,
functions/src/signed_url_policy.ts의 규칙과 동일)라 저장할 필드가
없다. 다만 지시서가 "대상: wardrobe·demo_wardrobe·fitting_cache"라고
명시했으므로, fitting_cache는 **감사(파일 존재 확인)만** 이 스크립트가
같이 수행한다 — write는 없다.

[설계 보강 2026-08-06, 관문 A 조사에서 고아 참조 3건 발견 이후]:
경로 역산은 URL 문자열만 보고 성공 여부를 판단하며 파일이 실제로
있는지는 모른다. 그래서 dry-run은 "경로 역산 성공/실패"와 "파일
존재/부재"를 **두 축으로 분리**해 보고한다 — 역산 성공 + 파일 부재인
문서(고아 참조)가 역산 성공 쪽에 섞여 "정상"으로 보이면 안 된다.
**파일이 없어도 path 필드는 그대로 백필 대상에 포함한다** — 경로 계산
자체는 유효하고(파일이 없을 뿐 경로는 맞다), 존재 여부는 별도 문제다.
이 스크립트는 부재 건을 골라내 빼지 않는다 — 그건 사람이 처분을
정할 문제다(§8-5).

[범위 축소 2026-08-06]: wardrobe는 여러 ownerUid(본인/심사 계정 등)를
섞어 담고 있다. --owner-uid를 주면 wardrobe만 그 소유자로 좁혀
백필한다 — demo_wardrobe는 ownerUid 필드 자체가 없는 공용 컬렉션이라
uid로 못 거르므로, --owner-uid를 쓰면 demo_wardrobe는 이번 실행에서
통째로 건너뛰고 그 사실을 출력에 명시한다(조용히 빠지면 안 됨).

[롤백 대비 2026-08-06]: --apply는 실제로 쓴 (컬렉션, 문서id, 필드명,
갮 필드)를 로컬 manifest(JSON, manifests/ 아래, 커밋 대상 아님)로
남긴다. --rollback <manifest>는 그 manifest에 적힌 필드만 정확히
지운다 — "이미 path 보유"라 애초에 건드리지 않은 문서(예: 정상
업로드로 이미 imagePath가 있던 문서)는 manifest에 없으므로 롤백
대상도 아니다. 필드 단위로 정밀하게 되돌리기 위해 문서 전체를 지우지
않는다.

기존 백필 규약(tools/backfill_owner_uid와 동일) 준수:
- **이미 imagePath/cutoutPath가 있는 문서는 절대 덮어쓰지 않는다.**
  재실행해도 안전 — 대상은 매번 "필드 없는 문서"만 다시 집계된다.
- 기본 동작은 dry-run. `--apply`를 붙여야 실제로 반영된다.
- `--apply`/`--rollback` 실행 시 대상 프로젝트 id를 보여주고, 직접
  입력해야만 진행.
- 서비스 계정 키는 저장소 밖 경로(`--credentials`) 또는
  `GOOGLE_APPLICATION_CREDENTIALS`로만 받는다.
- **URL 필드(imageUrl/cutoutImageUrl)는 절대 건드리지 않는다**
  (task_signed_urls_v1.md §1-4) — path 필드를 추가/삭제만 한다.

사용법:
    # 1. dry-run — 아무것도 안 씀, 두 축 집계와 샘플만 확인
    python backfill.py --credentials ~/secrets/personal-adminsdk.json

    # 1b. 특정 사용자로 좁힌 dry-run(demo_wardrobe는 건너뜀)
    python backfill.py --credentials ~/secrets/personal-adminsdk.json \
        --owner-uid <uid>

    # 2. 확인 후 실제 백필(manifest 자동 기록)
    python backfill.py --credentials ~/secrets/personal-adminsdk.json --apply

    # 3. 롤백 — manifest에 적힌 필드만 정확히 삭제
    python backfill.py --credentials ~/secrets/personal-adminsdk.json \
        --rollback manifests/backfill_20260806_153000.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

try:
    import firebase_admin
    from firebase_admin import credentials, firestore, storage
    from firebase_admin.firestore import DELETE_FIELD
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
MANIFEST_DIR = SCRIPT_DIR / "manifests"

DEFAULT_BUCKET = "ai-fashion-assistant-personal.firebasestorage.app"
BATCH_LIMIT = 400  # Firestore 배치 쓰기 최대 500건, 여유를 둔다.

# (컬렉션, URL 필드 → path 필드) — fitting_cache는 write 대상이 아니라
# 여기 없다(별도로 감사만 한다).
WRITE_TARGETS = {
    "wardrobe": [("imageUrl", "imagePath"), ("cutoutImageUrl", "cutoutPath")],
    "demo_wardrobe": [("imageUrl", "imagePath"), ("cutoutImageUrl", "cutoutPath")],
}


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


def _confirm_project(project_id: str, action: str) -> None:
    answer = input(
        f"\n프로젝트 {project_id}에 {action}합니다.\n"
        f"진행하려면 대상 프로젝트 id를 입력하세요 [{project_id}]: "
    ).strip()
    if answer != project_id:
        print("입력이 대상 프로젝트 id와 일치하지 않습니다 — 중단합니다.", file=sys.stderr)
        sys.exit(1)


# signed_url_policy.ts의 pathFromDownloadUrl과 동일 규칙 — 반드시 같은
# 결과를 내야 한다(백필이 만든 path와 서버가 즉석 역산하는 path가 다르면
# 백필의 의미가 없다).
def path_from_download_url(url: str | None) -> str | None:
    if not url:
        return None
    match = re.search(r"/o/([^?]+)", url)
    if not match:
        return None
    try:
        return unquote(match.group(1))
    except Exception:
        return None


def run_rollback(db, manifest_path: Path, project_id: str) -> None:
    if not manifest_path.is_file():
        print(f"manifest 파일을 찾을 수 없습니다: {manifest_path}", file=sys.stderr)
        sys.exit(1)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.get("writes", [])
    if not entries:
        print("manifest에 롤백할 항목이 없습니다.")
        return

    print(f"\nmanifest: {manifest_path} ({len(entries)}개 필드 기록)")
    print(f"이 manifest는 {manifest.get('created_at')}에 --apply로 생성됨.")
    _confirm_project(project_id, f"manifest {len(entries)}건 롤백(필드 삭제)")

    batch = db.batch()
    pending = 0

    def flush():
        nonlocal batch, pending
        if pending > 0:
            batch.commit()
            batch = db.batch()
            pending = 0

    by_doc: dict[tuple[str, str], dict] = {}
    for e in entries:
        key = (e["collection"], e["doc_id"])
        by_doc.setdefault(key, {})[e["field"]] = DELETE_FIELD

    for (collection, doc_id), fields in by_doc.items():
        batch.update(db.collection(collection).document(doc_id), fields)
        pending += 1
        if pending >= BATCH_LIMIT:
            flush()
    flush()

    print(f"{len(by_doc)}개 문서에서 필드 {len(entries)}개 삭제 완료.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials", help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용")
    parser.add_argument("--apply", action="store_true", help="실제로 반영한다(기본은 dry-run). fitting_cache는 --apply여도 아무것도 안 쓴다")
    parser.add_argument("--owner-uid", help="wardrobe를 이 ownerUid로 좁힌다. 주면 demo_wardrobe는 건너뛴다(ownerUid 필드 없음)")
    parser.add_argument("--rollback", metavar="MANIFEST_PATH", help="지정한 manifest에 적힌 필드만 정확히 삭제하고 종료")
    parser.add_argument("--bucket", default=DEFAULT_BUCKET, help="Storage 버킷 이름")
    parser.add_argument("--sample-count", type=int, default=5, help="dry-run 시 각 분류별로 보여줄 샘플 수")
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    if args.rollback:
        print("\n=== 이미지 경로 백필 롤백 ===")
        print(f"프로젝트: {project_id}")
        print("==========================\n")
        app = firebase_admin.initialize_app(cred, {"storageBucket": args.bucket})
        db = firestore.client(app=app)
        run_rollback(db, Path(args.rollback), project_id)
        return

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print("\n=== 이미지 경로 백필 (Phase B) ===")
    print(f"프로젝트: {project_id}")
    print(f"모드: {mode_label}")
    print(f"owner-uid 범위: {args.owner_uid if args.owner_uid else '전체(모든 소유자)'}")
    if args.owner_uid:
        print("  -> demo_wardrobe는 ownerUid가 없는 공용 컬렉션이라 이번 실행에서 건너뜁니다.")
    print("==========================\n")

    if args.apply:
        scope = f"owner-uid={args.owner_uid}" if args.owner_uid else "전체 소유자"
        _confirm_project(project_id, f"wardrobe(+demo_wardrobe)에 path 필드 백필({scope})")

    app = firebase_admin.initialize_app(cred, {"storageBucket": args.bucket})
    db = firestore.client(app=app)
    bucket = storage.bucket(app=app)

    grand_total = {"resolve_ok_exists": 0, "resolve_ok_missing": 0, "resolve_fail": 0, "already_has_path": 0, "no_url": 0}
    write_batch = db.batch()
    write_count = 0
    pending_writes = 0
    manifest_writes: list[dict] = []

    def flush_batch():
        nonlocal write_batch, pending_writes
        if pending_writes > 0:
            write_batch.commit()
            write_batch = db.batch()
            pending_writes = 0

    for collection, field_pairs in WRITE_TARGETS.items():
        if args.owner_uid and collection == "demo_wardrobe":
            print(f"[{collection}] 건너뜀(--owner-uid 범위, ownerUid 필드 없음)")
            continue

        query = db.collection(collection)
        if args.owner_uid and collection == "wardrobe":
            query = query.where("ownerUid", "==", args.owner_uid)
        docs = list(query.stream())
        print(f"[{collection}] {len(docs)}건 순회")
        samples_shown = 0
        doc_updates: dict[str, dict] = {}

        for doc in docs:
            data = doc.to_dict() or {}
            for url_field, path_field in field_pairs:
                url = data.get(url_field)
                existing_path = data.get(path_field)
                if existing_path is not None:
                    grand_total["already_has_path"] += 1
                    continue
                if url is None:
                    grand_total["no_url"] += 1
                    continue

                derived = path_from_download_url(url)
                if derived is None:
                    grand_total["resolve_fail"] += 1
                    print(f"  [역산 실패] {collection}/{doc.id}.{url_field} — URL 형식이 예상과 다름")
                    continue

                exists = bucket.blob(derived).exists()
                if exists:
                    grand_total["resolve_ok_exists"] += 1
                else:
                    grand_total["resolve_ok_missing"] += 1
                    print(f"  [파일 없음 — 확인 필요] {collection}/{doc.id}.{path_field} = {derived}")

                doc_updates.setdefault(doc.id, {})[path_field] = derived

                if samples_shown < args.sample_count and not args.apply:
                    exists_label = "존재" if exists else "부재"
                    print(f"  샘플: {collection}/{doc.id} {path_field}={derived} (파일 {exists_label})")
                    samples_shown += 1

        if args.apply:
            for doc_id, fields in doc_updates.items():
                write_batch.set(db.collection(collection).document(doc_id), fields, merge=True)
                pending_writes += 1
                write_count += 1
                for field_name, value in fields.items():
                    manifest_writes.append({
                        "collection": collection, "doc_id": doc_id,
                        "field": field_name, "value": value,
                    })
                if pending_writes >= BATCH_LIMIT:
                    flush_batch()
            flush_batch()

    # fitting_cache — write 없음, 감사만(--owner-uid로 좁히지 않는다 —
    # ownerUid가 있는 문서도 레거시도 섞여 있고 이건 감사일 뿐이라 전량이
    # 더 유용하다).
    fc_total = {"exists": 0, "missing": 0}
    fc_docs = list(db.collection("fitting_cache").stream())
    print(f"\n[fitting_cache] {len(fc_docs)}건 순회 (write 없음 — 경로는 문서 id에서 결정론적으로 나옴, 감사만)")
    for doc in fc_docs:
        derived = f"fitting_results/{doc.id}.jpg"
        exists = bucket.blob(derived).exists()
        if exists:
            fc_total["exists"] += 1
        else:
            fc_total["missing"] += 1
            print(f"  [파일 없음 — 확인 필요] fitting_cache/{doc.id} = {derived}")

    print("\n=== 집계 (wardrobe + demo_wardrobe, imageUrl/cutoutImageUrl 필드 단위) ===")
    print(f"이미 path 보유(건드리지 않음): {grand_total['already_has_path']}")
    print(f"URL 필드 자체 없음(대상 아님): {grand_total['no_url']}")
    print(f"경로 역산 실패: {grand_total['resolve_fail']}")
    print(f"경로 역산 성공 + 파일 존재: {grand_total['resolve_ok_exists']}")
    print(f"경로 역산 성공 + 파일 부재(고아 참조 후보): {grand_total['resolve_ok_missing']}")
    print(f"\n=== fitting_cache 감사 ===")
    print(f"파일 존재: {fc_total['exists']}")
    print(f"파일 부재: {fc_total['missing']}")

    if args.apply:
        MANIFEST_DIR.mkdir(exist_ok=True)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        manifest_path = MANIFEST_DIR / f"backfill_{timestamp}.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "created_at": datetime.now(timezone.utc).isoformat(),
                    "project_id": project_id,
                    "owner_uid_scope": args.owner_uid,
                    "writes": manifest_writes,
                },
                ensure_ascii=False, indent=2,
            ),
            encoding="utf-8",
        )
        print(f"\n{write_count}개 문서에 path 필드 {len(manifest_writes)}개 기록 완료(파일 부재 건 포함 — 경로는 그대로 남긴다).")
        print(f"롤백용 manifest: {manifest_path}")
        print(f"되돌리려면: python backfill.py --credentials ... --rollback {manifest_path}")
    else:
        print("\ndry-run입니다. 확인 후 --apply로 다시 실행하면 실제로 반영됩니다(manifest 자동 기록).")
        print("(--apply를 붙여도 fitting_cache에는 아무것도 쓰지 않습니다.)")


if __name__ == "__main__":
    main()
