# -*- coding: utf-8 -*-
"""라벨링 도구(index.html)에 인라인으로 심을 데이터를 만든다.
answer_key에서 점수·축·kind·모델을 전부 제거하고 itemIds/itemSummaries/
이미지(base64)만 남긴다 - 블라인드 원칙.
"""
import base64
import json
import os

BASE = os.path.dirname(os.path.abspath(__file__))
ANSWER_KEY = os.path.join(BASE, "..", "..", "answer_key", "pairs_answer_key.json")
IMAGES_DIR = os.path.join(BASE, "..", "images")
OUT = os.path.join(BASE, "tool_data.json")

with open(ANSWER_KEY, encoding="utf-8") as f:
    answer = json.load(f)

# itemId -> base64 data URI (전부 .jpg로 통일됨, compress_images.py)
b64_cache = {}


def data_uri(item_id):
    if item_id in b64_cache:
        return b64_cache[item_id]
    path = os.path.join(IMAGES_DIR, f"{item_id}.jpg")
    with open(path, "rb") as f:
        b = f.read()
    uri = "data:image/jpeg;base64," + base64.b64encode(b).decode("ascii")
    b64_cache[item_id] = uri
    return uri


def side_payload(side):
    return {
        "images": [data_uri(iid) for iid in side["itemIds"]],
        "text": "\n".join(side["itemSummaries"]),
    }


pairs_out = []
for p in answer["pairs"]:
    pairs_out.append({
        "pairId": p["pairId"],
        "left": side_payload(p["left"]),
        "right": side_payload(p["right"]),
    })

tool_data = {
    "pairs": pairs_out,
    "textSubsamplePairIds": answer["textSubsamplePairIds"],
}

with open(OUT, "w", encoding="utf-8") as f:
    json.dump(tool_data, f, ensure_ascii=False)

size = os.path.getsize(OUT)
print(f"tool_data.json 크기: {size/1024/1024:.2f} MB")
