# fittingCacheKey 백필 (backfill_fitting_cache_key)

`docs/task_signed_urls_v1.md` §10-1 (B) 결정 실행 도구. `users/{uid}/
history`의 `type=='fitting'` 문서에 `fittingCacheKey` 필드를 채운다
— A-5(군 (c): 홈/캘린더/기록시트/스크랩의 피팅 결과 이미지)가 이
필드로 `fitting_cache` 문서를 특정해 서명 URL을 받는다.

## 왜 "역산"이지 "재계산"이 아닌가

캐시 키를 다시 만드는 게 아니다 — 이미 저장된 `fittingImageUrl`
자체가 그 값을 그대로 담고 있다. 업로드 경로가 `fitting_results/
{cacheKey}.jpg`로 결정론적이라(`storage_service.dart`
`uploadFittingResult`), URL에서 파일명만 떼면 원래 값이 나온다 —
`functions/src/signed_url_policy.ts`의 `pathFromDownloadUrl`과
같은 규칙. 2026-08-06 사전 조사에서 28건 전수 실측 100% 일치(모호성
없음)를 확인한 뒤에 이 스크립트를 만들었다.

## 안전 원칙 (기존 백필 도구와 동일 규약)

- 이미 `fittingCacheKey`가 있는 문서는 절대 덮어쓰지 않는다 — 재실행
  안전.
- 기본 동작은 dry-run. `--apply`를 붙여야 실제로 반영된다.
- `--apply`/`--rollback` 실행 시 대상 프로젝트 id를 직접 입력해야
  진행.
- 서비스 계정 키는 저장소 밖 경로만 허용.
- `fittingImageUrl` 필드는 절대 건드리지 않는다 — `fittingCacheKey`
  필드만 추가한다.
- `--apply`는 (uid, 문서id, 필드명, 값)을 manifest(JSON,
  `manifests/` 아래, 커밋 대상 아님)에 남긴다. `--rollback`은 그
  필드만 정확히 삭제한다.

## fitting_cache 문서가 없는 경우

역산은 성공해도 대응하는 `fitting_cache/{cacheKey}` 문서가 없으면
채우지 않는다(캐시 문서 저장이 실패했던 드문 사례 — `fitting_job_
controller.dart`의 "uid 없으면 캐시 문서 저장만 건너뛴다" 분기 참고).
그런 항목은 목록으로만 보고한다.

## 실행

```bash
pip install -r requirements.txt

# 1. dry-run
python backfill.py --credentials ~/secrets/personal-adminsdk.json

# 2. 확인 후 실제 백필(manifest 자동 기록)
python backfill.py --credentials ~/secrets/personal-adminsdk.json --apply

# 3. 롤백
python backfill.py --credentials ~/secrets/personal-adminsdk.json \
    --rollback manifests/backfill_20260806_153000.json
```
