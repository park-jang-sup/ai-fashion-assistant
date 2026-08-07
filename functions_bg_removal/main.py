"""배경 제거 재개 — 업로드 트리거
(docs/task_background_removal_v1.md §1-1~1-3, D-1 단계).

`wardrobe_images/` 업로드를 감지해 배경을 제거하고
`wardrobe_cutouts/`에 저장한 뒤, 그 wardrobe 문서의
`cutoutPath`/`cutoutImageUrl`을 갱신한다.

**스코프 제한(§1-1)**: `wardrobe_images/`로만 제한한다.
Eventarc 필터(`bucket`)만으로는 프리픽스를 못 거르므로 함수 진입부에서
명시적으로 검사한다 — 안 그러면 이 함수가 `wardrobe_cutouts/`에 쓴
결과가 자기 자신을 다시 발화시켜 무한 루프가 된다
(`functions/src/index.ts`의 `isTokenRevocablePath()`와 같은 패턴).

**Firestore 문서 연결(§1-3, 메타데이터 전달)**: 폴링도 업로드 순서
반전도 아니다 — 클라이언트가 업로드 *전에* 미리 뽑은 문서 ID를
Storage 커스텀 메타데이터(`wardrobeDocId`/`ownerUid`/`category`)에
실어 보내고, 이 함수는 조회 없이 그 문서를 바로 대상으로 삼는다.
**메타데이터(셋 중 하나라도)가 없는 업로드는 처리 대상에서 제외하고
로그만 남긴다** — 경로 기반으로 문서를 추측하지 않는다(레거시 업로드,
다른 클라이언트 대비). `ownerUid`는 방어용 — 대상 문서가 이미
존재하면 그 문서의 `ownerUid`와 메타데이터의 `ownerUid`가 일치하는지
대조해, 다른 사용자의 문서에 컷아웃이 주입되는 걸 막는다
(`storage.rules`가 `wardrobe_images/`에 소유자 검사 없이
`allow write: if request.auth != null`만 요구하므로 이 대조가 없으면
임의의 인증된 클라이언트가 `wardrobeDocId`를 조작해 주입할 수 있다).

**'전신' 카테고리 제외(결함 1 수정, 2026-08-07)**: 전신 사진은 가상
피팅의 기준 이미지이고(`wardrobe_screen.dart`도 같은 이유로
`category != '전신'`일 때만 클라이언트 배경 제거를 시도한다), u2netp도
인물 매팅용 모델이 아니다. 이 함수는 Firestore를 조회하지 않는
설계라(위 문단) 문서에서 카테고리를 읽어 판정할 수 없으므로, 클라이언트가
업로드 메타데이터에 실어 보낸 `category`를 그대로 신뢰해 '전신'이면
컷아웃을 만들지 않고 즉시 반환한다.

**`revokeTokenOnUpload`(functions/src/index.ts, Node)와의 상호작용
(§1-2, 무간섭 확인됨)**: 같은 `google.cloud.storage.object.v1.finalized`
이벤트를 두 함수가 각자 독립된 Eventarc 트리거로 받는다 — 순서
보장 없음. 이 함수는 Admin SDK로 원본을 읽기만 하므로(IAM 기반,
다운로드 토큰 유무와 무관) `revokeTokenOnUpload`가 토큰을 먼저
지우든 나중에 지우든 영향이 없다. 이 함수가 `wardrobe_cutouts/`에
쓰는 새 파일은 그 자체가 새 `finalized` 이벤트를 만들어
`revokeTokenOnUpload`가 독립적으로 처리한다(기존 클라이언트 업로드
컷아웃도 똑같이 이 경로를 탔다 — 새로 생긴 위험 없음). 공유하는
가변 자원이 없어 락·순서 조율이 필요 없다.

**폴백(§3 원칙)**: 실패해도(모델 추론 오류, 다운로드 실패 등) 옷
등록 자체(Firestore 문서)는 이미 끝난 뒤의 일이라 그대로 성공으로
남는다 — 재시도하지 않는다. 컷아웃 없이 원본만 있는 상태가 정상
종료다(사용자에게 실패를 알리지 않음, 현행 릴리스 비활성 상태와
동일한 사용자 경험).

**출력 캔버스(§3-1)**: 알파 bbox 크롭 적용 — 기존 111건의 타이트
크롭 관행을 따른다(모델 선택과 무관하게 확정된 결정).

모델: minimal_runtime.py(§2-5/§2-6에서 34건 무손실 검증 + 클라우드
콜드스타트 1.3~2.1초 실측 완료) — rembg가 아니라 onnxruntime을
직접 호출한다.
"""
import os
import time
from urllib.parse import quote

from firebase_admin import firestore, initialize_app, storage
from firebase_functions import options, storage_fn

from minimal_runtime import MinimalSession

initialize_app()

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_MODEL_PATH = os.path.join(BASE_DIR, "u2netp.onnx")

TARGET_PREFIX = "wardrobe_images/"
CUTOUT_PREFIX = "wardrobe_cutouts/"
WARDROBE_COLLECTION = "wardrobe"

# 콜드스타트 시(컨테이너 인스턴스 시작 시) 모듈 스코프에서 딱 한 번
# 로드된다 — §2-6에서 실측한 콜드스타트(1.3~2.1초)가 이 로드까지
# 포함한 값이다. 요청마다 다시 로드하지 않는다.
_session = MinimalSession(_MODEL_PATH)


def _cutout_path_for(original_path: str) -> str:
    stem = os.path.splitext(os.path.basename(original_path))[0]
    return f"{CUTOUT_PREFIX}{stem}.png"


def _legacy_download_url(bucket_name: str, path: str, token: str) -> str:
    # 서명 URL 이행 신규 컷아웃 확인 항목(docs/task_signed_urls_v1.md §4)의
    # 그 URL 형식과 동일 — [C-4b] 표기와 같은 의미로, 업로드 직후
    # revokeTokenOnUpload가 이 토큰을 지우기 전까지만 유효한 잔여물이다.
    return (
        f"https://firebasestorage.googleapis.com/v0/b/{bucket_name}/o/"
        f"{quote(path, safe='')}?alt=media&token={token}"
    )


@storage_fn.on_object_finalized(
    region="asia-northeast3",
    memory=options.MemoryOption.GB_1,
    timeout_sec=60,
    min_instances=0,
)
def bg_removal_on_upload(event: storage_fn.CloudEvent) -> None:
    t_start = time.perf_counter()
    path = event.data.name
    if not path.startswith(TARGET_PREFIX):
        return

    metadata = event.data.metadata or {}
    wardrobe_doc_id = metadata.get("wardrobeDocId")
    owner_uid = metadata.get("ownerUid")
    category = metadata.get("category")
    if not wardrobe_doc_id or not owner_uid or not category:
        print(f"[bg_removal_on_upload] 메타데이터 없음, 처리 대상 제외 path={path}")
        return
    if category == "전신":
        print(f"[bg_removal_on_upload] 전신 카테고리, 처리 대상 제외 path={path}")
        return

    db = firestore.client()
    bucket = storage.bucket(event.data.bucket)
    doc_ref = db.collection(WARDROBE_COLLECTION).document(wardrobe_doc_id)

    doc_snap = doc_ref.get()
    if doc_snap.exists:
        existing_owner = (doc_snap.to_dict() or {}).get("ownerUid")
        if existing_owner is not None and existing_owner != owner_uid:
            print(
                "[bg_removal_on_upload] 소유자 불일치, 건너뜀 "
                f"path={path} doc={wardrobe_doc_id}"
            )
            return

    try:
        original_bytes = bucket.blob(path).download_as_bytes()
        result_png = _session.remove(original_bytes, crop=True)

        cutout_path = _cutout_path_for(path)
        cutout_blob = bucket.blob(cutout_path)
        cutout_blob.upload_from_string(result_png, content_type="image/png")
        cutout_blob.reload()
        token = (cutout_blob.metadata or {}).get("firebaseStorageDownloadTokens", "")
        cutout_url = _legacy_download_url(bucket.name, cutout_path, token)

        doc_ref.set(
            {"cutoutPath": cutout_path, "cutoutImageUrl": cutout_url},
            merge=True,
        )
        elapsed = time.perf_counter() - t_start
        print(
            f"[bg_removal_on_upload] 완료 path={path} -> {cutout_path} "
            f"doc={wardrobe_doc_id} elapsed={elapsed:.3f}s"
        )
    except Exception as e:  # noqa: BLE001 — §3 폴백 원칙: 실패해도 원본만 있는
        # 상태로 정상 종료, 등록 자체를 실패로 만들지 않는다. 재시도 없음.
        print(f"[bg_removal_on_upload] 실패 path={path} doc={wardrobe_doc_id}: {e}")
