# Storage 다운로드 토큰 회수 (revoke_storage_tokens)

앱 코드(`lib/`)와 무관한 독립 도구. `docs/task_signed_urls_v1.md`
Phase C — `wardrobe_images/`·`wardrobe_cutouts/` 아래 파일의
`firebaseStorageDownloadTokens` 커스텀 메타데이터를 제거해 기존
영구 다운로드 URL(질의 문자열의 구 토큰)을 무효화한다. **파일 자체는
지우지 않는다.**

서명 URL(V4, IAM signBlob 기반)은 이 토큰과 완전히 별개 메커니즘이라
회수해도 영향받지 않는다 — 이게 이 회수가 "구멍을 실제로 닫는" 단계인
이유다(5.13.2).

## 되돌리기 어려운 단계 — 반드시 dry-run 먼저

이미 배포된 클라이언트가 구 URL을 캐시/저장해 두고 있다면 회수 즉시
그 URL은 못 쓴다. `--apply` 전에 dry-run으로 대상 개수·경로 샘플·
토큰 보유 여부를 반드시 확인할 것.

`--apply`는 실제로 제거한 (경로, 원래 토큰 값)을 `manifests/`(커밋
대상 아님)에 JSON으로 남긴다. `--rollback`은 그 manifest를 읽어
**정확히 같은 토큰 값**을 복원한다 — Firebase Storage는 토큰 이력을
따로 추적하지 않으므로, 원래 값을 그대로 되돌려 놓으면 원래 URL이
다시 살아난다.

## demo_wardrobe는 왜 별도 처리가 없나

`demo_wardrobe`는 `wardrobe`와 같은 물리 Storage 경로(같은 파일)를
재사용한다(`tools/seed_demo_wardrobe` 참고). 이 스크립트는 Storage
객체 단위로 동작하므로, 회수 한 번으로 두 컬렉션의 참조가 동시에
무효화된다 — 컬렉션별로 따로 돌 필요가 없다.

## fitting_cache는 대상이 아니다

`fitting_results/`는 기본 프리픽스에 없다. 재생성·캐시 히트 경로와
얽혀 성격이 달라 Phase C-3에서 별도 절차로 처리한다.

## 안전 원칙

- 파일 삭제·이동은 절대 하지 않는다 — 메타데이터 키 하나만 건드린다.
- 기본 동작은 **dry-run** — 아무것도 쓰지 않는다.
- `--apply`/`--rollback` 실행 시 대상 프로젝트 id를 **직접 입력**해야
  진행된다.
- 서비스 계정 키는 반드시 **이 저장소 밖**의 로컬 경로(`--credentials`)
  또는 `GOOGLE_APPLICATION_CREDENTIALS` 환경변수로만 넘긴다.

## 준비

```bash
pip install -r requirements.txt
```

## 실행

### 1. dry-run — 대상 개수·경로 샘플·토큰 보유 여부 확인

```bash
python revoke.py --credentials ~/secrets/personal-adminsdk.json
```

### 2. 확인 후 실제 회수(manifest 자동 기록)

```bash
python revoke.py --credentials ~/secrets/personal-adminsdk.json --apply
```

### 3. 롤백 — manifest에 적힌 원래 토큰 값을 정확히 복원

```bash
python revoke.py --credentials ~/secrets/personal-adminsdk.json \
  --rollback manifests/revoke_20260806_120000.json
```

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | (없으면 `GOOGLE_APPLICATION_CREDENTIALS`) | 서비스 계정 키 경로 |
| `--apply` | off | 실제로 반영(기본은 dry-run) |
| `--rollback` | (없음) | 지정한 manifest의 토큰을 복원하고 종료 |
| `--prefixes` | `wardrobe_images/ wardrobe_cutouts/` | 대상 경로 프리픽스(여러 개 지정 가능) |
| `--bucket` | `ai-fashion-assistant-personal.firebasestorage.app` | Storage 버킷 이름 |
| `--sample-count` | 5 | dry-run 시 보여줄 샘플 수 |
