# 이미지 경로 백필 (backfill_image_paths)

앱 코드(`lib/`)와 무관한 독립 도구. `docs/task_signed_urls_v1.md` Phase B
규약에 따라 `wardrobe`/`demo_wardrobe` 문서에 `imagePath`/`cutoutPath`
필드를 백필한다(기존 다운로드 URL에서 경로 역산). `getSignedImageUrls`
(functions)가 이 필드를 우선 읽고, 없으면 URL에서 즉석 역산한다 — 이
스크립트는 그 즉석 역산 결과를 영속화해 매 호출마다 다시 계산하지 않게
하는 용도다.

## fitting_cache는 왜 대상이 아닌가

`fitting_cache` 문서의 Storage 경로는 문서 id 자체에서 결정론적으로
나온다(`fitting_results/{id}.jpg`) — 저장할 게 없다. 다만 지시서가
감사 대상으로 지정했으므로 이 스크립트도 `fitting_cache`를 **감사(파일
존재 확인)만** 하고 아무것도 쓰지 않는다.

## 핵심 원칙 — 파일 존재와 경로 역산은 별개다

경로 역산(URL 문자열 파싱)은 파일이 실제로 있는지 모른다.
[2026-08-06 관문 A 조사]에서 정확히 이 사각지대로 고아 참조 3건
(wardrobe 상의, 문서는 URL을 갖고 있지만 Storage에 파일 없음)을
찾아냈다 — `tools/audit_image_refs` 참고. 그래서 이 스크립트는 dry-run
출력을 **두 축**으로 분리한다:

1. 경로 역산 성공/실패 (URL 문자열 파싱 문제)
2. 파일 존재/부재 (`bucket.blob(path).exists()`로 직접 확인)

**파일이 없어도 path 필드는 그대로 백필 대상에 포함한다.** 경로 계산
자체는 유효하다(파일이 없을 뿐 경로는 맞다) — 스크립트가 부재 건을
임의로 판단해 빼지 않는다. 처분은 사람이 정한다.

## 안전 원칙

- **이미 `imagePath`/`cutoutPath`가 있는 문서는 절대 건드리지 않는다.**
  재실행해도 안전 — 대상은 매번 "필드 없는 문서"만 다시 집계된다.
- 기본 동작은 **dry-run** — 아무것도 쓰지 않는다. `--apply`를 붙여야
  실제로 반영된다.
- `--apply` 실행 시 대상 프로젝트 id를 보여주고, **직접 입력해야만**
  진행된다.
- 서비스 계정 키는 반드시 **이 저장소 밖**의 로컬 경로(`--credentials`)
  또는 `GOOGLE_APPLICATION_CREDENTIALS` 환경변수로만 넘긴다.
- **URL 필드(`imageUrl`/`cutoutImageUrl`)는 절대 건드리지 않는다**
  (task_signed_urls_v1.md §1-4) — path 필드를 추가만 한다.

## 준비

```bash
pip install -r requirements.txt
```

## 실행

### 1. dry-run — 두 축 집계와 샘플만 확인

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json
```

아무것도 쓰지 않는다. 출력에서 확인할 것:

- 이미 path 보유(건드리지 않음) / URL 필드 자체 없음(대상 아님) / 경로
  역산 실패 / **경로 역산 성공 + 파일 존재** / **경로 역산 성공 + 파일
  부재(고아 참조 후보)** 5개 분류 건수
- fitting_cache 감사 결과(파일 존재/부재)
- 각 분류 샘플(기본 5건)

### 2. 확인 후 실제 백필

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json --apply
```

대상 프로젝트 id를 입력하면 진행된다. wardrobe/demo_wardrobe에 path
필드를 배치로 기록한다(파일 부재 건 포함 — 제외하지 않음).
`fitting_cache`는 `--apply`를 줘도 아무것도 쓰지 않는다(감사만 계속
수행). 실제로 쓴 (컬렉션, 문서id, 필드명, 값)은 `manifests/`(커밋
대상 아님)에 JSON으로 남는다.

### 3. 특정 소유자로 좁히기 — `--owner-uid`

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json \
  --owner-uid <uid>
```

`wardrobe`만 그 소유자로 좁혀 처리한다. `demo_wardrobe`는 `ownerUid`
필드 자체가 없는 공용 컬렉션이라 uid로 못 거르므로, `--owner-uid`를
쓰면 이번 실행에서 통째로 건너뛰고 그 사실을 출력에 명시한다.

### 4. 특정 컬렉션으로 좁히기 — `--collections`

```bash
# demo_wardrobe만(ownerUid가 없어 --owner-uid로는 못 고른다)
python backfill.py --credentials ~/secrets/personal-adminsdk.json \
  --collections demo_wardrobe --apply
```

`--owner-uid`와 함께 쓰면 두 조건을 모두 만족해야 한다(예:
`--owner-uid X --collections wardrobe`는 `--owner-uid X`만 줬을 때와
결과가 같다 — `demo_wardrobe`가 어차피 건너뛰어지므로).

### 5. 롤백 — manifest에 적힌 필드만 정확히 삭제

```bash
python backfill.py --credentials ~/secrets/personal-adminsdk.json \
  --rollback manifests/backfill_20260806_120000.json
```

문서 전체가 아니라 manifest에 적힌 필드만 지운다 — 백필 이전부터 이미
`imagePath`가 있던 문서(정상 업로드분)는 manifest에 없어 롤백 대상도
아니다.

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | (없으면 `GOOGLE_APPLICATION_CREDENTIALS`) | 서비스 계정 키 경로 |
| `--apply` | off | 실제로 반영(기본은 dry-run) |
| `--owner-uid` | (없음) | `wardrobe`를 이 소유자로 좁힌다. 주면 `demo_wardrobe`는 건너뜀 |
| `--collections` | `wardrobe demo_wardrobe` 둘 다 | 처리할 컬렉션을 좁힌다 |
| `--rollback` | (없음) | 지정한 manifest의 필드만 삭제하고 종료 |
| `--bucket` | `ai-fashion-assistant-personal.firebasestorage.app` | Storage 버킷 이름 |
| `--sample-count` | 5 | dry-run 시 분류별 샘플 수 |
