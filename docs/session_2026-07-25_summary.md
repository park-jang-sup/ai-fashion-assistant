# 작업 정리 (2026-07-25 세션 — CLIP 임베딩 통합 1단계)

브랜치 `feature/clip-embedding-spike`(`main`에서 분기, 아직 병합 안 됨) 위에서
작업. **이번 세션에서 만든 것 전부가 아직 커밋되지 않은 워킹 트리 변경/
untracked 파일 상태다** — 다음 세션 첫 번째 할 일은 이걸 정리해서 커밋하는
것 (자세한 내용은 맨 아래 "다음 세션 시작 시 할 일" 참고).

## 1. 온디바이스 CLIP 임베딩 스파이크

- 목표: 옷 이미지를 512차원 벡터로 바꿔 매칭/RAG를 텍스트 태그에서 임베딩
  유사도 기반으로 전환하는 로드맵 1단계 — 온디바이스로 가능한지 검증.
- 조사 결과: MobileCLIP은 라이선스(Apple ML Research TOU)가 상업적 사용을
  명시적으로 금지. CLIP ViT-B/32/OpenCLIP/FashionCLIP/SigLIP은 전부 TFLite
  변환 시 attention/LayerNorm에 Flex ops(`SELECT_TF_OPS`)가 필요할 가능성이
  높아 일반 `tflite_flutter` 인터프리터로 못 돌릴 위험 — **온디바이스로 CLIP
  품질 임베딩을 깔끔하게 확보하는 경로가 없음을 확인**.
- `tflite_flutter`(v0.12.1) 스택 자체는 release 빌드에서 안정적으로 검증됨
  (SM_S918N 실기기, 콜드스타트 4회 × 20반복 × 3장 = 총 240회 추론 크래시 0,
  평균 98~105ms/추론, 메모리 누수 없음).
- **결론: CLIP 임베딩은 서버/API 방식(Vertex AI multimodal embeddings 또는
  Replicate)으로 간다.** 다만 검증된 `tflite_flutter` 스택 자체는 버리지 않고
  **배경 제거(현재 release에서 onnxruntime 네이티브 JNI 버그로 완전히
  비활성 상태 — `wardrobe_screen.dart`의 `kReleaseMode` 가드)를 교체할
  대안 런타임 후보로 남겨둔다.**
- 코드(전부 스파이크 전용, 앱 통합에는 미사용):
  `lib/spike/embedding_service.dart`, `lib/spike/embedding_spike_app.dart`,
  `lib/spike/synthetic_test_images.dart`, `assets/spike_models/
  efficientnet_lite0_feature_vector.tflite`, `main.dart`의
  `--dart-define=RUN_EMBEDDING_SPIKE=true` 진입 분기.

## 2. Kaggle 임베딩 품질 비교용 데이터 export 도구

- `tools/export_for_kaggle/export.py`: Firebase Admin SDK로 Firestore
  (`wardrobe` 전역 컬렉션 — 전 사용자 공유)와 Storage에 접근해 이미지
  (cutout 우선, 없으면 원본, 긴 변 512px 리사이즈)와 속성 6종
  (color/style/pattern/formality/fit/tags), 추천 이력(`users/*/
  recommendations` — 실제 Firebase uid는 절대 내보내지 않고 `user_001`식
  익명 라벨로 치환)을 `wardrobe_export.zip` 하나로 내보낸다.
- 서비스 계정 키는 `GOOGLE_APPLICATION_CREDENTIALS` 환경변수로만 참조,
  export 폴더 안에 두면 스크립트가 거부. 실행 후 자격증명/PII 흔적 자동
  스캔.
- 실행 중 버그 발견/수정: `doc.data()`(JS SDK API를 착각해서 씀)를
  `doc.to_dict()`(Python `google-cloud-firestore`의 실제 API)로 수정.
  설치된 SDK를 직접 introspect해서 나머지(`.stream()`, `.reference`,
  `download_as_bytes()`, 타임스탬프 `.isoformat()` — Python 클라이언트는
  Timestamp를 `datetime` 서브클래스로 반환)는 원래부터 정상이었음을 확인.
- **실행 완료**: wardrobe 문서 103개 대상 export 성공, `output/`에 실제
  산출물 존재(이미지 다수 + `items.csv`/`items.json` + `history.json`).
- `tools/export_for_kaggle/matcher_spec.md`: `lib/services/
  outfit_matcher.dart`의 스코어링(격식 랭크 + 무채색 보너스)/조합 생성
  로직을 Python으로 재구현 가능한 수준으로 문서화.

## 3. Kaggle 비교 노트북

`tools/export_for_kaggle/kaggle_embedding_comparison.ipynb` — OpenCLIP
ViT-B/32 vs FashionCLIP 2.0 vs EfficientNet-B0 pooled feature(시각 유사도
대조군) 3종 임베딩 추출 → 태그 매칭 재구현(matcher_spec.md 포팅 + 노트북
전용 확장 태그 유사도) → 프로브 테스트(같은 태그·다른 재질 / 다른 태그·
비슷한 무드) → 최근접이웃 그리드 → UMAP/t-SNE 투영 → rejected 사례 정성
분석 → `embeddings.json` 내보내기. 정량 평가(AUC 등)는 의도적으로 제외.
nbformat 검증 + 전 코드셀 문법 검사 통과.

## 4. 실험 결과 → 모델 채택

**FashionCLIP(`patrickjohncyh/fashion-clip`, MIT, 512-dim, L2 정규화)
채택 확정.**

- 근거: 태그 6개가 완전히 동일한 아우터 4벌(트러커 자켓/패딩 후드/아노락/
  코치 자켓)을 태그 매칭은 구별 못 하는데 FashionCLIP은 0.69~0.86으로
  분리했고, 반대로 태그가 다르다고 판정된 검정 와이드 슬랙스들은
  0.89~0.92로 묶어냄 — 두 집단이 겹침 없이 분리(a_max 0.861 < b_min 0.886).
- **중요 원칙**: 절대 코사인 임계값(0.7 등)을 쓰면 안 됨 — 이 옷장은
  무채색 편중이라 임의의 두 벌도 유사도가 높게 나온다. 상대 순위/분포
  기반 기준을 쓸 것.

## 5. Firestore 백필

`tools/backfill_embeddings/backfill.py` — `tools/export_for_kaggle/
embeddings.json`(itemId → 512차원 벡터)을 읽어 `wardrobe` 문서에
`embedding.{model, dim, vector[512], createdAt}` 필드로 저장(map 필드
안의 flat array라 Firestore의 "배열 안에 배열" 금지 제약과 무관).

- 안전장치: 기본 동작이 dry-run(`--apply`로만 실제 반영), `'전신'` 카테고리
  (착장 스냅 사진이라 임베딩 대상 아님, 4건)는 스킵, 이미 `embedding` 있는
  문서는 `--force` 없이 스킵, 저장 전 벡터 검증(길이 512 / 전부 유한값 /
  L2 norm 0.99~1.01).
- 실행 중 버그 수정 2건:
  1. `doc.data()` → `doc.to_dict()` (export.py와 동일한 원인).
  2. `embedding` map 전체를 `update()`로 통째로 set하면서 그 안에
     `firestore.SERVER_TIMESTAMP`(서버 트랜스폼)를 같이 넣으면 필드 경로
     충돌로 Firestore가 쓰기를 거부 — dry-run에서는 안 잡히고 `--apply`
     에서만 터지는 문제였음. 백필 기록용이라 서버 시각일 필요가 없어
     클라이언트 `datetime.now(timezone.utc)`로 교체해 해결.
- **실행 완료: wardrobe 99건에 `embedding` 필드 백필 성공**(103개 중
  `'전신'` 4건 제외 = 99건, 숫자 일치 확인됨).

## 지켜야 할 작업 원칙 (재확인 + 이번 세션에서 새로 확인된 것)

- (기존) Firebase 규칙 배포 등 공유 인프라 변경은 실행 전 사용자 승인
  필요. 사용자가 직접 트리거한 액션의 에러는 조용히 삼키지 않고 노출.
  코드 변경 후 항상 `flutter analyze`.
- **Firebase Admin Python SDK ≠ JS SDK API.** `DocumentSnapshot.data()`는
  없고 `to_dict()`를 쓴다. `firestore.SERVER_TIMESTAMP`를 중첩 map 필드를
  통째로 `update()`하는 호출 안에 섞으면 필드 경로 충돌 — 이런 스크립트는
  dry-run으로 먼저 검증해도 이 종류의 버그는 `--apply`에서만 드러날 수
  있다는 것 자체를 유의.
- 서비스 계정 키는 절대 저장소 안에 두지 않고 환경변수로만 참조 —
  `export.py`/`backfill.py` 둘 다 저장소 내부 경로면 실행 자체를 거부하게
  구현되어 있음. 이 패턴을 앞으로 만들 스크립트에도 유지할 것.
- 이 프로젝트의 Windows 환경 콘솔이 cp949라 em-dash 등 특수문자 출력 시
  `UnicodeEncodeError`가 날 수 있음 — 새 Python 스크립트에는 stdout UTF-8
  reconfigure 방어코드를 넣는 습관을 들일 것.

## 다음 세션 시작 시 할 일

1. **커밋 정리** — 지금 전부 워킹 트리 변경/untracked 상태
   (`.gitignore`, `lib/main.dart`, `pubspec.yaml`/`pubspec.lock`,
   `lib/spike/`, `assets/spike_models/`, `tools/export_for_kaggle/`,
   `tools/backfill_embeddings/`). `feature/clip-embedding-spike`라는
   브랜치 이름이 이제 "임베딩 통합 전체"를 담고 있어 더 안 맞을 수 있음 —
   커밋을 스파이크/도구/앱 통합 단위로 쪼갤지, 브랜치를 새로 팔지 검토.
2. **`lib/spike/` 처리 결정** — 스파이크는 끝났고 CLIP은 서버사이드로
   갈 것이므로, 이 디렉토리 전체(+ `pubspec.yaml`의 `tflite_flutter`
   의존성, `assets/spike_models/`, `main.dart`의 진입 분기)를 지울지,
   아니면 배경 제거 ONNX 대체용으로 남겨서 다음 스파이크의 출발점으로
   쓸지 결정 필요.
3. **CLIP 임베딩 실제 앱 통합** — 백필은 끝났지만 앱 코드는 아직 하나도
   안 건드림. 다음 단계는 (a) `OutfitMatcher` 또는 신규 서비스가 Firestore
   의 `embedding` 필드를 읽어 코사인 유사도 기반 매칭을 실제로 쓰도록
   연결하는 것, (b) 신규 옷 등록 시 임베딩을 생성하는 경로(서버사이드 —
   Vertex AI multimodal embeddings vs Replicate 중 택일 필요, 아직
   미정) 구현.
4. `tools/export_for_kaggle/output/`, `wardrobe_export.zip`,
   `embeddings.json`은 `.gitignore`에 이미 등록되어 커밋될 걱정은 없지만,
   로컬에 실제 옷장 이미지 원본이 남아있으니 취급에 유의.

## 참고 파일 위치

- 스파이크: `lib/spike/`, `assets/spike_models/`
- Kaggle export / 노트북 / 매칭 알고리즘 명세: `tools/export_for_kaggle/`
- Firestore 백필: `tools/backfill_embeddings/`
