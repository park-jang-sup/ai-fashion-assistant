# 작업 지시서 — 신규/결측 아이템 임베딩 본 구현 트랙 (task_embedding_impl_v1)

## 0. 이 트랙의 위치와 승계 원칙

`task_realtime_embedding_v1`(조사·측정, 커밋 `7e83ef4`에서 종결)의
다음 축이다 — 그 트랙이 남긴 결론 위에서 **본 구현을 설계**한다.

**승계 원칙은 옮겨 적지 않는다** — `task_realtime_embedding_v1.md`
§0(그 문서가 다시 `task_selfeval_followup_v1.md` §0 → ... →
`task_hardening_v2.md` §0으로 이어진다)을 그대로 참조한다. 판정
기준 사전 등록, 계측 우선, 미확정 불인정, 재빌드 대조, "무료
진단 먼저", 측정 하네스 우선, 기록 원칙(원문 안 지우고 `[정정]`/
`[보강]` 블록 추가) — 전부 그 링크를 따라간다.

**직전 트랙의 결론(재논의하지 않고 전제로 삼는다, 원문은 옮겨
적지 않고 절 번호만 인용)**:
- 실행 위치 최종 판정 — `task_realtime_embedding_v1.md` §3
  "최종 판정".
- 판정 기준 재정립(지연 시간이 이 기능엔 적용 안 되는 축이라는
  정정) — 같은 문서 §21.
- 웜 이상 원인 규명(부분)과 비용 축 등록 — 같은 문서 §20, §3
  "웜 이상 — 성능 축은 닫히고 비용 축은 열려 있다".
- 스파이크 롤백 완료 — 같은 문서 §22.
- 조사 단계 종합 요약·인계 — 같은 문서 §23.

**남은 셋(Artifact Registry 확인, 다음 달 청구 확인, 웜 이상
비용 축 진단)은 이 트랙을 막지 않는다 — 병행/후속으로 미룬다**
(사용자 결정, 이번 세션). 특히 웜 이상 비용 축은 **본 구현의
계측으로 답한다** — 스파이크 기준 재측정은 하지 않는다(아래
[1단계](d) 참고).

**이번 세션의 범위: 설계와 승인까지다. 구현·배포에 착수하지
않는다.**

## 1. [1단계] 구현 설계

### (a) 확정된 전제 (재논의하지 않는다)

- **Cloud Functions(Python) + Storage 트리거 + `min_instances=0`**
  (`task_realtime_embedding_v1.md` §3 "최종 판정", §21).
- **ONNX 이미지 인코더 + torchvision 직접 호출 전처리**
  (`transformers` 미사용) — 같은 문서 §11(a)/§14(a)가 코드 대조로
  이식한 그대로.
- **512차원 L2 정규화, `wardrobe/{itemId}.embedding` 스키마 유지**
  — `{model, dim, vector, createdAt}`, 같은 문서 §1이 확인한 실제
  저장 형태(`tools/backfill_embeddings/backfill.py:203-215`와 동일).
- **파리티 기준 ≥0.9999997, 검증용 5건 픽스처 재사용** — 같은
  문서 §9/§11/§14가 쓴 것과 같은 아이템 5건, 같은 코사인 유사도
  기준.

### (b) 아키텍처 — 같은 함수 본체, 진입점 둘

**핵심 결정: 계산부(전처리·추론·저장)를 진입점(트리거 vs 배치
호출)과 분리한다.** 이건 새로 정하는 게 아니라 직전 트랙 §5
(사용자 결정, "임베딩 계산부를... 트리거와 분리해서 설계한다")를
이 시점에 실제로 값을 하게 만드는 것이다.

**모듈 구조(설계만 — 파일 생성 안 함)**:

```
functions_embedding/main.py          # 배경 제거(functions_bg_removal)와 같은 급의 새 코드베이스
  _compute_embedding(image_bytes) -> (vector, timings)
      # 스파이크 main.py의 _preprocess + ONNX 세션 추론을 그대로 이식
      # (재구현 아님 — 파일 복사 후 트리거 배선만 추가)
  _write_embedding(doc_ref, vector, model_name, dim)
      # backfill.py:203-215와 동일한 스키마로 wardrobe/{id}.embedding에 merge:true
  _record_metric(item_id, trigger, success, timings, model_hash, error=None)
      # 아래 (d) 참고 — Firestore embedding_metrics 컬렉션에 쓴다
  embedding_on_upload(event)            # Storage 트리거 진입점, 아래 참고
  embedding_backfill_batch(req)         # 관리자 배치 진입점, 아래 참고
```

**진입점 1 — `embedding_on_upload`**(신규 등록):
`@storage_fn.on_object_finalized`, `wardrobe_images/` 프리픽스
필터, 배경 제거(`functions_bg_removal/main.py:123-183`)와 **똑같은
메타데이터 계약**을 재사용한다 — 클라이언트가 이미 업로드
메타데이터에 `wardrobeDocId`/`ownerUid`/`category`를 싣고 있으므로
(`wardrobe_screen.dart:665-674`, §21이 이미 확인) 새 계약을 만들
필요가 없다. `category=="전신"`은 스킵(배경 제거·백필 둘 다와
같은 규칙, `backfill.py:42`의 `SKIP_CATEGORY`와 일치).

**진입점 2 — `embedding_backfill_batch`**(기존 결측분, §3 "결측
46벌 백필"이 범위 밖으로 미뤄뒀던 바로 그 대상 — 이번에 되돌린다):
`@https_fn.on_request`, **IAM invoker 제한**으로 공개 엔드포인트를
막는다 — 새 인증 방식을 설계하지 않는다, 스파이크가 이미 쓴
패턴(`_ADMIN_SA` 초대 SA만 invoker, ID 토큰 발급 후 호출,
`task_realtime_embedding_v1.md` §17(a)/`call_spike.py`)을 그대로
가져온다. 동작: `wardrobe` 컬렉션에서 `category != '전신' and
embedding == null`인 문서를 조회(`backfill.py`의 스킵 로직과 동일한
선택 기준) → 시간 예산(예: 45초, 60초 타임아웃 안에서 여유를 둠)
안에서 처리 가능한 만큼만 `_compute_embedding`으로 처리 → 남은
건수와 함께 JSON 요약 반환. **페이지네이션 커서를 따로 안 둔다** —
이미 처리된 문서는 다음 조회에서 `embedding != null`이라 자연히
제외되므로(`backfill.py`가 이미 쓰는 멱등 원칙과 동일), 관리자가
남은 건수가 0이 될 때까지 같은 호출을 반복하면 된다.

**이미지 소스 — 원본만 쓴다(컷아웃 안 씀), 두 진입점 동일**:
`export_for_kaggle/export.py:171-174`는 "컷아웃 우선, 없으면
원본"이라 기존 94건 벡터 중 일부는 컷아웃에서 나왔을 수 있다.
**이번엔 그 관례를 안 따르고 원본으로 통일한다** — 이유: 배경
제거(`bg_removal_on_upload`)는 **같은 Storage 이벤트를 독립
트리거로 받아 순서 보장이 없다**(그 함수 자신의 문서화,
`functions_bg_removal/main.py:60-69`) — 신규 등록 시점엔 컷아웃이
아직 없을 확률이 높다. 컷아웃 유무에 따라 신규분은 원본, 백필분은
컷아웃으로 갈리면 같은 파이프라인 안에서 두 개의 다른 이미지
소스가 섞여 이 트랙이 공들여 지킨 "파리티"의 다른 축(전처리는
같아도 입력 이미지가 다르면 벡터가 갈린다)이 조용히 깨질 수
있다. **원본 통일이 기존 94건과 완전히 같은 소스라는 보장은
아니다**(그중 일부는 컷아웃 기반일 수 있음, §1의 이미 확정된
사실) — 이건 새로 여는 리스크가 아니라 이미 있던 상태이고, 이번
결정은 최소한 **앞으로 생기는 벡터끼리는(신규·백필 모두) 소스가
갈리지 않게** 한다. **이 판단에 이견이 있으면(예: 컷아웃 우선이
검색 품질에 더 유리하다고 볼 경우) 승인 단계에서 뒤집을 수
있다 — 지금은 설계 기본값으로만 등록한다.**

### (c) 실패 처리·재시도 — 배경 제거 선례 대조

**`functions_bg_removal/main.py:71-75,160-183`를 그대로 읽고
대조했다**:

- 처리 전체를 `try/except`로 감싸고, 실패하면 `print()`로 로그만
  남기고 **재시도 없이 종료**. 예외 종류를 구분하지 않는다
  (`except Exception as e`).
- 근거로 명시된 원칙(§3, 그 문서 인용): "실패해도 옷 등록 자체
  (Firestore 문서)는 이미 끝난 뒤의 일이라 그대로 성공으로 남는다
  — 재시도하지 않는다." 사용자에게 실패를 알리지 않는다.

**그대로 쓰는 것**: try/except로 전체를 감싸는 구조, 재시도 없음,
등록(Firestore wardrobe 문서 생성) 자체는 이 함수의 성패와
완전히 무관하게 이미 끝나 있다는 전제. `task_realtime_embedding_
v1.md` §21이 확인한 대로 임베딩 결손은 사용자에게 안 보이는
실패이므로("비슷한 옷" 시트가 `embedding==null`을 정상 처리) 같은
폴백 철학이 그대로 맞는다 — 배경 제거가 이미 검증한 패턴을
다시 검증할 필요가 없다.

**바꾸는 것 — 실패를 `print()`에만 남기지 않는다**: 배경 제거의
실패 로그는 Cloud Logging에만 남고(§20이 이미 확인했듯 실행 로그
자체를 조회하기가 이 프로젝트 권한으로는 어렵다) 다른 곳에
집계되지 않는다. 이 트랙은 (d)에서 설계하는 `embedding_metrics`
컬렉션에 **성공·실패 둘 다** 기록한다 — 배경 제거와 달리 이번엔
"몇 건이 실패했는지"를 Firestore 조회만으로 알 수 있게 한다(아래
(d)).

**배치 진입점의 "재시도"**: 별도 재시도 로직을 안 만든다 —
실패한 항목은 `embedding`이 여전히 null로 남으므로 다음 배치
호출이 자연히 다시 시도한다(`backfill.py`의 멱등 스킵 원칙과
동일). 관리자가 반복 호출하는 것 자체가 재시도다.

### (d) 계측 설계

**새 Firestore 컬렉션 `embedding_metrics/{autoId}`**(릴리스에서도
남는 방식 — 표준 출력에만 의존하지 않는다):

```
itemId:              string
trigger:              "storage" | "batch"
success:              bool
errorMessage:          string | null
moduleTotalSeconds:    float | null   # 초기화(임포트+세션로드) 소요 — 0에 가까우면 진짜 웜, 크면 재초기화
preprocessSeconds:      float | null
inferenceSeconds:       float | null
totalSeconds:          float
modelName:             "fashionclip"
modelHash:             string          # 아래 (e), 재현성 감사용
createdAt:             서버 타임스탬프
```

**웜 이상의 비용 축은 이 컬렉션으로 답한다(스파이크 재측정 안
함, 사용자 지시)** — `moduleTotalSeconds`가 요청마다 0에 가까운
값만 나오면 초기화가 실제로 인스턴스당 1회로 amortize되고 있다는
뜻이고, 계속 큰 값(7~9초대)이 섞여 나오면 `task_realtime_
embedding_v1.md` §20이 규명 못 한 재초기화가 프로덕션에서도
반복되고 있다는 실측 증거다 — 어느 쪽이든 **이 컬렉션을 며칠
쌓아 조회하면 결론이 난다**, 새 스파이크 호출이 필요 없다.

### (e) 모델 산출물 재현성

- **배포 전 체크(절차, 코드 아님)**: `export_onnx.py`를 다시
  실행해 산출물 해시를 그 스크립트 docstring에 기록된 값
  (`task_realtime_embedding_v1.md` §17(b)가 이미 확립한 절차)과
  대조한다 — 다르면 §17(b)와 같은 5건 파리티 재검증을 거친 뒤
  새 해시를 등록한다.
- **런타임 감사 흔적**: `functions_embedding/main.py`의 `@core.init`
  단계에서 번들링된 `.onnx`/`.onnx.data` 파일의 SHA-256을 계산해
  모듈 상수로 보관하고, (d)의 `embedding_metrics.modelHash`에
  매 기록마다 실어 둔다 — 배포된 아티팩트가 조용히 바뀌어도(잘못된
  빌드 캐시, 실수로 다른 파일 번들링 등) 재배포 없이 Firestore
  조회만으로 사후 감사가 가능하다.

### (f) 착수 전 검증 계획·판정 기준 (사전 등록, 결과 보기 전 고정)

**"됐다"로 볼 최소 조건**:
1. 신규 등록 1건 → `embedding_on_upload`가 자동으로 붙여
   `wardrobe/{id}.embedding`이 채워진다(엔드투엔드, 에뮬레이터
   또는 실기기 확인).
2. 그 벡터가 기존 벡터와 같은 공간에 있다 — **실제 배포 코드
   기준으로** 5건 픽스처 파리티 ≥0.9999997 재확인(스파이크가
   통과한 것과 코드를 옮긴 것은 다르다 — 이식 후 다시 통과해야
   한다).
3. `embedding_backfill_batch`를 결측이 0이 될 때까지 반복 호출한
   뒤, `category != '전신'`인 문서 중 `embedding == null`인 건수가
   0이거나, 0이 아니면 그 사유(예: 이미지 다운로드 실패)가
   `embedding_metrics`에 기록돼 있다.
4. 실패해도 옷 등록(Firestore wardrobe 문서 생성) 자체는 영향받지
   않는다 — **코드 리뷰로 확인**(try/except가 등록 이후 단계에만
   걸려 있는지), 실패를 인위로 유발하는 실험은 이번에도 하지
   않는다.
5. `embedding_metrics`에 성공·실패 건이 실제로 쌓인다 — 계측
   자체가 작동하는지 확인.

### (g) 범위 밖 (이번 트랙에서 다루지 않는다)

- 외부 카탈로그 이미지 URL을 받는 공개 엔드포인트(직전 트랙 §5
  사용자 결정이 이미 미뤄 둔 것, 이번에도 안 엶).
- ONNX 양자화(직전 트랙 §10(d)가 후보로만 등록, 이번에도 후보만).
- 기존 배치 파이프라인(`tools/export_for_kaggle/`,
  `tools/backfill_embeddings/`) 수정 — `embedding_backfill_batch`는
  그 파이프라인을 대체하는 것이지 그 코드 자체를 고치는 게
  아니다.
- Kaggle 노트북이 쓰는 `transformers` API의 향후 버전업 대응
  (직전 트랙 §23(b)가 이미 열린 항목으로 등록).
- `tools/export_for_kaggle/export.py`의 `DEFAULT_BUCKET` 낡음
  (§1에서 이미 지적된 기존 결함, 안 고침).

## 2. 다음

**이 설계는 승인 전까지 코드로 옮기지 않는다.** 사용자 승인을
받은 뒤에만 `functions_embedding/` 실제 구현·`firebase.json` 코드
베이스 추가·배포로 넘어간다.
