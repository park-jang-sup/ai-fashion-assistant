# TFLite 배경제거 교체 스파이크용 메모 (온디바이스 임베딩 스파이크 이력 보존)

`lib/spike/`(온디바이스 CLIP 임베딩 검증, 2026-07-24)는 CLIP 임베딩을
서버사이드 방식(Vertex AI multimodal embeddings / Replicate)으로 채택하면서
역할이 끝나 코드는 삭제했다. 다만 그 과정에서 확인된 사실 중 하나 —
`tflite_flutter`가 이 앱의 release 빌드에서 안정적으로 동작한다는 것 —
는 별개로 재사용 가치가 있어 이 문서에 남긴다.

## 배경 — 왜 이게 필요한가

현재 옷 등록 시 배경 제거는 `image_background_remover`(ONNX runtime 기반)를
쓰는데, **release 빌드에서만 재현되는 네이티브 크래시** 때문에
`kReleaseMode`일 때 아예 초기화를 건너뛰고 원본 이미지만 쓰도록 막아둔
상태다(`lib/screens/wardrobe_screen.dart:160-180`).

- 2026-07-19 실기기(Galaxy S23 Ultra, SM_S918N) release APK에서 재현,
  logcat 확인: `JNI DETECTED ERROR IN APPLICATION: java_class == null in
  call to GetMethodID` — `Java_ai_onnxruntime_OrtSession_run` →
  `convertOrtValueToONNXValue` → `convertToTensorInfo` → `GetMethodID`(널
  클래스) → `SIGABRT`.
- JNI 변환 코드가 이전 JNI 호출 실패(pending exception)를 확인하지 않고
  다음 JNI API를 호출하다 죽는 구조로, `microsoft/onnxruntime#12679`에
  보고된 패턴과 일치. R8/ProGuard, NNAPI, 입력 텐서 shape, 동시 호출 경합은
  전부 원인에서 배제됨 — `onnxruntime-android`(1.23.0) 네이티브 JNI 유틸
  내부 버그로 확정, 앱 쪽 코드/설정으로는 고칠 수 없음.
- 즉 지금 프로덕션에서 배경 제거는 **release에서 완전히 죽어있는 기능**이고,
  대체 런타임이 필요한 상태다.

## 임베딩 스파이크에서 확인된 사실(재사용 가치 있음)

- `tflite_flutter`(v0.12.1) 인터프리터 로드+추론이 **release 빌드에서
  안정적**임을 실기기(SM_S918N, Android 16 API 36)로 검증: 콜드스타트
  4회 × 20반복 × 3장 = 총 240회 추론, 크래시 0건, 평균 98~105ms/추론,
  메모리 누수 없음.
- asset 번들링 모델 로딩 패턴: adb push 방식(external files dir)이 이
  기기의 scoped storage에서 `File.existsSync()`가 `false`를 반환하는
  문제를 만나, **asset 번들링 + `rootBundle.load()` +
  `Interpreter.fromBuffer()`**로 전환해 우회함(파일시스템 경로 자체를
  안 씀). 이 패턴은 모델 종류와 무관하게 그대로 재사용 가능.
- 검증에 쓴 모델은 EfficientNet-Lite0 headless feature-vector(ImageNet
  사전학습) — 출력이 `[1, outputDim]` 1차원 벡터인 임베딩 전용 모델이었다.

## 다음 스파이크가 새로 짜야 하는 것 (재사용 불가 부분)

`lib/spike/embedding_service.dart`의 `embed()`는 출력 텐서를
`[1, outputDim]` 벡터로 하드코딩해서 읽었다(`List.filled(_outputDim,
0.0)`). 배경제거(세그멘테이션/매팅) 모델은 전형적으로 `[1, H, W, C]`
형태의 마스크를 출력하므로:

- 출력 텐서 shape을 세그멘테이션 모델에 맞게 새로 다뤄야 함(2D/3D 텐서,
  모델별로 dynamic shape 가능성도 확인 필요).
- 후처리가 완전히 다름 — L2 정규화가 아니라 마스크 임계값 처리, 원본
  해상도로 업샘플링, 알파 채널 합성이 필요.
- 삼각 유사도 테스트(`synthetic_test_images.dart`) 같은 검증 방식도
  세그멘테이션에는 안 맞음 — 전경/배경이 명확히 구분된 합성 이미지로
  마스크 경계가 대략 맞는지 보는 방식으로 새로 설계해야 함.
- 후보 모델 자체(예: MODNet, U^2-Net, RMBG 계열 등 TFLite로 변환 가능한
  경량 매팅 모델)도 이번 임베딩 스파이크에서는 조사 안 됨 — 처음부터
  다시 조사 필요.

## 결론

`tflite_flutter` 의존성은 `pubspec.yaml`에 그대로 남겨뒀다(제거하면
배경제거 스파이크 때 release 안정성 검증을 처음부터 다시 해야 함). 다음
스파이크는 "이 런타임이 이 기기에서 안 죽는다"는 전제를 깔고, 세그멘테이션
모델의 입출력 처리부터 새로 시작하면 된다.

## [정정 — 2026-08-06] "onnxruntime#12679와 일치" 근거가 부정확했다

배경 제거 재개 작업(`docs/task_background_removal_v1.md`) 1단계
조사에서, 위 "확정" 근거로 인용한 `microsoft/onnxruntime#12679`를
코멘트까지 전부 재확인했다. 결과:

- **#12679는 우리 버그가 아니다.** 마감 사유는 "completed"지만 실제
  원인은 JNI와 무관한 **tree-ensemble 모델의 feature_id 인덱스
  초과**(학습 시 피처 수보다 큰 인덱스로 네이티브 배열을 읽어
  SIGSEGV) — 신고자가 학습/추론 데이터의 피처 수가 다른 모델을 쓴
  것이 원인이었다(`xadupre`가 직접 재현·확인). "JNI DETECTED
  ERROR... GetMethodID" 로그 형태가 우리와 비슷해 스파이크 당시
  같은 버그로 오인한 것으로 보인다.
- **진짜 관련 있는 건 `#11451` + PR `#12516`**("JNI refactor for
  OrtJniUtil", pending-exception 미체크가 실제 원인)이고, 이건
  **2022-09-09에 이미 머지**돼 onnxruntime **1.13.0부터** 포함돼
  있다. 우리는 그로부터 한참 뒤인 **1.23.0**에서 크래시를
  재현했다 — 이미 3년 전에 고쳐진 버그가 재발한 게 아니라, **정체가
  불명확한 별개의 크래시**라는 뜻이다.
- 1.23.0 이후 릴리스(1.23.1~1.28.0, Maven Central 기준 최신)의
  GitHub 릴리스 노트를 전수 확인 — JNI/Android 크래시 관련 수정
  항목 없음(유일한 Android 항목은 1.25.0의 16KB 페이지 정렬,
  무관). `flutter_onnxruntime`(image_background_remover 2.0.0의
  기반)도 최신 1.8.3까지 `onnxruntime-android:1.23.0`에 그대로
  고정 — 패키지를 올려도 우리가 이미 크래시 재현한 네이티브 버전
  그대로다.
- 참고로 발견한 별개 사례: `#17847`(2023, 우리와 동일한 에러
  메시지)의 실제 원인은 **R8/ProGuard가 ONNX 심볼을 스트립**한
  것이었다. 우리는 `minifyEnabled`가 꺼져있어 이 원인은 이미
  배제됨(원래 스파이크 노트에도 명시). 같은 에러 메시지가 서로 다른
  원인에서도 나올 수 있다는 걸 보여주는 사례일 뿐, 우리 원인의
  답은 아니다.

**결론: "onnxruntime JNI 내부 버그로 확정"은 유지하되(우리 코드/
설정으로 고칠 수 없다는 실무적 결론 자체는 여전히 유효 — R8/NNAPI/
텐서 shape/동시성 배제는 그대로 맞다), "#12679와 일치"라는 근거
문장과 "업스트림이 언젠가 고칠 것"이라는 기대는 틀렸다.** 업스트림
어디에도 우리 버그에 대응하는 확인된 수정이 없고, 패치를 기다리는
전략 자체가 성립하지 않는다 — 대체 런타임(TFLite) 또는 서버 이관
쪽으로 가야 한다는 이 문서 원래의 결론은 오히려 이번 조사로 더
강하게 뒷받침됐다.

논문 5.7절이 같은(부정확한) 근거를 인용하고 있어 rev8 논문 세션에서
정정이 필요하다 — 지금은 메모만 남기고 문서 반영은 하지 않는다.

## 참고

- 배경 제거 ONNX 크래시 상세: `lib/screens/wardrobe_screen.dart:160-180`
- CLIP 임베딩 채택 경위 전체: `docs/archive/session_2026-07-25_summary.md`
- 재개 작업 지시서: `docs/task_background_removal_v1.md`
