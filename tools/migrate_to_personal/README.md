# 팀 → 개인 Firebase 이관 (wardrobe만, 빠른 이관)

앱 코드(`lib/`)와 무관한 독립 도구. 팀 Firebase 프로젝트
(`ai-fashion-assistant-eb206`)의 `wardrobe` Firestore 컬렉션(embedding
필드 포함)과 관련 Storage 이미지(`wardrobe_images/`, `wardrobe_cutouts/`)만
개인 Firebase 프로젝트로 옮긴다.

**안 옮기는 것**: `users`, `users/*/recommendations`(이력),
`fitting_cache`, `fitting_results`.

## 안전 원칙

- **SOURCE(팀 프로젝트)는 항상 read-only.** 코드 안에서 `source_db`/
  `source_bucket`에는 `stream()`/`get()`/`exists()`/`download_as_bytes()`
  같은 읽기 메서드만 호출되고, `set()`/`update()`/`delete()`/업로드는 전부
  `dest_db`/`dest_bucket`에만 호출된다.
- 기본 동작은 **dry-run** — 아무것도 쓰지 않는다. `--apply`를 붙여야 실제로
  반영된다.
- `--apply` 실행 시 `SOURCE {id}(읽기) → DEST {id}(쓰기)` 방향을 보여주고,
  **대상 프로젝트 id를 직접 입력해야만** 진행된다(방향이 뒤집히지 않았는지
  사람이 확인).
- 서비스 계정 키는 반드시 **이 저장소 밖**의 로컬 경로로만 넘긴다. 저장소
  안의 경로면 스크립트가 실행을 거부한다.
- 문서 id는 소스와 동일하게 유지 — 재실행 시 대상에 이미 있는 문서는
  기본적으로 건너뛴다(`--force`로만 재이관). 중간에 실패해도 다시 실행하면
  이어서 진행된다.

## 준비

```bash
pip install -r requirements.txt
```

Firebase 콘솔에서 **두 프로젝트 각각**의 서비스 계정 키를 발급받아 이
저장소 밖의 로컬 경로에 저장한다(예: `~/secrets/team-adminsdk.json`,
`~/secrets/personal-adminsdk.json`).

## 실행

### 1. dry-run — 이미지 필드 구성부터 확인

```bash
python migrate.py \
  --source-credentials ~/secrets/team-adminsdk.json \
  --dest-credentials ~/secrets/personal-adminsdk.json \
  --dest-bucket ai-fashion-assistant-personal.firebasestorage.app
```

아무것도 쓰지 않는다. 출력에서 확인할 것:

- `imageUrl`/`cutoutImageUrl` 필드 보유 건수, 둘 다 없는 문서 목록
- 예상 밖 이름의 URL 필드, 파싱 실패 의심 필드가 있는지
- URL 변환 샘플(소스 URL → 오브젝트 경로 → 대상 URL 예정 형태)
- 이관/스킵 예정 건수

### 2. 확인 후 실제 이관

```bash
python migrate.py \
  --source-credentials ~/secrets/team-adminsdk.json \
  --dest-credentials ~/secrets/personal-adminsdk.json \
  --dest-bucket ai-fashion-assistant-personal.firebasestorage.app \
  --apply
```

방향 확인 프롬프트에 대상 프로젝트 id를 입력하면 진행된다. 문서별로
`[n/전체] itemId: OK/SKIP/FAIL` 로그가 출력되고, 끝나면 요약(성공/스킵/
실패, 이미지 업로드 성공/실패, 이미지 없는 문서 수)이 나온다.

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--source-credentials` | (필수) | 소스(팀) 프로젝트 서비스 계정 키 |
| `--dest-credentials` | (필수) | 대상(개인) 프로젝트 서비스 계정 키 |
| `--source-bucket` | `ai-fashion-assistant-eb206.firebasestorage.app` | 소스 Storage 버킷 |
| `--dest-bucket` | (필수) | 대상 Storage 버킷 |
| `--apply` | off | 실제로 이관(기본은 dry-run) |
| `--force` | off | 대상에 이미 있는 문서도 다시 이관 |
| `--sample-count` | 3 | dry-run 시 URL 변환 샘플 개수 |

## 실패 처리 방식

- `imageUrl`(필수) 이관이 실패하면 그 문서 전체를 대상에 쓰지 않고 실패로
  기록 — 다음 재실행 때 자동으로 다시 시도된다.
- `cutoutImageUrl`이나 그 외 예상 밖 이미지 필드가 실패하면 그 필드만 빼고
  문서는 계속 이관한다(앱이 이미 "컷아웃 없으면 원본만 사용"을 지원).
- 이미지 URL 필드가 아예 없는 문서는 실패가 아니라 "이미지 없음"으로
  집계하고 메타데이터만 이관한다.
