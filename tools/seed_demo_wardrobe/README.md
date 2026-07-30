# demo_wardrobe 시드

앱 코드(`lib/`)와 무관한 독립 도구. `docs/task_demo_ready_v2.md` F'.1.3 규약에
따라 본인 `wardrobe`(ownerUid 소유)를 `demo_wardrobe`(심사·시연용 공개
읽기 전용 세트)로 복사한다.

## 안전 원칙

- **118벌 전량이 기본이다.** 일부만 골라 넣지 않는다 — 문서(사업계획서·논문)의
  수치가 118벌(속성 보유 87벌) 기준으로 산출되어 있어, 일부만 넣으면 화면과
  문서가 다른 옷장을 가리키게 된다. 특정 아이템을 빼고 싶으면 `--exclude`로
  단순 제외만 한다(큐레이션 아님).
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

## 준비

```bash
pip install -r requirements.txt
```

## 실행

### 1. dry-run — 대상 수·분포·보유 수만 확인

```bash
python seed.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <본인 uid>
```

아무것도 쓰지 않는다. 출력에서 확인할 것 — **이 수치가 사업계획서에 그대로
들어갈 근거다**:

- 총 대상 건수
- 카테고리별 분포
- `attributes` 보유 건수
- `embedding` 보유 건수

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
| `--exclude` | (없음) | 제외할 `wardrobe` 문서 id. 여러 번 지정 가능 |

## 배포 순서 주의

`demo_wardrobe` 컬렉션의 `firestore.rules` 블록(읽기 전용)을 먼저 배포하지
않으면 앱이 `demo_wardrobe`를 읽지 못한다. 이 스크립트 자체는 Admin SDK로
쓰므로 규칙과 무관하게 항상 쓸 수 있다 — 순서는:

```
1. firestore.rules 배포(demo_wardrobe read 허용)
2. 이 스크립트로 demo_wardrobe 채우기
3. 앱에서 "데모 옷장 불러오기" 확인
```
