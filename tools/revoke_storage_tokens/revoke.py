"""wardrobe_images/, wardrobe_cutouts/ 아래 파일의
firebaseStorageDownloadTokens 커스텀 메타데이터를 제거한다(Phase C
토큰 회수, docs/task_signed_urls_v1.md). **파일 자체는 지우지 않는다**
— 메타데이터만 지워 기존 다운로드 URL(쿼리의 구 토큰 값)을 무효화한다.
서명 URL(V4, IAM signBlob 기반)은 이 토큰과 무관하므로 회수해도 영향
없다.

되돌리기 어려운 단계라(§0 "실패 방향은 보수적", 5.11.2 "배포 순서
역전 사고"와 같은 층위) --apply 전 반드시 dry-run으로 대상 개수·
경로 샘플·토큰 보유 여부를 확인하고 승인받는다. --apply는 실제로
제거한 (경로, 원래 토큰 값)을 manifest(JSON, manifests/ 아래, 커밋
대상 아님)에 남겨 --rollback으로 **정확히 같은 토큰 값**을 복원할
수 있게 한다(tools/backfill_image_paths의 manifest 패턴과 동일 —
Firebase Storage는 토큰 이력을 따로 추적하지 않고 그 순간의
메타데이터 값만 보므로, 원래 값을 그대로 복원하면 원래 URL이 다시
살아난다).

demo_wardrobe는 wardrobe와 같은 물리 파일(같은 경로)을 재사용한다
(tools/seed_demo_wardrobe README 참고) — 이 스크립트는 Storage
객체 단위로 동작하므로 별도 처리가 필요 없다. 회수 한 번으로 두
컬렉션의 참조가 동시에 무효화된다.

대상은 --prefixes로 지정(기본 wardrobe_images/ wardrobe_cutouts/).
fitting_results/는 기본 대상이 아니다 — 재생성·캐시 히트 경로와
얽혀 성격이 달라 Phase C-3에서 별도 처리한다(task_signed_urls_v1.md
참고).

안전 원칙(tools/backfill_image_paths와 동일 관례):
- 기본 dry-run — 아무것도 안 씀. --apply를 붙여야 실제로 반영된다.
- --apply/--rollback 실행 시 대상 프로젝트 id를 직접 입력해야 진행.
- 서비스 계정 키는 저장소 밖 경로만 허용.
- 파일 삭제·이동은 절대 하지 않는다(§1-2) — 메타데이터 키 하나만
  건드린다.

사용법:
    # 1. dry-run — 대상 개수·경로 샘플·토큰 보유 여부만 확인
    python revoke.py --credentials ~/secrets/personal-adminsdk.json

    # 2. 확인 후 실제 회수(manifest 자동 기록)
    python revoke.py --credentials ~/secrets/personal-adminsdk.json --apply

    # 3. 롤백 — manifest에 적힌 원래 토큰 값을 정확히 복원
    python revoke.py --credentials ~/secrets/personal-adminsdk.json \
        --rollback manifests/revoke_20260806_120000.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, storage
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
DEFAULT_PREFIXES = ["wardrobe_images/", "wardrobe_cutouts/"]
TOKEN_KEY = "firebaseStorageDownloadTokens"


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


def run_rollback(bucket, manifest_path: Path, project_id: str) -> None:
    if not manifest_path.is_file():
        print(f"manifest 파일을 찾을 수 없습니다: {manifest_path}", file=sys.stderr)
        sys.exit(1)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.get("revocations", [])
    if not entries:
        print("manifest에 복원할 항목이 없습니다.")
        return

    print(f"\nmanifest: {manifest_path} ({len(entries)}개 객체)")
    print(f"이 manifest는 {manifest.get('created_at')}에 --apply로 생성됨.")
    _confirm_project(project_id, f"manifest {len(entries)}건 롤백(토큰 복원)")

    restored = 0
    for e in entries:
        blob = bucket.blob(e["path"])
        blob.reload()
        metadata = dict(blob.metadata or {})
        metadata[TOKEN_KEY] = e["old_token"]
        blob.metadata = metadata
        blob.patch()
        restored += 1
    print(f"{restored}개 객체의 토큰 복원 완료.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials", help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용")
    parser.add_argument("--apply", action="store_true", help="실제로 반영한다(기본은 dry-run)")
    parser.add_argument("--rollback", metavar="MANIFEST_PATH", help="지정한 manifest의 토큰을 정확히 복원하고 종료")
    parser.add_argument("--prefixes", nargs="+", default=DEFAULT_PREFIXES, help=f"대상 경로 프리픽스(기본: {DEFAULT_PREFIXES})")
    parser.add_argument("--only", nargs="+", help="지정한 정확한 blob 경로만 대상으로 한다(리허설용 — --prefixes로 나열된 것 중 이 목록에 있는 것만 처리)")
    parser.add_argument("--bucket", default=DEFAULT_BUCKET, help="Storage 버킷 이름")
    parser.add_argument("--sample-count", type=int, default=5, help="dry-run 시 보여줄 샘플 수")
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    app = firebase_admin.initialize_app(cred, {"storageBucket": args.bucket})
    bucket = storage.bucket(app=app)

    if args.rollback:
        print("\n=== Storage 토큰 회수 롤백 ===")
        print(f"프로젝트: {project_id}")
        print("==========================\n")
        run_rollback(bucket, Path(args.rollback), project_id)
        return

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print("\n=== Storage 다운로드 토큰 회수 (Phase C) ===")
    print(f"프로젝트: {project_id}")
    print(f"모드: {mode_label}")
    print(f"대상 프리픽스: {', '.join(args.prefixes)}")
    print("==========================\n")

    if args.apply:
        _confirm_project(project_id, f"{', '.join(args.prefixes)} 아래 파일의 다운로드 토큰 회수")

    only_set = set(args.only) if args.only else None
    if only_set:
        print(f"--only 지정됨 — {len(only_set)}개 경로로 제한(리허설 모드)")

    has_token = []
    no_token = []
    for prefix in args.prefixes:
        blobs = list(bucket.list_blobs(prefix=prefix))
        if only_set:
            blobs = [b for b in blobs if b.name in only_set]
        print(f"[{prefix}] {len(blobs)}건 순회")
        for blob in blobs:
            metadata = blob.metadata or {}
            if TOKEN_KEY in metadata:
                has_token.append((blob, metadata[TOKEN_KEY]))
            else:
                no_token.append(blob)

    print(f"\n토큰 보유(회수 대상): {len(has_token)}")
    print(f"토큰 없음(이미 회수됐거나 애초에 없음 — 건드리지 않음): {len(no_token)}")

    for blob, _token in has_token[: args.sample_count]:
        print(f"  샘플: {blob.name}")

    if not args.apply:
        print("\ndry-run입니다. 확인 후 --apply로 다시 실행하면 실제로 반영됩니다(manifest 자동 기록).")
        return

    revocations = []
    for blob, old_token in has_token:
        metadata = dict(blob.metadata or {})
        del metadata[TOKEN_KEY]
        blob.metadata = metadata
        blob.patch()
        revocations.append({"path": blob.name, "old_token": old_token})

    MANIFEST_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    manifest_path = MANIFEST_DIR / f"revoke_{timestamp}.json"
    manifest_path.write_text(
        json.dumps(
            {
                "created_at": datetime.now(timezone.utc).isoformat(),
                "project_id": project_id,
                "prefixes": args.prefixes,
                "revocations": revocations,
            },
            ensure_ascii=False, indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\n{len(revocations)}개 객체의 토큰 회수 완료.")
    print(f"롤백용 manifest: {manifest_path}")
    print(f"되돌리려면: python revoke.py --credentials ... --rollback {manifest_path}")


if __name__ == "__main__":
    main()
