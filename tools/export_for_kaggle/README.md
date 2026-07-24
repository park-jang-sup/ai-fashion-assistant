# Kaggle 임베딩 품질 비교용 데이터 내보내기

앱 코드(`lib/`)와 무관한 독립 도구. Firebase Admin SDK로 Firestore/Storage를
직접 읽어 옷장 이미지·메타데이터·추천 이력·매칭 알고리즘 명세를 로컬로
내보낸 뒤 `wardrobe_export.zip` 하나로 묶는다.

## 준비

```bash
pip install -r requirements.txt
```

Firebase 콘솔 → 프로젝트 설정 → 서비스 계정 → "새 비공개 키 생성"으로
받은 JSON 키 파일을 **이 저장소 밖의 아무 로컬 경로**에 저장한다(예:
`~/secrets/ai-fashion-assistant-firebase-adminsdk.json`). 이 폴더 안에
두면 스크립트가 실행을 거부한다.

## 실행

```bash
export GOOGLE_APPLICATION_CREDENTIALS=~/secrets/ai-fashion-assistant-firebase-adminsdk.json
python export.py
```

또는 `--credentials` 인자로 직접 경로를 넘겨도 된다. 주요 옵션:

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | `$GOOGLE_APPLICATION_CREDENTIALS` | 서비스 계정 키 경로 |
| `--bucket` | `ai-fashion-assistant-eb206.firebasestorage.app` | Storage 버킷 |
| `--output-dir` | `./output` | 출력 디렉토리 |
| `--max-side` | `512` | 이미지 긴 변 리사이즈 목표(px) |
| `--bg-color` | `white` | 투명 cutout PNG를 JPEG로 저장할 때 채울 배경색 |
| `--force` | off | 이미 내려받은 이미지도 다시 다운로드 |

## 출력물 (`output/` → `wardrobe_export.zip`)

- `images/{itemId}.jpg` — 옷장 이미지. cutout(배경 제거본)이 있으면 그것을,
  없으면 원본을 사용한다(`items.csv`의 `imageSource` 컬럼에 어느 쪽인지 기록).
  긴 변 512px로 리사이즈, 투명 배경은 흰색으로 합성 후 JPEG 저장.
- `items.csv` / `items.json` — itemId, category, subCategory, 6개 속성
  (color/style/pattern/formality/fit/tags), createdAt, imageSource.
- `history.json` — `users/*/recommendations`를 전부 모은 추천 이력. 실제
  Firebase uid는 절대 포함하지 않고 `user_001`, `user_002`처럼 등장 순서
  기반 익명 라벨로 치환한다(코디 데이터는 uid 없이 itemIds만으로 충분히
  조인 가능).
- `matcher_spec.md` — `lib/services/outfit_matcher.dart`의 스코어링/조합
  생성 로직을 Python 재구현 가능한 수준으로 문서화한 알고리즘 명세.

## 보안

- 서비스 계정 키는 스크립트가 **읽기만** 하고 export 폴더 어디에도 복사하지
  않는다. 경로가 이 디렉토리 안이면 스크립트가 즉시 종료한다.
- 마지막 단계에서 출력 디렉토리 전체를 스캔해 `private_key`, `BEGIN
  PRIVATE KEY`, `client_email` 등 자격증명 흔적과 예상치 못한 파일(허용
  목록: `items.csv`/`items.json`/`history.json`/`matcher_spec.md`/
  `images/*.jpg`)이 있는지 확인한다. 문제가 있으면 zip을 만들지 않고
  종료 코드 1로 실패한다.
- `output/`, `wardrobe_export.zip`, 서비스 계정 키로 보이는 파일 패턴은
  저장소 루트 `.gitignore`에 등록되어 있다.
