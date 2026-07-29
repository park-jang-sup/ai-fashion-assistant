# wardrobe ownerUid 백필

앱 코드(`lib/`)와 무관한 독립 도구. `docs/task_multi_user.md` D.2 규약에 따라
`wardrobe` 컬렉션에서 `ownerUid` 필드가 없는 기존 문서(다중 사용자 격리 이전에
만들어진 문서)에 `ownerUid`를 채워 넣는다.

## 안전 원칙

- **`ownerUid`가 이미 있는 문서는 절대 건드리지 않는다(기본 모드).** 대상은
  매 실행마다 "없는 문서"만 다시 집계하므로 재실행해도 안전하다.
  `--force`를 주면 이미 값이 있는 문서도 덮어쓴다(예: 잘못된/옛 uid로
  백필된 뒤 재배정이 필요할 때) — 이 경우 재실행 안전성이 깨지므로
  신중히 써야 한다.
- 기본 동작은 **dry-run** — 아무것도 쓰지 않는다. `--apply`를 붙여야 실제로
  반영된다.
- `--apply` 실행 시 대상 프로젝트 id를 보여주고, **직접 입력해야만** 진행된다.
- 서비스 계정 키는 반드시 **이 저장소 밖**의 로컬 경로(`--credentials`) 또는
  `GOOGLE_APPLICATION_CREDENTIALS` 환경변수로만 넘긴다. 저장소 안의 경로면
  스크립트가 실행을 거부한다.
- 마지막에 `ownerUid` 없는 문서 수를 다시 세어 **0이 아니면 실패로 종료**한다.
  누락된 문서는 그 옷이 화면에서 영원히 사라진다는 뜻이라, 스크립트가 스스로
  확인한다.

## 준비

```bash
pip install -r requirements.txt
```

## 실행

### 1. dry-run — 대상 수와 샘플만 확인

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json
```

아무것도 쓰지 않는다. 출력에서 확인할 것:

- **`users` 컬렉션 문서 수와 부여 예정 `ownerUid`, 그 결정 방식.**
  `users` 문서 id가 곧 uid이므로(`firestore_service.dart`의
  `_db.collection('users').doc(uid)` 규약), 문서가 정확히 1개면 그 uid로
  자동 결정하고 이유를 출력한다. 0개거나 2개 이상이면 **자동 결정하지 않고**
  후보 목록만 보여준다 — 후보가 여럿인 상태에서 하나를 임의로 골라 엉뚱한
  사용자에게 옷장을 붙여버리는 사고를 막기 위함이다. 이 경우
  `--apply` 시 `--owner-uid`를 반드시 사람이 직접 지정해야 한다.
- `ownerUid` 없는 문서 수
- 샘플 문서(기본 5건)의 itemId, createdAt

### 2. 확인 후 실제 백필

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json \
  --apply --owner-uid <현재 사용 중인 익명 계정 uid>
```

대상 프로젝트 id를 입력하면 진행된다. 배치로 `ownerUid` 필드를 기록한 뒤,
끝나면 `ownerUid` 없는 문서를 다시 세어 0건인지 검증하고 결과를 출력한다.
0건이 아니면 실패로 종료(exit code 1)한다.

`--owner-uid`에 넣을 값은 앱 설정 화면이나 Firebase 콘솔 → Authentication에서
확인할 수 있다.

### 3. 이미 값이 기록된 문서를 재배정 — `--force`

uid가 바뀌었거나(예: 앱 재설치로 새 익명 uid 발급) 잘못된 값으로 백필됐을 때,
이미 `ownerUid`가 있는 문서까지 포함해 전부 새 값으로 덮어쓴다.

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json \
  --apply --owner-uid <새 uid> --force
```

dry-run(`--force`만 붙이고 `--apply` 생략)에서는 샘플에 `현재ownerUid`가
같이 출력되어 무엇을 덮어쓰는지 미리 확인할 수 있다. 검증 단계도
기본 모드보다 엄격해서, "`ownerUid`가 없는 문서 0건"이 아니라
**"`ownerUid`가 지정한 값과 다른 문서 0건"**을 확인한다 — wardrobe 전체가
남김없이 새 uid로 재배정됐는지까지 스크립트가 스스로 확인한다.

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | (없으면 `GOOGLE_APPLICATION_CREDENTIALS`) | 서비스 계정 키 경로 |
| `--apply` | off | 실제로 반영(기본은 dry-run) |
| `--owner-uid` | (`--apply` 시 필수) | 백필할 ownerUid 값 |
| `--force` | off | 이미 `ownerUid`가 있는 문서도 덮어쓴다(재실행 안전성 깨짐) |
| `--sample-count` | 5 | dry-run 시 출력할 샘플 개수 |
