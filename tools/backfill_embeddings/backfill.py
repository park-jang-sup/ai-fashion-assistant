"""옷장 아이템(Firestore `wardrobe` 컬렉션)에 이미지 임베딩을 백필한다.

tools/export_for_kaggle/embeddings.json (Kaggle 임베딩 비교 실험 산출물)을
읽어 각 wardrobe 문서에 `embedding` 필드로 저장한다. 앱 코드(lib/)는
전혀 건드리지 않는다.

서비스 계정 키는 tools/export_for_kaggle/export.py와 동일한 원칙으로
GOOGLE_APPLICATION_CREDENTIALS 환경변수 또는 --credentials로만 참조하고,
이 저장소 안의 경로는 거부한다.

기본 동작은 dry-run이다 — 실제로 Firestore에 쓰려면 --apply를 명시해야 한다.

사용법:
    export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json
    python backfill.py                 # dry-run — 아무것도 쓰지 않음
    python backfill.py --apply         # 실제 반영
    python backfill.py --apply --force # 이미 embedding 있는 문서도 덮어쓰기
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_EMBEDDINGS_FILE = REPO_ROOT / "tools" / "export_for_kaggle" / "embeddings.json"

WARDROBE_COL = "wardrobe"
SKIP_CATEGORY = "전신"  # 아이템 컷아웃이 아니라 착장 스냅 사진이라 임베딩 대상 아님
DEFAULT_MODEL_NAME = "patrickjohncyh/fashion-clip"
DEFAULT_DIM = 512
NORM_LOW, NORM_HIGH = 0.99, 1.01


@dataclass
class BackfillCounts:
    would_update: int = 0
    updated: int = 0
    skipped_existing: int = 0
    skipped_whole_body: int = 0
    skipped_not_in_file: int = 0
    failed_validation: int = 0
    failed_write: int = 0


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
    if REPO_ROOT in Path(cred_path).resolve().parents or Path(cred_path).resolve() == REPO_ROOT:
        print(
            "서비스 계정 키를 이 저장소 안에 두지 마세요 — 저장소 밖의 안전한 경로를 사용하세요.",
            file=sys.stderr,
        )
        sys.exit(1)

    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)


def load_embeddings(path: Path, model_name_override: str, dim_override: int):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, dict) and isinstance(data.get("embeddings"), dict):
        model_name = data.get("model") or model_name_override
        dim = data.get("dim") or dim_override
        vectors = data["embeddings"]
        print(
            f"[임베딩파일] 래핑된 형식 감지({path.name}) — "
            f"model={model_name}, dim={dim}, 아이템 {len(vectors)}개"
        )
    else:
        model_name = model_name_override
        dim = dim_override
        vectors = data
        print(
            f"[임베딩파일] 평면 형식(itemId->vector) 감지({path.name}) — "
            f"파일에 모델 정보가 없어 기본값 사용: model={model_name}, dim={dim}, "
            f"아이템 {len(vectors)}개"
        )
    return model_name, dim, vectors


def validate_vector(vector, expected_dim: int) -> tuple[bool, str | None, float | None]:
    """(통과 여부, 실패 사유, norm) 반환. 캐글에서 이미 L2 정규화했지만 JSON
    직렬화를 한 번 거쳤으니 저장 전에 다시 확인한다."""
    if not isinstance(vector, list):
        return False, f"벡터가 배열이 아님(type={type(vector).__name__})", None
    if len(vector) != expected_dim:
        return False, f"길이 불일치(기대 {expected_dim}, 실제 {len(vector)})", None

    floats = []
    for v in vector:
        try:
            f = float(v)
        except (TypeError, ValueError):
            return False, f"숫자로 변환 불가한 값: {v!r}", None
        if not math.isfinite(f):
            return False, f"NaN/inf 값 포함", None
        floats.append(f)

    norm = math.sqrt(sum(f * f for f in floats))
    if not (NORM_LOW <= norm <= NORM_HIGH):
        return False, f"L2 norm이 1에서 벗어남({norm:.4f}, 허용 {NORM_LOW}~{NORM_HIGH})", None

    return True, None, norm


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials", help="서비스 계정 키 JSON 로컬 경로 (기본: GOOGLE_APPLICATION_CREDENTIALS 환경변수)")
    parser.add_argument("--embeddings-file", default=str(DEFAULT_EMBEDDINGS_FILE), help="embeddings.json 경로")
    parser.add_argument("--model-name", default=DEFAULT_MODEL_NAME, help="파일이 평면 형식이라 모델명이 없을 때 쓸 기본값")
    parser.add_argument("--dim", type=int, default=DEFAULT_DIM, help="파일이 평면 형식이라 차원 정보가 없을 때 쓸 기본값")
    parser.add_argument("--force", action="store_true", help="이미 embedding 필드가 있는 문서도 덮어쓰기")
    parser.add_argument("--apply", action="store_true", help="실제로 Firestore에 쓴다 (기본은 dry-run)")
    parser.add_argument("--sample-count", type=int, default=3, help="dry-run 시 상세 출력할 샘플 개수")
    args = parser.parse_args()

    # Windows 콘솔이 cp949 등 레거시 코드페이지면 한글/em-dash 출력에서
    # UnicodeEncodeError가 날 수 있어 표준출력을 UTF-8로 강제한다.
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")

    embeddings_path = Path(args.embeddings_file).resolve()
    if not embeddings_path.is_file():
        print(f"embeddings.json을 찾을 수 없습니다: {embeddings_path}", file=sys.stderr)
        sys.exit(1)

    init_firebase(args.credentials)
    db = firestore.client()

    model_name, dim, vectors = load_embeddings(embeddings_path, args.model_name, args.dim)

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print(f"\n=== 모드: {mode_label} — force={args.force} ===\n")

    counts = BackfillCounts()
    samples_shown = 0

    docs = list(db.collection(WARDROBE_COL).stream())
    print(f"[wardrobe] Firestore 문서 {len(docs)}개 발견\n")

    for doc in docs:
        item_id = doc.id
        data = doc.to_dict() or {}
        category = data.get("category")

        if category == SKIP_CATEGORY:
            counts.skipped_whole_body += 1
            continue

        vector = vectors.get(item_id)
        if vector is None:
            counts.skipped_not_in_file += 1
            continue

        if data.get("embedding") is not None and not args.force:
            counts.skipped_existing += 1
            continue

        ok, reason, norm = validate_vector(vector, dim)
        if not ok:
            counts.failed_validation += 1
            print(f"  ! {item_id}: 벡터 검증 실패 — {reason}")
            continue

        if not args.apply:
            counts.would_update += 1
            if samples_shown < args.sample_count:
                preview = ", ".join(f"{x:.4f}" for x in vector[:5])
                print(
                    f"  [샘플 {samples_shown + 1}] itemId={item_id} category={category} "
                    f"vector[:5]=[{preview}, ...] norm={norm:.4f}"
                )
                samples_shown += 1
            continue

        try:
            doc.reference.update({
                "embedding": {
                    "model": model_name,
                    "dim": dim,
                    "vector": vector,
                    # embedding 맵 전체를 통째로 set하는 update()라, 안에
                    # SERVER_TIMESTAMP(transform)를 넣으면 필드 경로 충돌로
                    # Firestore가 거부한다 — 백필 기록용이라 서버 시각일
                    # 필요도 없어 클라이언트 UTC 시각을 그냥 쓴다.
                    "createdAt": datetime.now(timezone.utc),
                }
            })
            counts.updated += 1
        except Exception as e:  # noqa: BLE001 - 스크립트 도구, 개별 실패는 로그만 남기고 계속
            counts.failed_write += 1
            print(f"  ! {item_id}: Firestore 쓰기 실패 — {e}")

    print("\n=== 완료 ===")
    if args.apply:
        print(f"저장 성공: {counts.updated}")
    else:
        print(f"저장 예정(dry-run, 실제 반영 안 함): {counts.would_update}")
    print(f"스킵 — 이미 embedding 있음: {counts.skipped_existing}")
    print(f"스킵 — '전신' 카테고리: {counts.skipped_whole_body}")
    print(f"스킵 — 임베딩 파일에 없음: {counts.skipped_not_in_file}")
    print(f"실패 — 벡터 검증: {counts.failed_validation}")
    if args.apply:
        print(f"실패 — Firestore 쓰기: {counts.failed_write}")

    if not args.apply:
        print("\ndry-run입니다. 결과를 확인한 뒤 --apply를 붙여 다시 실행하면 실제로 반영됩니다.")


if __name__ == "__main__":
    main()
