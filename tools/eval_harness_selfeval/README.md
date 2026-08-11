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
