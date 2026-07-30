# F'.3 지표 집계

앱 코드(`lib/`)와 무관한 독립 도구. `docs/task_demo_ready_v2.md` F'.3 규약에
따라 Firestore를 직접 읽어 사업계획서에 넣을 수치를 산출한다. 읽기 전용 —
아무것도 쓰지 않으므로 몇 번을 실행해도 안전하다.

## 산출 항목

- 옷장 규모·구성(총 벌 수, 카테고리별 분포, 격식 분포)
- 속성 추출 성공률(`attributes != null` 비율)
- 임베딩 보유율(`embedding != null` 비율)
- 추천 채택률(`userChoice == accepted` / 응답 있는 추천)
- 백그라운드 발화 간격(`agent_meta.invocationLog` 시계열 — 중앙값/최소/최대,
  `invokeCount`/`skipCount`/`skipped:true` 건수도 함께 출력)

**`isDemo: true`인 wardrobe 문서는 모든 집계에서 제외한다.** 데모 시드가
본인 옷장 수치를 오염시키지 않기 위함이다.

## 옷장 커버리지(표9)는 여기서 다루지 않는다

표9는 `OutfitMatcher`(실제 매칭 엔진)를 그대로 실행해야 나오는 수치라
`test/tpo_policy_report_test.dart`가 이미 계산하고 있다. 이 스크립트를
실행하기 전에:

```bash
python tools/export_for_kaggle/export.py \
  --credentials ~/secrets/personal-adminsdk.json \
  --owner-uid <본인 uid>
flutter test test/tpo_policy_report_test.dart
```

`export.py`는 이번에 `--owner-uid`(선택)와 `isDemo` 제외 필터를 추가했다 —
주지 않으면 `isDemo`만 제외하고 전체를 내보낸다. 표9를 다시 낼 때는
`--owner-uid`로 본인 uid만 좁혀야 데모/타 계정 데이터와 섞이지 않는다.

## 준비

```bash
pip install -r requirements.txt
```

## 실행

```bash
python report.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <본인 uid>
```

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | (없으면 `GOOGLE_APPLICATION_CREDENTIALS`) | 서비스 계정 키 경로 |
| `--owner-uid` | (필수) | 집계 대상 uid(본인 uid) |
