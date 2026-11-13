"""텍스트 모델 프로브 입력 ① — 아이템 속성 받기(읽기 전용).

docs/task_text_model_v1.md §3-1. 자기평가 라벨링 자료(tools/eval_harness_selfeval)
의 아이템 55개와 가상 피팅 프로브의 set4_7벌 아이템 7개를 Firestore `wardrobe`
에서 읽어 `input/items.json`으로 쓴다. Firestore·Storage에는 아무것도 쓰지
않는다.

T1(자기평가)은 8월 쌍 생성 때와 같은 아이템 순서로 프롬프트를 만들어야 하므로,
정답지(pairs_answer_key.json)의 itemSummaries 줄 순서대로 각 조합의 itemId를
정렬해 `t1Combos`에 남긴다. 현재 속성으로 만든 요약 줄이 8월 줄과 다르면
(예: 2026-11-13에 정정한 "레ギュラー") 그 차이를 함께 기록한다.

    python fetch_items.py --credentials ~/secrets/personal-adminsdk.json

서비스 계정 키는 저장소 밖 경로로만 받는다(다른 tools/ 도구와 같은 규칙).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

from firebase_admin import credentials, firestore, initialize_app

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
ANSWER_KEY = REPO_ROOT / "tools/eval_harness_selfeval/answer_key/pairs_answer_key.json"
OUT = SCRIPT_DIR / "input/items.json"
# 옷장 전체를 읽을 사용자(가상 피팅 프로브 0단계 로그의 uid). T5(docs/task_agent_grounding_v1.md
# §3-4)가 앱과 같은 로직으로 옷장 후보를 뽑는 데 쓴다.
OWNER_UID = "BDDOIl08EhXnHu6oz6Zro47EtMw1"

# tools/fitting_probe/fetch_inputs.py의 SET4_7과 같은 값(T4 스트리밍 분석용).
FITTING_SET = {
    "top": "6vVNoavk5DLduhTNKu0d",
    "bottom": "ocHh3cdrQwcb5YW03HIT",
    "outer": "vRnIn4pj9Nn1CBsxyrYA",
    "shoes": "Z0HlgPZ6ypYyAnIim9Jw",
    "hat": "cb7yrcouGGpbsZCYGS1F",
    "bag": "cnwqpOYioHPlFxgju1JO",
    "watch": "WiyzsFM2QqSCYa3d8Uzp",
}


def load_credentials(path_str: str | None) -> credentials.Certificate:
    path_str = path_str or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path_str:
        sys.exit("서비스 계정 키가 없습니다. --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로 지정하세요.")
    resolved = Path(os.path.expanduser(path_str)).resolve()
    if not resolved.is_file():
        sys.exit(f"서비스 계정 키 파일을 찾을 수 없습니다: {resolved}")
    if REPO_ROOT in resolved.parents:
        sys.exit("서비스 계정 키를 이 저장소 안에 두지 마세요 — 저장소 밖 경로를 쓰세요.")
    return credentials.Certificate(str(resolved))


def prompt_line(attrs: dict) -> str:
    # lib/models/clothing_attributes.dart toPromptLine()과 같은 형식.
    tags = attrs.get("tags") or []
    tags_text = f", 태그: {', '.join(tags)}" if tags else ""
    return (f"색상 {attrs.get('color')}, 스타일 {attrs.get('style')}, 패턴 {attrs.get('pattern')}, "
            f"격식 {attrs.get('formality')}, 핏 {attrs.get('fit')}{tags_text}")


def order_combo(item_ids: list[str], august_lines: list[str], items: dict) -> tuple[list[str], list[dict]]:
    """8월 요약 줄 순서대로 itemId를 정렬. 줄마다 같은 카테고리 후보 중 요약이
    정확히 같은 것을 먼저 고르고, 없으면 같은 카테고리의 첫 후보를 고른다."""
    remaining = list(item_ids)
    ordered, diffs = [], []
    for line in august_lines:
        cat = line.split(":", 1)[0].strip()
        same_cat = [i for i in remaining if items[i]["category"] == cat]
        exact = [i for i in same_cat if f"{cat}: {prompt_line(items[i]['attributes'])}" == line]
        pick = (exact or same_cat or remaining)[0]
        remaining.remove(pick)
        ordered.append(pick)
        current = f"{items[pick]['category']}: {prompt_line(items[pick]['attributes'])}"
        if current != line:
            diffs.append({"itemId": pick, "august": line, "current": current})
    return ordered + remaining, diffs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--credentials")
    args = ap.parse_args()

    key = json.loads(ANSWER_KEY.read_text(encoding="utf-8"))
    eval_ids = sorted({i for p in key["pairs"] for side in ("left", "right") for i in p[side]["itemIds"]})
    all_ids = sorted(set(eval_ids) | set(FITTING_SET.values()))

    initialize_app(load_credentials(args.credentials))
    db = firestore.client()
    # 이전에 받은 값 — 그 사이 문서가 삭제된 아이템은 이 값을 그대로 쓴다(T1 입력이
    # 이미 고정돼 있어 바뀌면 안 된다). 삭제 사실은 출력으로 남긴다.
    previous = json.loads(OUT.read_text(encoding="utf-8")).get("items", {}) if OUT.exists() else {}
    items = {}
    missing_now = []
    for doc_id in all_ids:
        snap = db.collection("wardrobe").document(doc_id).get()
        if not snap.exists:
            if doc_id in previous:
                items[doc_id] = previous[doc_id]
                missing_now.append(doc_id)
                continue
            sys.exit(f"wardrobe/{doc_id} 문서가 없습니다(이전 값도 없음).")
        d = snap.to_dict()
        if not d.get("attributes"):
            sys.exit(f"wardrobe/{doc_id}에 attributes가 없습니다.")
        a = d["attributes"]
        items[doc_id] = {
            "category": d.get("category"),
            "subCategory": d.get("subCategory"),
            "attributes": {k: a.get(k) for k in ("color", "style", "pattern", "formality", "fit", "tags")},
        }

    # 옷장 전체(속성 있는 옷) — 앱의 FirestoreService.wardrobeStream과 같은 소유자 조건.
    wardrobe = []
    for snap in db.collection("wardrobe").where("ownerUid", "==", OWNER_UID).stream():
        d = snap.to_dict()
        a = d.get("attributes")
        if not a:
            continue
        wardrobe.append({
            "id": snap.id,
            "category": d.get("category"),
            "subCategory": d.get("subCategory"),
            "attributes": {k: a.get(k) for k in ("color", "style", "pattern", "formality", "fit", "tags")},
        })
    wardrobe.sort(key=lambda w: w["id"])

    t1, total_diffs = [], 0
    for p in key["pairs"]:
        for side in ("left", "right"):
            ordered, diffs = order_combo(p[side]["itemIds"], p[side]["itemSummaries"], items)
            total_diffs += len(diffs)
            t1.append({"pairId": p["pairId"], "side": side, "itemIds": ordered,
                       "augustScore": p[side]["score"], "summaryDiffs": diffs})

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps({
        "evalItemIds": eval_ids,
        "fittingSet": FITTING_SET,
        "items": items,
        "t1Combos": t1,
        "wardrobe": wardrobe,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"옷장 전체(속성 있는 옷) {len(wardrobe)}벌")
    if missing_now:
        print(f"Firestore에서 지금은 없는 아이템 {len(missing_now)}개 — 이전 items.json 값 사용: {', '.join(missing_now)}")
    print(f"아이템 {len(items)}개(자기평가 {len(eval_ids)} + 피팅 세트), T1 조합 {len(t1)}개 → {OUT}")
    print(f"8월 요약 줄과 현재 속성이 다른 줄: {total_diffs}개")
    for c in t1:
        for d in c["summaryDiffs"]:
            print(f"  {c['pairId']}/{c['side']} {d['itemId']}\n    8월: {d['august']}\n    현재: {d['current']}")


if __name__ == "__main__":
    main()
