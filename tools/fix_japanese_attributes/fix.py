"""옷 속성(attributes)에 섞여 들어간 일본어(가나·한자)를 한국어로 정정한다.

docs/task_fitting_quality_v2.md 실행 기록 — 모자 아이템의 `핏 레ギュラー`처럼
속성 추출 결과에 일본어가 섞인 값이 가상 피팅 프롬프트에 그대로 들어간다.
이번 한 번만 Firestore 쓰기를 허용받은 작업이다(지시서 §5의 예외).

대상: wardrobe, demo_wardrobe의 attributes.{color, style, pattern, formality,
fit, tags}. 다른 필드·다른 문서는 건드리지 않는다.

흐름(다른 backfill 도구와 같은 규약):
    # 1. dry-run(기본) — 읽기만. 표를 출력하고 plans/ 아래에 계획 파일을 남긴다.
    python fix.py --credentials ~/secrets/personal-adminsdk.json

    # 2. 사람이 표(계획 파일의 "after")를 확인·승인한 뒤 그 계획만 적용.
    #    적용 직전 현재 값이 계획의 "before"와 다르면 그 항목은 건너뛴다.
    #    변경 전 값은 manifests/ 아래 manifest로 남는다.
    python fix.py --credentials ... --apply --plan plans/plan_YYYYmmdd_HHMMSS.json

    # 3. 되돌리기 — manifest의 before 값으로 그 필드만 복원.
    python fix.py --credentials ... --rollback manifests/fix_YYYYmmdd_HHMMSS.json

서비스 계정 키는 --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로만 받고
이 저장소 안의 경로는 거부한다. --apply/--rollback은 대상 프로젝트 id를 직접
입력해야 진행된다. plans/·manifests/는 실제 문서 id가 담긴 실행 산출물이라
커밋하지 않는다(.gitignore).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

try:
    from firebase_admin import credentials, firestore, initialize_app
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install firebase-admin", file=sys.stderr)
    raise

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
PLAN_DIR = SCRIPT_DIR / "plans"
MANIFEST_DIR = SCRIPT_DIR / "manifests"

COLLECTIONS = ["wardrobe", "demo_wardrobe"]
STRING_FIELDS = ["color", "style", "pattern", "formality", "fit"]

# 히라가나·가타카나(전각/반각)·CJK 한자. 한국어 속성값에는 정상적으로 나오지 않는다.
JAPANESE = re.compile(r"[぀-ヿㇰ-ㇿｦ-ﾟ㐀-䶿一-鿿]")

# 제안 값 사전 — 속성 추출 프롬프트(_buildAttributeExtractionPrompt)의 예시
# 어휘(레귤러/슬림/오버사이즈/캐주얼/…)에 맞춘다. 사전에 없는 일본어는 제안
# 없음으로 표시하고 사람이 계획 파일에서 직접 채운다.
PROPOSALS = {
    # 실제 관측(2026-11-13): 한글 첫 글자 뒤에 가타카나가 이어진 "레ギュラー"(24건).
    "레ギュラー": "레귤러",
    "レギュラー": "레귤러", "スリム": "슬림", "オーバーサイズ": "오버사이즈", "ルーズ": "루즈",
    "ワイド": "와이드", "タイト": "타이트", "ストレート": "스트레이트",
    "カジュアル": "캐주얼", "フォーマル": "포멀", "セミフォーマル": "세미포멀",
    "ストリート": "스트릿", "ミニマル": "미니멀", "スポーティ": "스포티", "スポーティー": "스포티",
    "無地": "무지", "ストライプ": "스트라이프", "チェック": "체크", "ドット": "도트", "グラフィック": "그래픽",
    "ブラック": "블랙", "ホワイト": "화이트", "グレー": "그레이", "ネイビー": "네이비", "ベージュ": "베이지",
    "ブラウン": "브라운", "カーキ": "카키", "アイボリー": "아이보리", "チャコール": "차콜",
    "黒": "블랙", "白": "화이트", "紺": "네이비",
}


def propose(value: str) -> str | None:
    """사전의 일본어 조각을 한국어로 치환. 치환 후에도 일본어가 남으면 None."""
    out = value
    for ja in sorted(PROPOSALS, key=len, reverse=True):
        out = out.replace(ja, PROPOSALS[ja])
    return None if JAPANESE.search(out) else out


def _reject_repo_path(resolved: Path, hint: str) -> None:
    if REPO_ROOT in resolved.parents or resolved == REPO_ROOT:
        sys.exit(f"서비스 계정 키를 이 저장소 안에 두지 마세요 ({hint}) — 저장소 밖 경로를 쓰세요.")


def _load_credentials(cred_path_str: str | None) -> credentials.Certificate:
    hint = "--credentials"
    if not cred_path_str:
        cred_path_str = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        hint = "GOOGLE_APPLICATION_CREDENTIALS"
    if not cred_path_str:
        sys.exit("서비스 계정 키가 없습니다. --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로 지정하세요.")
    resolved = Path(os.path.expanduser(cred_path_str)).resolve()
    if not resolved.is_file():
        sys.exit(f"서비스 계정 키 파일을 찾을 수 없습니다: {resolved}")
    _reject_repo_path(resolved, hint)
    return credentials.Certificate(str(resolved))


def _confirm_project(project_id: str, action: str) -> None:
    answer = input(
        f"\n프로젝트 {project_id}에 {action}합니다.\n"
        f"진행하려면 대상 프로젝트 id를 입력하세요 [{project_id}]: "
    ).strip()
    if answer != project_id:
        sys.exit("입력이 일치하지 않아 중단합니다. 아무것도 쓰지 않았습니다.")


def _now() -> str:
    return datetime.datetime.now().strftime("%Y%m%d_%H%M%S")


def scan(db) -> list[dict]:
    """읽기 전용. 일본어가 든 속성 필드를 찾아 계획 항목으로 만든다."""
    entries = []
    for col in COLLECTIONS:
        for snap in db.collection(col).stream():
            attrs = (snap.to_dict() or {}).get("attributes") or {}
            for field in STRING_FIELDS:
                v = attrs.get(field)
                if isinstance(v, str) and JAPANESE.search(v):
                    entries.append({"collection": col, "id": snap.id, "field": field,
                                    "before": v, "after": propose(v)})
            tags = attrs.get("tags")
            if isinstance(tags, list) and any(isinstance(t, str) and JAPANESE.search(t) for t in tags):
                new_tags = [propose(t) if isinstance(t, str) and JAPANESE.search(t) else t for t in tags]
                entries.append({"collection": col, "id": snap.id, "field": "tags",
                                "before": tags, "after": None if None in new_tags else new_tags})
    return entries


def print_table(entries: list[dict]) -> None:
    print("\n| 컬렉션 | 문서 id | 필드 | 현재 값 | 제안 값 |")
    print("|---|---|---|---|---|")
    for e in entries:
        after = "(제안 없음 — 계획 파일에서 직접 채울 것)" if e["after"] is None else json.dumps(e["after"], ensure_ascii=False)
        print(f"| {e['collection']} | {e['id']} | attributes.{e['field']} | "
              f"{json.dumps(e['before'], ensure_ascii=False)} | {after} |")


def write_fields(db, project_id: str, items: list[tuple[dict, object]], label: str) -> list[dict]:
    """items: (항목, 쓸 값). 문서마다 attributes.<field> 하나만 update한다."""
    done = []
    for e, value in items:
        ref = db.collection(e["collection"]).document(e["id"])
        ref.update({f"attributes.{e['field']}": value})
        done.append(e)
        print(f"  {label} {e['collection']}/{e['id']} attributes.{e['field']}")
    return done


def run_apply(db, project_id: str, plan_path: Path) -> None:
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    entries = plan.get("entries", [])
    if plan.get("project_id") != project_id:
        sys.exit(f"계획 파일의 프로젝트({plan.get('project_id')})가 현재 자격 증명({project_id})과 다릅니다.")
    missing = [e for e in entries if e.get("after") is None]
    if missing:
        sys.exit(f"제안 값이 비어 있는 항목이 {len(missing)}개 있습니다 — 계획 파일에서 채운 뒤 다시 실행하세요.")

    # 적용 직전 재확인: 현재 값이 계획의 before와 같은 항목만 쓴다.
    todo, skipped = [], []
    for e in entries:
        snap = db.collection(e["collection"]).document(e["id"]).get()
        current = ((snap.to_dict() or {}).get("attributes") or {}).get(e["field"]) if snap.exists else None
        (todo if current == e["before"] else skipped).append(e)
    for e in skipped:
        print(f"  건너뜀(현재 값이 계획과 다름) {e['collection']}/{e['id']} attributes.{e['field']}")
    if not todo:
        print("쓸 항목이 없습니다.")
        return
    print_table(todo)
    _confirm_project(project_id, f"위 {len(todo)}개 필드 update")

    MANIFEST_DIR.mkdir(exist_ok=True)
    manifest_path = MANIFEST_DIR / f"fix_{_now()}.json"
    # 쓰기 전에 manifest를 먼저 남긴다 — 도중에 실패해도 되돌릴 근거가 있게.
    manifest_path.write_text(json.dumps({
        "created_at": datetime.datetime.now().isoformat(), "project_id": project_id,
        "plan": str(plan_path), "writes": todo}, ensure_ascii=False, indent=2), encoding="utf-8")
    write_fields(db, project_id, [(e, e["after"]) for e in todo], "update")
    print(f"\n{len(todo)}개 필드 정정 완료. 되돌리려면: python fix.py --credentials ... --rollback {manifest_path}")


def run_rollback(db, project_id: str, manifest_path: Path) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.get("writes", [])
    if manifest.get("project_id") != project_id:
        sys.exit(f"manifest의 프로젝트({manifest.get('project_id')})가 현재 자격 증명({project_id})과 다릅니다.")
    print_table([{**e, "after": e["before"]} for e in entries])
    _confirm_project(project_id, f"manifest {len(entries)}개 필드를 변경 전 값으로 복원")
    write_fields(db, project_id, [(e, e["before"]) for e in entries], "restore")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--credentials", help="서비스 계정 키 경로(저장소 밖)")
    ap.add_argument("--apply", action="store_true", help="--plan의 항목만 실제로 쓴다(기본은 dry-run)")
    ap.add_argument("--plan", help="--apply에 쓸 계획 파일(dry-run이 plans/에 만든 것)")
    ap.add_argument("--rollback", metavar="MANIFEST_PATH", help="manifest의 before 값으로 복원")
    args = ap.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id
    initialize_app(cred)
    db = firestore.client()
    print(f"프로젝트: {project_id}")

    if args.rollback:
        run_rollback(db, project_id, Path(args.rollback))
        return
    if args.apply:
        if not args.plan:
            sys.exit("--apply에는 --plan이 필요합니다(dry-run이 만든 계획 파일).")
        run_apply(db, project_id, Path(args.plan))
        return

    entries = scan(db)
    print(f"\n일본어가 든 속성 필드: {len(entries)}개 ({', '.join(COLLECTIONS)} 전체 검사)")
    if entries:
        print_table(entries)
        PLAN_DIR.mkdir(exist_ok=True)
        plan_path = PLAN_DIR / f"plan_{_now()}.json"
        plan_path.write_text(json.dumps({"created_at": datetime.datetime.now().isoformat(),
                                         "project_id": project_id, "entries": entries},
                                        ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\n계획 파일: {plan_path}")
    print("\ndry-run입니다. 아무것도 쓰지 않았습니다.")


if __name__ == "__main__":
    main()
