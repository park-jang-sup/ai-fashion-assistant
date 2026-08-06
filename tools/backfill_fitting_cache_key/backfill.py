"""users/{uid}/history의 type=='fitting' 문서에 fittingCacheKey 필드를
백필한다. docs/task_signed_urls_v1.md §10-1 (B) 결정에 따른 1회성
스크립트 — A-5(군 (c))가 이 필드를 읽어 fitting_cache 문서를 서명
대상으로 특정한다.

fittingCacheKey는 새로 계산하지 않는다 — 이미 저장된 fittingImageUrl
자체가 그 값을 인코딩하고 있다. StorageService.uploadFittingResult가
파일을 `fitting_results/{cacheKey}.jpg`에 올리므로(파일명이 곧 문서
id), URL의 `/o/{encodedPath}`에서 경로를 역산(signed_url_policy.ts의
pathFromDownloadUrl과 동일 규칙)해 프리픽스·확장자만 벗기면 원래
cacheKey가 그대로 나온다. 2026-08-06 사전 조사에서 28건 전수 실측
100% 일치(모호성·오매칭 없음) — 이 스크립트는 그 조사를 실제 반영
경로로 옮긴 것뿐이다.

fitting_cache/{cacheKey} 문서가 실제로 존재하는지 반드시 같이
확인한다 — 존재하지 않으면(캐시 문서 저장이 실패했던 극히 드문 사례,
fitting_job_controller.dart의 "uid 없으면 캐시 문서 저장만 건너뛴다"
분기 참고) 역산은 성공해도 서명 대상 문서가 없어 채워봐야 소용없다.
그런 항목은 필드를 쓰지 않고 별도로 보고만 한다.

기존 백필 규약(tools/backfill_image_paths와 동일) 준수:
- 이미 fittingCacheKey가 있는 문서는 절대 덮어쓰지 않는다.
- 기본 동작은 dry-run. --apply를 붙여야 실제로 반영된다.
- --apply/--rollback 실행 시 대상 프로젝트 id를 직접 입력해야 진행.
- 서비스 계정 키는 저장소 밖 경로만 허용.
- fittingImageUrl 필드는 절대 건드리지 않는다 — fittingCacheKey
  필드만 추가한다.
- --apply는 (컬렉션 경로, 문서id, 필드명, 값)을 manifest(JSON,
  manifests/ 아래, 커밋 대상 아님)에 남긴다. --rollback은 그 필드만
  정확히 삭제한다.

사용법:
    # 1. dry-run — 아무것도 안 씀
    python backfill.py --credentials ~/secrets/personal-adminsdk.json

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
    from firebase_admin import credentials, firestore
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

FITTING_RESULTS_PREFIX = "fitting_results/"


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


# signed_url_policy.ts의 pathFromDownloadUrl과 동일 규칙.
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


def cache_key_from_fitting_url(url: str | None) -> str | None:
    path = path_from_download_url(url)
    if not path or not path.startswith(FITTING_RESULTS_PREFIX):
        return None
    if not path.endswith(".jpg"):
        return None
    return path[len(FITTING_RESULTS_PREFIX):-len(".jpg")]


def run_rollback(db, manifest_path: Path, project_id: str) -> None:
    if not manifest_path.is_file():
        print(f"manifest 파일을 찾을 수 없습니다: {manifest_path}", file=sys.stderr)
        sys.exit(1)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.get("writes", [])
    if not entries:
        print("manifest에 롤백할 항목이 없습니다.")
        return

    print(f"\nmanifest: {manifest_path} ({len(entries)}건)")
    print(f"이 manifest는 {manifest.get('created_at')}에 --apply로 생성됨.")
    _confirm_project(project_id, f"manifest {len(entries)}건 롤백(필드 삭제)")

    restored = 0
    for e in entries:
        sub = e.get("collection", "history")  # 구 manifest(collection 필드 없음) 하위호환
        ref = db.collection("users").document(e["uid"]).collection(sub).document(e["doc_id"])
        ref.update({"fittingCacheKey": DELETE_FIELD})
        restored += 1
    print(f"{restored}개 문서에서 fittingCacheKey 필드 삭제 완료.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials", help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용")
    parser.add_argument("--apply", action="store_true", help="실제로 반영한다(기본은 dry-run)")
    parser.add_argument("--rollback", metavar="MANIFEST_PATH", help="지정한 manifest에 적힌 필드만 정확히 삭제하고 종료")
    parser.add_argument("--sample-count", type=int, default=10, help="dry-run 시 보여줄 샘플 수")
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    app = firebase_admin.initialize_app(cred)
    db = firestore.client(app=app)

    if args.rollback:
        print("\n=== fittingCacheKey 백필 롤백 ===")
        print(f"프로젝트: {project_id}")
        print("==========================\n")
        run_rollback(db, Path(args.rollback), project_id)
        return

    # 대상 서브컬렉션 3개 — 전부 독립적으로 fittingImageUrl을 저장한다
    # (2026-08-06 조사에서 발견: history/calendar/scraps가 서로 다른
    # Firestore 컬렉션이라 하나를 백필해도 나머지는 안 채워짐,
    # docs/task_signed_urls_v1.md §10 참고). "type"으로 걸러야 하는 건
    # history뿐이다 — calendar/scraps는 그런 필드가 없다.
    SUBCOLLECTIONS: list[tuple[str, str | None]] = [
        ("history", "fitting"),
        ("calendar", None),
        ("scraps", None),
    ]

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print("\n=== fittingCacheKey 백필 (docs/task_signed_urls_v1.md §10-1 (B)) ===")
    print(f"프로젝트: {project_id}")
    print(f"모드: {mode_label}")
    print(f"대상: 전 사용자 users/*/{{{', '.join(c for c, _ in SUBCOLLECTIONS)}}}")
    print("==========================\n")

    if args.apply:
        _confirm_project(project_id, "history/calendar/scraps 문서에 fittingCacheKey 백필")

    # collection_group + where는 복합 색인이 없어 FAILED_PRECONDITION으로
    # 막힌다 — 색인을 새로 배포하는 대신(그 자체가 별도 승인·대기가
    # 필요한 인프라 변경) users 컬렉션을 먼저 순회하고 사용자별 서브
    # 컬렉션에 단일 필드 쿼리(또는 무조건 순회)를 돌린다.
    users = list(db.collection("users").stream())
    print(f"users 문서 {len(users)}건 순회\n")

    already_has = 0
    no_url = 0
    resolve_fail = 0
    cache_missing = []  # (collection, uid, doc_id, cacheKey)
    targets = []  # (collection, uid, doc_id, cacheKey)

    for user_doc in users:
        uid = user_doc.id
        for sub, type_filter in SUBCOLLECTIONS:
            query = db.collection("users").document(uid).collection(sub)
            if type_filter is not None:
                query = query.where("type", "==", type_filter)
            docs = list(query.stream())
            for doc in docs:
                data = doc.to_dict() or {}
                if data.get("fittingCacheKey") is not None:
                    already_has += 1
                    continue
                url = data.get("fittingImageUrl")
                if not url:
                    no_url += 1
                    continue
                cache_key = cache_key_from_fitting_url(url)
                if cache_key is None:
                    resolve_fail += 1
                    print(f"  [역산 실패] {doc.reference.path} — fittingImageUrl 형식이 예상과 다름: {url}")
                    continue

                cache_doc = db.collection("fitting_cache").document(cache_key).get()
                if not cache_doc.exists:
                    cache_missing.append((sub, uid, doc.id, cache_key))
                    print(f"  [fitting_cache 문서 없음 — 채우지 않음] {doc.reference.path} -> {cache_key}")
                    continue

                targets.append((sub, uid, doc.id, cache_key))

    print(f"\n=== 집계 ===")
    print(f"이미 fittingCacheKey 보유(건드리지 않음): {already_has}")
    print(f"fittingImageUrl 없음(대상 아님): {no_url}")
    print(f"경로 역산 실패: {resolve_fail}")
    print(f"역산 성공했지만 fitting_cache 문서 없음(채우지 않음): {len(cache_missing)}")
    print(f"백필 대상(역산 성공 + fitting_cache 문서 존재): {len(targets)}")

    for sub, uid, doc_id, cache_key in targets[: args.sample_count]:
        print(f"  샘플: users/{uid}/{sub}/{doc_id} -> fittingCacheKey={cache_key}")

    if not args.apply:
        print("\ndry-run입니다. 확인 후 --apply로 다시 실행하면 실제로 반영됩니다(manifest 자동 기록).")
        return

    manifest_writes: list[dict] = []
    for sub, uid, doc_id, cache_key in targets:
        ref = db.collection("users").document(uid).collection(sub).document(doc_id)
        ref.update({"fittingCacheKey": cache_key})
        manifest_writes.append({
            "collection": sub, "uid": uid, "doc_id": doc_id,
            "field": "fittingCacheKey", "value": cache_key,
        })

    MANIFEST_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    manifest_path = MANIFEST_DIR / f"backfill_{timestamp}.json"
    manifest_path.write_text(
        json.dumps(
            {
                "created_at": datetime.now(timezone.utc).isoformat(),
                "project_id": project_id,
                "writes": manifest_writes,
            },
            ensure_ascii=False, indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\n{len(manifest_writes)}개 문서에 fittingCacheKey 기록 완료.")
    print(f"롤백용 manifest: {manifest_path}")
    print(f"되돌리려면: python backfill.py --credentials ... --rollback {manifest_path}")


if __name__ == "__main__":
    main()
