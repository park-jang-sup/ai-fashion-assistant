# Firestore 전체 백업 (2026-08-15)

Blaze(종량제) 플랜 해제 전, 콘솔/API 접근이 막히기 전에 Firestore 전체를 덤프한 것이다.
읽기 전용 스크립트로 생성했으며, 프로덕션 데이터에 대한 쓰기는 발생하지 않았다.

## 덤프 시각과 그 시점의 상태

- `dumpedAt`: `2026-08-15T12:29:12Z` (KST 21:29) — `manifest.json` 참고.
- 최상위 컬렉션: `wardrobe` 254건, `demo_wardrobe` 113건, `fitting_cache` 51건, `rate_limits` 7건.
- `users`: 3개 계정.
  - `BDDOIl08...`: agent_logs 355 / agent_meta 1 / calendar 10 / fcm_tokens 1 / history 127 / recommendations 37 / scraps 1
  - `JmllppO9...`: agent_logs 182 / agent_meta 1 / agent_tasks 1 / calendar 14 / history 16 / recommendations 23 / scraps 1
  - `yPyw4DC2...`: agent_logs 190 / agent_meta 1 / calendar 16 / fcm_tokens 1 / history 55 / recommendations 18 (scraps 서브컬렉션 없음)

컬렉션 목록은 `db.collections()`로 먼저 조회해 확인한 것이며, 알고 있던 이름만 내보낸 것이 아니다.

논문 등에서 이 시점의 실측(문서 수, 분포)을 인용할 때는 이 README와 `manifest.json`을 근거로 삼으면
재현 가능하다.

## raw/ vs sanitized/ — 왜 나눴는가

이 저장소(`park-jang-sup/ai-fashion-assistant`)는 **공개(public) 저장소**다. Firestore 원본에는
다음과 같은 개인정보/민감정보가 포함되어 있다:

- Firebase Storage 이미지 URL(`imageUrl`, `cutoutImageUrl` 등) — 다운로드 토큰이 포함되어 있어
  Security Rules를 우회해 직접 접근 가능하다(논문 §5.13.2 "발급된 주소의 회수 불가" 참고). 토큰이
  한번 공개 저장소 히스토리에 들어가면 회수할 방법이 없다.
- 체형 프로필(`heightCm`, `weightKg`, `waistCm`, `chestCm`, `personalColor`, `bodyType`,
  `preferredStyles`, 위치 정보 등) — `users/{uid}` 최상위 문서.
- 512차원 CLIP 임베딩 벡터 — 옷 사진에서 뽑은 개인 데이터 파생물. 기존 `.gitignore`에서
  `tools/export_for_kaggle/embeddings.json`을 제외해 온 것과 같은 이유로 취급한다.
- 전체 Firebase uid, FCM 토큰(기기 식별자) — `fcm_tokens` 서브컬렉션은 토큰 자체가 문서 ID다.

그래서 두 벌로 나눴다.

- **`raw/`** — 마스킹 없는 원본 전체. **git에 커밋하지 않는다** (`.gitignore`에 등록).
  로컬에만 존재하며, 복구가 필요하면 이 폴더에서 직접 재적재한다.
- **`sanitized/`** — 아래 규칙으로 마스킹한 버전. 커밋 대상.

### sanitized/ 마스킹 규칙

| 대상 | 처리 |
|---|---|
| `http`로 시작하는 문자열(모든 이미지 URL) | `"[REDACTED-URL]"`로 치환 |
| 키 이름이 `vector`인 필드(임베딩) | `"[REDACTED-VECTOR len=N]"`으로 치환(차원 수만 남김) |
| `users/{uid}` 최상위 문서의 체형/위치 필드 | 통째로 제거, 대신 `_hasProfile: true/false`만 남김 |
| `users` 및 `fcm_tokens` 문서 ID | `uid-{앞 8자}`, `[REDACTED-ID-N]`으로 치환 |
| 그 외 필드(옷 카테고리, 색상, 스타일 태그, 캘린더 일정 텍스트, 추천 로그 등) | 그대로 유지 |

즉 "이 앱이 어떤 데이터 구조와 분포로 동작했는가"를 논문/재현 목적으로 확인하는 데는 `sanitized/`로
충분하고, 실제 개인을 특정하거나 이미지에 접근할 수 있는 정보는 남기지 않았다.

검증: `sanitized/` 전체에서 `http` 문자열 잔존 0건, 임베딩 필드가 실제로 치환됐는지 직접 파일
확인, 한글 텍스트가 실제로 깨지지 않은 유효 UTF-8인지 `Read` 도구로 직접 확인(터미널 출력에서
보였던 깨짐은 셸 코드페이지 표시 문제였을 뿐, 파일 자체는 정상이었다).

## 파일 구성

```
manifest.json              # 덤프 메타(시각, 프로젝트, 컬렉션별 건수)
raw/                        # 원본 전체 — git-ignored
  wardrobe.json, demo_wardrobe.json, fitting_cache.json, rate_limits.json
  users.json                # users/{uid} 최상위 문서 전체
  users/{uid}/{subcollection}.json
sanitized/                  # 마스킹본 — 커밋 대상
  (raw/와 동일한 구조, uid는 uid-{8자}로 치환)
```
