# 작업 정리 (2026-07-29 세션 2 — 다중 사용자 격리 D단계 + 계정 승격 E단계)

`docs/task_multi_user.md` 지시서의 D단계와 E단계를 순서대로 진행했다
(F단계·실사용자 배포는 이번 세션에서 건너뜀 — 아직 미착수). 배포 순서(0절:
인덱스→백필→앱 릴리스→규칙 배포)를 그대로 지켰고, 규칙 배포는 매번
`firebase use`로 활성 프로젝트(`ai-fashion-assistant-personal`)를 먼저
확인한 뒤에만 실행했다. 전부 커밋(`177d7eb`)·push 완료.

## 1. D단계 — Firestore 사용자 격리

### D.1 복합 인덱스
`firestore.indexes.json`에 `wardrobe` 컬렉션 `ownerUid`(ASC) +
`createdAt`(DESC) 복합 인덱스 추가 → 배포 → 콘솔에서 "사용 설정됨" 확인
(사용자 확인) 후 다음 단계 진행.

### D.2 백필 스크립트 — `tools/backfill_owner_uid/`
`tools/migrate_to_personal/migrate.py`와 동일한 안전 규약으로 신설:
- 서비스 계정 키는 `--credentials`/`GOOGLE_APPLICATION_CREDENTIALS`로만,
  저장소 내부 경로는 거부.
- 기본 dry-run, `--apply` 시 대상 프로젝트 id를 직접 입력해야 진행.
- `ownerUid` 없는 문서만 대상(있으면 안 건드림 — 재실행 안전), 마지막에
  누락 0건 검증.
- **부가 기능(사용자 요청)**: dry-run에 "부여 예정 ownerUid"와 결정 방식을
  표시. `users` 컬렉션(문서 id == uid) 문서 수를 함께 출력해, 정확히
  1개일 때만 자동 후보 결정하고 0개/2개 이상이면 자동 결정하지 않고
  `--owner-uid` 직접 지정을 요구.
- **`--force` 옵션 추가(세션 중반, 사고 대응)**: 이미 `ownerUid`가 있는
  문서까지 새 값으로 덮어쓴다. 검증도 더 엄격해져 "지정한 uid와 다른 문서
  0건"까지 확인.

1차 백필: 118건 반영, 누락 0건 검증 통과.

### D.3 모델·서비스·호출부
- `lib/models/wardrobe_item.dart`: `ownerUid`(nullable) 필드 추가.
- `lib/services/firestore_service.dart`: `wardrobeStream(String uid)` —
  `where(ownerUid) + orderBy(createdAt)`로 변경. `addWardrobeItem`에
  `required String ownerUid` 추가(optional로 두면 새 등록 경로가 생겼을 때
  조용히 누락될 수 있어 컴파일 타임에 강제).
- `wardrobeStream()` 호출부 12곳 전부 수정(grep으로 누락 없음 확인):
  `agent_planner.dart`(×3, 백그라운드 경로 포함), `calendar_record_sheet.dart`,
  `similarity_check.dart`, `home_screen.dart`(×2), `calendar_screen.dart`,
  `wardrobe_screen.dart`, `outfit_board.dart`, `fitting_room_screen.dart`(×2).
  uid를 못 구하는 지점은 빈 문자열/임의값 대신 `Stream.empty()`로 대체해
  "옷장이 비었다"는 오탐을 막음.

### D.4 규칙
`firestore.rules`: `wardrobe`를 소유자 검사로 변경(`create`와
`update/delete` 분리 — `request.resource` vs `resource` 차이 때문).
`fitting_cache`는 `allow get, write` + `allow list: if false`로 변경(문서
열거로 남의 가상 피팅 URL을 얻는 경로 차단, 마이그레이션 불필요).

### 사고와 대응 — uid 변경으로 옷장이 "사라짐"
규칙 배포 후 사용자가 릴리스 APK를 재설치하는 과정에서 세션 uid가
`JmllppO9t9NcU0NiaDWrbOnP4ae2` → `BDDOIl08EhXnHu6oz6Zro47EtMw1`로 바뀌었다
(원인 미조사 — `adb install -r`은 정상적으로 데이터를 보존하므로 재설치
자체보다 그 사이 다른 세션 이벤트가 있었을 가능성). 결과적으로 118벌
전부가 새 uid로는 안 보이는, **지시서가 명시적으로 경고한 실패 모드**가
그대로 재현됐다. 위에서 추가한 `--force`로 118건을 새 uid에 재배정,
스크립트 자체 검증(불일치 0건) 통과 후 실기기에서 옷장 재확인 완료.

### D단계 관문
1~6 전부 통과(4·6은 사용자가 "옷 등록하면 활동내역에 잘 찍힘"으로
포괄 확인). 3·5는 위 사고 대응 후 재검증까지 마침.

### 검증
`flutter analyze` 통과(무관한 기존 info 1건만 유지), `flutter test`
137개 전체 통과.

## 2. E단계 — 계정 승격 (교체 아닌 링크)

### E.1 의존성
`pubspec.yaml`에 `google_sign_in: ^6.2.1` 추가 → `6.3.0`으로 해결,
**버전 충돌 없음**(보고 후 승인받을 사안 자체가 발생하지 않음).

### E.2 승격 로직 — 신규/수정 파일
- `lib/services/google_auth_service.dart`(신규): 구글 계정 선택 →
  `AuthCredential` 생성만 공유(link/signIn 분기는 호출부 책임).
- `lib/screens/login_screen.dart`: `_signInAnonymously` 자리표시자 →
  `_continueWithGoogle`로 교체. 이 화면은 `currentUser`가 없을 때만
  보이므로(`main.dart`의 `authStateChanges` 라우팅) **`signInWithCredential`**
  사용 — 재설치 후 같은 구글 계정으로 로그인하면 그 계정에 이미 연결된
  uid로 자연스럽게 복원됨(E단계 관문 2 경로 자체).
- `lib/screens/settings_screen.dart`: "계정 연동" 행 추가(미연동 →
  "Google 계정 연동" 버튼, 연동됨 → 이메일 표시). 여기는 이미 익명
  세션이 있으므로 **`linkWithCredential`**(uid 불변) 사용:
  - `provider-already-linked` → 조용히 성공 처리
  - `credential-already-in-use` → 확인 다이얼로그("현재 기기의 데이터는
    유지되지 않습니다") 후 **동의해야만** `signInWithCredential`로 전환.
    묻지 않고 전환하는 코드 경로 없음.

### 검증
`flutter analyze`/`flutter test`(137개) 통과. 릴리스 APK 빌드 →
`adb install -r`로 설치.

### 실기기 관문 검증
- **관문 1(익명→연동, uid 유지) 통과** — 콘솔에서 제공업체가
  익명→Google로 바뀌고 uid `BDDOIl08…` 그대로, 계정 수 4개 유지(새 uid
  안 생김) 확인. 118벌 그대로 보임.
- **관문 2(삭제 후 재설치 → 같은 구글 계정 → 복원) 통과** — 앱 삭제 →
  `adb install`로 재설치 → 같은 구글 계정 로그인 → uid 복원, 옷장 확인됨.
  **지시서가 "이 단계의 전부"라고 명시한 관문이 실증됨.**
- 관문 3(`credential-already-in-use` 다이얼로그), 관문 4(미연동 사용자도
  정상 사용)는 이번 세션에 별도 재현 안 함 — 필요 시 다음 세션에서 확인.

## 3. 커밋/push

`177d7eb` — "feat: Google 계정 승격 (E단계) — link로 uid 보존, 재설치
복구 검증" (23개 파일, D+E단계 변경분 전부 포함). `git push` 완료
(`ee633a9..177d7eb`, `main` → `personal/main`).

## 다음에 할 일

1. **F단계(실사용자 배포) 아직 미착수** — App Distribution 테스터 등록,
   참가자 안내문/동의 절차, 집계 스크립트(`tools/user_study_report/`)
   전부 남아있음. D→E만 하고 F를 건너뛴 순서라, 지시서가 원래 의도한
   D→F→E 순서와 달라졌다는 점 인지하고 진행할 것.
2. E단계 관문 3(`credential-already-in-use`)·관문 4(미연동 사용자) 실기기
   재현 — 관문 3은 다른 익명 세션에서 같은 구글 계정으로 연동을 다시
   시도하면 재현 가능.
3. **uid가 바뀐 근본 원인 미조사** — `adb install -r`이 데이터를 보존하는
   게 정상인데 왜 세션이 끊겼는지 확인 안 됨. 재발하면 원인을 봐야 함
   (Firebase Auth 로컬 퍼시스턴스, 키스토어, 또는 다른 세션 이벤트 의심).
4. 이전 세션들에서 이월된 것들도 계속 미착수: CLIP 임베딩 RAG 통합(B단계),
   신규 옷 등록 서버사이드 임베딩 경로, 배경제거 TFLite 교체 스파이크,
   personal Firebase App Check 활성화, iOS 실기기 테스트.

## 참고 파일 위치

- 다중 사용자 격리 지시서: `docs/task_multi_user.md`
- 백필 도구: `tools/backfill_owner_uid/`(`backfill.py`, `README.md`)
- 옷장 모델/서비스: `lib/models/wardrobe_item.dart`,
  `lib/services/firestore_service.dart`(`wardrobeStream`, `addWardrobeItem`)
- 구글 인증 공통 로직: `lib/services/google_auth_service.dart`
- 로그인/설정 화면: `lib/screens/login_screen.dart`,
  `lib/screens/settings_screen.dart`(`_linkGoogleAccount`,
  `_handleCredentialAlreadyInUse`)
- Firestore 인덱스/규칙: `firestore.indexes.json`, `firestore.rules`
