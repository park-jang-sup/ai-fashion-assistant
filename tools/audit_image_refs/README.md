# 이미지 참조 감사 (audit_image_refs)

앱 코드(`lib/`)와 무관한 독립 도구. `wardrobe`/`demo_wardrobe`/`fitting_cache`
문서가 가리키는 Storage 파일이 실제로 존재하는지 전수 검사한다.
`docs/task_signed_urls_v1.md` 관문 A 조사(2026-08-06)에서 발견한 "고아
참조"(문서는 다운로드 URL을 갖고 있으나 Storage에 그 파일이 없는 경우 —
wardrobe 상의 3건)를 다시 찾아내려고 만들었다. 읽기 전용 — 아무것도 쓰지
않으므로 몇 번을 실행해도 안전하다.

## 핵심 함정 — 403 ≠ 권한 문제

Firebase Storage의 공개 다운로드 엔드포인트(`.../o/{path}?alt=media&token=...`)는
**"토큰이 틀림"과 "객체가 아예 없음"을 구분하지 않고 둘 다 403으로
응답한다**(열거 공격 방지 목적으로 보인다). 그래서 공개 URL만 두드려서는
"403 = 권한 문제"라고 단정할 수 없다 — `--check-storage`로 Admin SDK
`bucket.blob(path).exists()`를 직접 불러야 진짜 원인(권한 문제 vs 파일
부재)이 갈린다. 2026-08-06 실측에서는 403 3건 전부 `exists()==False`
(파일 자체가 없음)로 확인됐지만, 이게 항상 성립한다고 가정하지 말 것 —
매번 `--check-storage`로 재확인해야 한다.

## 안전 원칙

- 읽기 전용 — Firestore/Storage 어디에도 쓰지 않는다.
- 서비스 계정 키는 반드시 **이 저장소 밖**의 로컬 경로(`--credentials`) 또는
  `GOOGLE_APPLICATION_CREDENTIALS` 환경변수로만 넘긴다. 저장소 안의 경로면
  스크립트가 실행을 거부한다.
- 출력에 다운로드 토큰이 든 원본 URL을 그대로 찍지 않는다 — Storage
  경로(토큰 없음)와 상태 코드만 남긴다.

## 준비

```bash
pip install -r requirements.txt
```

## 실행

### 1. 기본 — 특정 사용자 소유 문서의 공개 URL만 두드려 상태 코드 집계

```bash
python audit.py --credentials ~/secrets/personal-adminsdk.json --owner-uid <uid>
```

### 2. Storage 파일 존재까지 직접 대조(진짜 원인 판별)

```bash
python audit.py --credentials ~/secrets/personal-adminsdk.json \
  --owner-uid <uid> --check-storage
```

서비스 계정에 해당 버킷 읽기 권한이 있어야 한다.

### 3. 특정 사용자로 좁히지 않고 컬렉션 전체(모든 소유자) 검사

```bash
python audit.py --credentials ~/secrets/personal-adminsdk.json --all-owners
```

### 4. fitting_cache까지 함께 검사

```bash
python audit.py --credentials ~/secrets/personal-adminsdk.json \
  --owner-uid <uid> --collections wardrobe fitting_cache
```

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | (없으면 `GOOGLE_APPLICATION_CREDENTIALS`) | 서비스 계정 키 경로 |
| `--owner-uid` | (없음) | 이 ownerUid 소유 문서만 검사 |
| `--all-owners` | off | ownerUid로 좁히지 않고 컬렉션 전체 검사(`--owner-uid`와 배타 아님, 둘 중 하나 필수) |
| `--collections` | `wardrobe` | 검사할 컬렉션(`wardrobe`/`demo_wardrobe`/`fitting_cache`, 여러 개 지정 가능) |
| `--check-storage` | off | 403/404인 문서에 한해 Admin SDK로 파일 존재 여부까지 직접 확인 |
| `--bucket` | `ai-fashion-assistant-personal.firebasestorage.app` | Storage 버킷 이름 |

## 출력 읽는 법

- "200이 아닌 것" 표에 컬렉션·문서id·필드·카테고리·상태코드·생성시각·경로·
  Storage 존재 여부가 나온다.
- `--check-storage` 없이 실행하면 "Storage 존재" 열은 항상
  `(--check-storage 안 씀)`으로 비워진다 — 403이 권한 문제인지 파일
  부재인지는 이 실행만으로 알 수 없다는 뜻이다.
- 처분(문서 정리·재업로드 요청 등)은 이 스크립트가 하지 않는다 — 목록만
  뽑고 판단은 사람이 한다.
