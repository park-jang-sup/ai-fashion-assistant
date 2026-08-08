# demo_wardrobe 시드

앱 코드(`lib/`)와 무관한 독립 도구. `docs/task_demo_ready_v2.md` F′.1.3 규약에
따라 본인 `wardrobe`(ownerUid 소유)를 `demo_wardrobe`(심사·시연용 공개
읽기 전용 세트)로 복사한다.

## 안전 원칙

- **전량이 기본이다.** 일부만 골라 넣지 않는다 — 논문·사업계획서가 인용하는
  수치가 실제 옷장 전량 기준으로 산출되어 있어, 일부만 넣으면 화면과 문서가
  다른 옷장을 가리키게 된다. 특정 아이템을 빼고 싶으면 `--exclude`로 단순
  제외만 한다(큐레이션 아님). **[갱신 2026-08-08] 실측(재시드 완료 시점):
  118벌, 속성 보유 117벌, 임베딩 보유 99벌.** 이 수치는 옷장이 자라면서
  계속 바뀐다 — 여기 적힌 숫자를 고정값으로 보지 말고, 실행할 때마다
  dry-run(아래 §1)이 출력하는 값을 그 시점의 실제 근거로 삼을 것.
- 기본 동작은 **dry-run** — 아무것도 쓰지 않는다. `--apply`를 붙여야 실제로
  반영된다.
- `--apply` 실행 시 대상 프로젝트 id를 보여주고, **직접 입력해야만** 진행된다.
- 서비스 계정 키는 반드시 **이 저장소 밖**의 로컬 경로(`--credentials`) 또는
  `GOOGLE_APPLICATION_CREDENTIALS` 환경변수로만 넘긴다. 저장소 안의 경로면
  스크립트가 실행을 거부한다.
- `createdAt`은 **원본 값을 그대로** 옮긴다. `serverTimestamp()`로 일괄
  부여하지 않는다 — 118벌이 전부 같은 시각이 되면 동점 정렬이 옷장 순회
  순서로 갈린다.
- `ownerUid`는 옮기지 않는다. `demo_wardrobe`는 특정 사용자 소유가 아니다.
- `demo_wardrobe` 문서 id는 원본 `wardrobe` 문서 id를 그대로 쓴다 — 재실행해도
  같은 문서를 덮어쓸 뿐이라 안전하다(idempotent).
- **[신규 2026-08-08] 원본에서 지워진 문서는 `demo_wardrobe`에서도 지운다.**
  이전엔 upsert만 해서, 원본을 지워도 `demo_wardrobe`엔 고아로 남았다(손상된
  원본 5건이 이 경로로 계속 남아 심사 계정 가상 피팅 404를 재현시킨 사례).
  **Storage 파일은 이 삭제 경로에서 절대 안 건드린다** — `demo_wardrobe`
  문서는 원본과 같은 Storage 파일을 URL로만 공유하고(파일 자체를 복사하지
  않음), 이 저장소는 그 공유 구조 때문에 파일을 잘못 지워 전신 12건을
  영구히 잃은 전례가 있다(`docs/task_signed_urls_v1.md` §8-3). Firestore
  문서만 지운다.
- **삭제 안전장치**: 삭제 대상이 `demo_wardrobe` 전체의 일정 비율
  (`--max-delete-ratio`, 기본 20%)을 넘으면 `--apply`여도 아무것도 쓰지
  않고 중단한다 — `--owner-uid` 오타 등으로 원본 조회 자체가 잘못됐을 때
  대량 오삭제·오시드를 막기 위함. 기본값 20%는 제안일 뿐 확정값이 아니다.
- 삭제 전 무엇을 지웠는지 `manifests/`에 JSON으로 남긴다(문서 전문 백업).
  롤백 기능은 없다 — `demo_wardrobe`가 참조하던 원본이 이미 없어져
  되살려도 무의미한 경우가 많기 때문. 무엇이 사라졌는지 기록만 남긴다.

## 준비

```bash
pip install -r requirements.txt
```

## 실행

### 1. dry-run — 대상 수·분포·보유 수·삭제 대상만 확인

```bash
python seed.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <본인 uid>
```

아무것도 쓰지 않는다. 출력에서 확인할 것 — **이 수치가 사업계획서에 그대로
들어갈 근거다**:

- 총 대상 건수
- 카테고리별 분포
- `attributes` 보유 건수
- `embedding` 보유 건수
- **삭제 대상**(원본에서 없어진 `demo_wardrobe` 문서) — 문서 id·category·
  subCategory까지 전부 열거된다. 지금 시점엔 0건이어야 정상(아직 아무것도
  안 지웠으므로) — 0건이 아니면 그 자체가 확인해야 할 사실이다.

### 2. 확인 후 실제 시드

```bash
python seed.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <본인 uid> --apply
```

대상 프로젝트 id를 입력하면 진행된다. 배치로 `demo_wardrobe`에 기록한 뒤,
`demo_wardrobe` 총 문서 수를 다시 세어 출력한다.

### 3. 특정 아이템 제외

```bash
python seed.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <본인 uid> \
  --apply --exclude <itemId1> --exclude <itemId2>
```

`--owner-uid`에 넣을 값은 앱 설정 화면이나 Firebase 콘솔 → Authentication에서
확인할 수 있다.

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | (없으면 `GOOGLE_APPLICATION_CREDENTIALS`) | 서비스 계정 키 경로 |
| `--owner-uid` | (필수) | 원본 `wardrobe`의 `ownerUid`(본인 uid) |
| `--apply` | off | 실제로 반영(기본은 dry-run) |
| `--exclude` | (없음) | 제외할 `wardrobe` 문서 id. 여러 번 지정 가능(삭제 판정에는 영향 없음 — 아래 참고) |
| `--max-delete-ratio` | 0.2 | 삭제 대상 비율이 이 값을 넘으면 `--apply`여도 중단(제안값, 확정 아님) |

## 배포 순서 주의

`demo_wardrobe` 컬렉션의 `firestore.rules` 블록(읽기 전용)을 먼저 배포하지
않으면 앱이 `demo_wardrobe`를 읽지 못한다. 이 스크립트 자체는 Admin SDK로
쓰므로 규칙과 무관하게 항상 쓸 수 있다 — 순서는:

```
1. firestore.rules 배포(demo_wardrobe read 허용)
2. 이 스크립트로 demo_wardrobe 채우기
3. 앱에서 "데모 옷장 불러오기" 확인
```
