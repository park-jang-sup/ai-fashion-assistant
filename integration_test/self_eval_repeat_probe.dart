// docs/task_selfeval_validity_v1.md §6-가 - 반복 일관성(신뢰도) 측정
// 하네스.
//
// 목적: 고정된 조합 하나(§6-가가 등록한 "임계값 근방" 기준으로 고른
// 실제 아이템 조합, 원 점수 70 - 아래 참고)를
// OutfitSelfEvaluator.run()으로 20회 반복 평가해 총점의 변동 폭을
// 잰다. self_eval_pair_generation_probe.dart와 같은 진입점을
// 재구현 없이 그대로 호출하며(§7-C가 못박은 것과 같은 원칙), 조합은
// 매회 동일하다.
//
// 조합 선정 근거(결과를 보기 전에 고정): §7 15쌍 답안지
// (tools/eval_harness_selfeval/answer_key/pairs_answer_key.json)에
// 이미 전체 아이템 구성이 기록된 조합 중 점수가 66~74 범위인 것을
// 후보로 하고, 70과의 거리가 가장 가까운 것을 고르고(동률이면 pairId
// 사전순), 실행 전 4개 아이템의 현재 옷장 생존을 확인했다. 결과:
// p007 왼쪽 조합(원 점수 70, kind=extreme).
//
// [설계 변경, §6-가 실행 시도 7 이후] 기존에는 실기기에 이미
// 로그인된 세션에 의존해 FirestoreService.wardrobeStream(uid)로
// 아이템을 조회했다 - `flutter test`가 매 실행마다 테스트 APK를
// install -r로 새로 깔고 끝나면 제거하는 수명주기 때문에(§6-가
// 실행 시도 1~7), 세션이 있어도 이 프로세스 안에서 관측되지 않는
// 문제를 겪었다(원인 미확정으로 남김). 재는 것("같은 조합을 반복
// 평가하면 점수가 얼마나 흔들리는가")에 사용자 인증이 본질적으로
// 필요하지 않다는 점에 착안해, 두 가지로 인증 의존을 없앤다:
//   1) 조합 자체를 옷장에서 조회하지 않고 답안지(위 참고)의 값을
//      그대로 하드코딩한다 - Firestore wardrobe 컬렉션은
//      `resource.data.ownerUid == request.auth.uid`로 소유자만
//      읽을 수 있어(firestore.rules), 새 계정으로는 애초에 조회할
//      수 없다.
//   2) `signInAnonymously()`로 이 실행 전용 익명 계정을 만든다 -
//      서버 프록시(`callGeminiText`)가 요구하는 것은 `request.auth`
//      존재뿐이며 소유권을 보지 않는다(`functions/src/index.ts`
//      확인). 익명 uid는 `rate_limit`이 0부터 시작하므로 기존 사용
//      량과도 섞이지 않는다(hardening 트랙 S4가 이미 "익명 uid 축은
//      열려 있다"로 등록해 둔 것과 같은 성질 - 여기서는 측정
//      목적으로 그 축을 1회성으로 쓴다).
//
// 실행: 로그인된 세션이 필요 없다 - 매 실행이 스스로 익명 계정을
// 만든다. 결과는 Firestore에 쓰지 않고 표준 출력에만 남긴다
// (`[REPEAT_RESULT] {...}` 줄 하나당 회차 하나).
//
// 실행 명령 예:
//   flutter test integration_test/self_eval_repeat_probe.dart -d <deviceId>

import 'dart:convert';

import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:ai_fashion_assistant/firebase_options.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';
import 'package:ai_fashion_assistant/services/outfit_self_evaluator.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';

// §6-가 사전 등록 - 결과를 보기 전에 고정.
const int _kRepeatCount = 20;

// tools/eval_harness_selfeval/answer_key/pairs_answer_key.json의 p007
// 왼쪽 조합을 그대로 옮긴 것 - 옷장 조회 없이 이 값만으로 조합을
// 구성한다(위 파일 헤더 설계 변경 1) 참고).
//
// [2026-08-12] 공개(밑줄 제거) - self_eval_model_fixed_probe.dart(§6-가
// 2차 측정)가 같은 조합을 재구성 없이 그대로 가져다 쓴다. 데이터를
// 두 곳에 따로 타이핑하면 나중에 한쪽만 고쳐 조합이 갈라질 위험이
// 있다 - 재구현 금지 원칙(§6-가 "하네스 위치 결정")을 조합 데이터에도
// 적용한다.
final List<WardrobeItem> kFixedCombo = [
  WardrobeItem(
    id: '6vVNoavk5DLduhTNKu0d',
    imageUrl: '',
    category: '상의',
    createdAt: DateTime(2026, 1, 1),
    attributes: const ClothingAttributes(
      color: '블랙',
      style: '미니멀',
      pattern: '무지',
      formality: '세미포멀',
      fit: '레귤러',
      tags: ['카라티', '니트', '반팔', '여름'],
    ),
  ),
  WardrobeItem(
    id: 'Q2TqinzkRVKNgDoQE5dp',
    imageUrl: '',
    category: '하의',
    createdAt: DateTime(2026, 1, 1),
    attributes: const ClothingAttributes(
      color: '블랙',
      style: '스포티',
      pattern: '무지',
      formality: '캐주얼',
      fit: '레귤러',
      tags: ['나일론', '여름', '숏팬츠', '밴딩'],
    ),
  ),
  WardrobeItem(
    id: 't16mhpuSrkQq4KvRxiqx',
    imageUrl: '',
    category: '신발',
    createdAt: DateTime(2026, 1, 1),
    attributes: const ClothingAttributes(
      color: '블랙',
      style: '캐주얼',
      pattern: '무지',
      formality: '캐주얼',
      fit: '레귤러',
      tags: ['가죽', '여름', '플랫폼', '샌들'],
    ),
  ),
  WardrobeItem(
    id: 'eX4cHUhrSMhv5GIGaB5Z',
    imageUrl: '',
    category: '아우터',
    createdAt: DateTime(2026, 1, 1),
    attributes: const ClothingAttributes(
      color: '베이지',
      style: '미니멀',
      pattern: '무지',
      formality: '캐주얼',
      fit: '오버사이즈',
      tags: ['스웨이드', '봄', '가을', '블루종'],
    ),
  ),
];

void _printResult(Map<String, dynamic> data) {
  // ignore: avoid_print
  print('[REPEAT_RESULT] ${jsonEncode(data)}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('self-eval 반복 일관성 하네스 (N=20, 고정 조합)', (tester) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    // 기존 세션에 의존하지 않는다 - 이 실행 전용 익명 계정을 새로
    // 만든다(위 파일 헤더 설계 변경 2) 참고). 서버 프록시는 이것으로
    // 충분하다.
    final cred = await FirebaseAuth.instance.signInAnonymously();
    final uid = cred.user?.uid;
    // ignore: avoid_print
    print('[REPEAT] 익명 로그인 uid: $uid');
    expect(uid, isNotNull, reason: 'signInAnonymously가 uid를 발급하지 못했습니다.');

    // ignore: avoid_print
    print('[REPEAT] 고정 조합(하드코딩): '
        '${kFixedCombo.map((it) => '${it.category}:${it.id}').toList()}');

    for (var i = 0; i < _kRepeatCount; i++) {
      final match = OutfitMatch(kFixedCombo);
      try {
        // enableRepair 기본값 false, recentHistoryText 기본값 없음 -
        // §6-가/A-3이 요구하는 조건 통제를 인자를 안 주는 것으로 그대로
        // 만족한다(self_eval_pair_generation_probe.dart와 동일 패턴).
        final outcome = await OutfitSelfEvaluator.run([match]);
        if (outcome == null) {
          _printResult({'trial': i, 'error': 'outcome-null(평가 실패)'});
          continue;
        }
        _printResult({
          'trial': i,
          'score': outcome.bestScore,
          'formality': outcome.candidateFormalityScores.isNotEmpty
              ? outcome.candidateFormalityScores.first
              : null,
          'colorHarmony': outcome.candidateColorHarmonyScores.isNotEmpty
              ? outcome.candidateColorHarmonyScores.first
              : null,
          'style': outcome.candidateStyleScores.isNotEmpty
              ? outcome.candidateStyleScores.first
              : null,
          'model': outcome.candidateModels.isNotEmpty ? outcome.candidateModels.first : null,
        });
      } catch (e) {
        _printResult({'trial': i, 'error': e.toString()});
      }
    }

    // ignore: avoid_print
    print('[REPEAT] 완료');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
