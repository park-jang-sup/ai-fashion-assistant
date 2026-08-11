# -*- coding: utf-8 -*-
"""template + tool_data.json -> 완성된 index.html (Artifact 게시용).
텍스트 조건 쌍 개수는 template의 {{TEXT_COUNT}} 자리에 채운다.
"""
import json
import os

BASE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(BASE, "index_template.html")
TOOL_DATA = os.path.join(BASE, "tool_data.json")
OUT = os.path.join(BASE, "index.html")

with open(TEMPLATE, encoding="utf-8") as f:
    template = f.read()

with open(TOOL_DATA, encoding="utf-8") as f:
    tool_data_raw = f.read()
    tool_data = json.loads(tool_data_raw)

text_count = len(tool_data["textSubsamplePairIds"])
template = template.replace("{{TEXT_COUNT}}", str(text_count))

marker = "// __TOOL_DATA_PLACEHOLDER__"
assert marker in template, "placeholder missing"
template = template.replace(marker, "var TOOL_DATA = " + tool_data_raw + ";")

with open(OUT, "w", encoding="utf-8") as f:
    f.write(template)

size = os.path.getsize(OUT)
print(f"index.html size: {size/1024/1024:.2f} MB")
print(f"text_count: {text_count}")
print(f"pairs: {len(tool_data['pairs'])}")
