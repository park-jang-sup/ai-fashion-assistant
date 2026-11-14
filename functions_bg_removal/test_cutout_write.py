"""cutout_write.py 시험 — python functions_bg_removal/test_cutout_write.py"""
from cutout_write import cutout_metadata, doc_update

assert cutout_metadata("alice") == {"ownerUid": "alice"}
u = doc_update("wardrobe_cutouts/a.png", "https://x/o/a?alt=media&token=", "alice")
assert u == {"cutoutPath": "wardrobe_cutouts/a.png", "cutoutImageUrl": "https://x/o/a?alt=media&token=", "ownerUid": "alice"}
print("PASS: 누끼 메타데이터에 주인, 문서 쓰기에 ownerUid 포함")
