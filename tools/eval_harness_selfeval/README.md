# 자기 평가 척도 검증용 라벨링 자료 (3단계 — 사람 라벨 쌍대비교)

`docs/task_selfeval_validity_v1.md` §6-나·§7의 사전 등록 설계와 실행
기록을 참고할 것 — 이 디렉터리는 그 산출물만 담는다.

## 구조

- `labeling_material/` — **라벨러에게 보여줄 자료.** `pairs_blind.json`
  (쌍 15개, 좌/우 이미지 목록 — 점수·`itemIds` 없음)과 `images/`
  (아이템 이미지 55장). 이 폴더만 압축해 라벨러에게 전달한다.
- `answer_key/` — **라벨러에게 보이면 안 되는 정답지.**
  `pairs_answer_key.json`에 쌍별 좌/우 조합의 총점·축 3종·`itemIds`·
  층(stratum)·주의 확인 문항 여부·텍스트 부분 표본 지정이 들어
  있다. 라벨 수집 완료 후 채점에만 쓴다.

## 재현 정보

15쌍은 `docs/task_selfeval_validity_v1.md` §7이 등록한 절차로 만들
었다 — `integration_test/self_eval_pair_generation_probe.dart`
(커밋 `96ad3a0`)로 조합 40개를 생성·채점한 뒤, 3분위 층화 +
사전 등록 제약(점수차≥5·아이템 겹침≤2·조합 재사용 금지)으로 쌍을
구성했다. 시드·층화 계획·경계값은 `answer_key/pairs_answer_key.json`에
전부 남아 있다.

## 이미지 출처

`imagePath`/`cutoutPath`(Firestore `wardrobe` 문서 필드)를 Admin SDK로
직접 읽어 로컬로 내려받았다 — 서명 주소(만료 60분, 3.12.3절)를 생성
하지 않았다. 라벨링 패키지에 만료되는 링크를 심지 않기 위해서다.

## 라벨링 도구 (3단계 실행 2)

`labeling_material/tool/`에 라벨러에게 배포하는 자체완결 HTML 도구가
있다.

- `index_template.html` — 실제 소스(마크업·스타일·로직). 데이터는
  `// __TOOL_DATA_PLACEHOLDER__` 자리에 빌드 시점에 주입된다.
- `build_tool_data.py` — `answer_key/pairs_answer_key.json` +
  `labeling_material/images/*`에서 점수·축·모델·kind 등 채점 관련
  필드를 전부 제거하고 `pairId`/이미지(base64 JPEG data URI)/
  `itemSummaries` 텍스트만 남긴 `tool_data.json`을 만든다(이 파일
  자체가 블라인드 원칙을 구조로 강제한다 — 라벨러 화면 쪽 코드가
  점수를 몰라서가 아니라 애초에 갖고 있지 않다).
- `merge_tool.py` — 템플릿에 `tool_data.json`을 그대로 심어
  `index.html`(약 3.8MB, 배포용 완성본)을 만든다.
- `index.html` — 최종 산출물. Claude Artifact로 게시해 카카오톡으로
  링크만 보내면 각 라벨러가 브라우저에서 바로 연다(이미지가 파일
  안에 base64로 들어 있어 별도 폴더 전달이 필요 없다).

재생성하려면 `python build_tool_data.py && python merge_tool.py`를
이 디렉터리에서 순서대로 실행한다. `tool_data.json`은 중간 산출물이라
커밋하지 않는다(`index.html`이 그것을 이미 포함한 최종본).

### 도구 동작 요약

- 좌/우 배치는 `pairs_answer_key.json`에 이미 고정된 시드를 그대로
  쓴다 — 도구가 화면마다 재추첨하지 않는다(두 라벨러가 같은 배치를
  봐야 일치도 계산이 의미가 있다). 세션마다 무작위화되는 것은
  "몇 번째 쌍을 먼저 보여줄지"뿐이다.
- 사진 15쌍을 전부 마쳐야 설명(텍스트) 조건으로 넘어가는 화면이
  나타난다 — 순서 준수를 라벨러의 자율에 맡기지 않고 도구가 강제한다.
- 주의 확인 쌍 2개는 다른 쌍과 구분되는 표시가 전혀 없다.
- 서버가 없다 — 완료 화면에서 JSON을 복사(또는 파일로 저장)해서
  보내주는 방식.
- 안내문에는 "시스템"·"AI"·"점수" 표현을 쓰지 않는다 — 라벨러가
  "AI 점수를 맞히는 과제"로 인식하면 블라인드 설계가 무의미해지기
  때문이다. 정답 없음·시간 제한 없음·라벨러 간 비상의를 명시하고,
  텍스트 조건 전환 시 "사진 때와 같은 답을 내야 한다"는 인상을 주지
  않도록 문구를 확인했다.

### 배포 방법

Claude Artifact로 `index.html`을 게시해 URL을 받고, 그 링크를
카카오톡으로 두 라벨러 각각에게 개별 전송한다. 응답은 라벨러가
완료 화면에서 복사해 보내주는 JSON 텍스트를 그대로 받는다 — 응답
저장 서버는 두지 않는다(요구사항상 "복잡한 수집 인프라를 만들지
않는다"는 제약에 따름).
