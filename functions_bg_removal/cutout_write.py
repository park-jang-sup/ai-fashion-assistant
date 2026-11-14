"""배경 제거 트리거가 쓰는 값(보안 최소 조치 S2-2) — Firebase에 의존하지 않는 순수 함수라 따로 시험한다.

- 누끼 파일의 커스텀 메타데이터: 원본 파일의 ownerUid(storage.rules·getSignedImageUrls가 보는 주인 표시).
- wardrobe 문서에 merge로 쓸 필드: 누끼 경로·주소와 함께 원본 파일의 ownerUid. 트리거가 앱보다 먼저
  문서를 만들면(문서가 아직 없을 때 set(merge)는 새 문서를 만든다) ownerUid 없는 문서가 생기고, 뒤이은
  앱의 set(merge)는 firestore.rules의 update(기존 문서의 ownerUid == 호출자)에 막혀 등록이 실패한다 —
  11/13의 주인 없는 문서가 그 흔적이다. ownerUid를 함께 쓰면 뒤이은 앱의 쓰기가 통과한다.
  owner_uid는 업로드 메타데이터에서 오고, 업로드 규칙이 그 값을 업로더 uid로 강제한다
  (storage.rules wardrobe_images create). 이미 다른 주인의 문서면 트리거가 먼저 건너뛴다(main.py).
"""

OWNER_KEY = "ownerUid"


def cutout_metadata(owner_uid: str) -> dict:
    return {OWNER_KEY: owner_uid}


def doc_update(cutout_path: str, cutout_url: str, owner_uid: str) -> dict:
    return {"cutoutPath": cutout_path, "cutoutImageUrl": cutout_url, OWNER_KEY: owner_uid}
