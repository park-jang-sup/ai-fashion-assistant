// docs/task_selfeval_validity_v1.md §6-가 - 반복 일관성(신뢰도) 측정
// 하네스.
//
// 목적: 고정된 조합 하나(§6-가가 등록한 "임계값 근방" 기준으로 고른
// 실제 아이템 조합, 원 점수 70 - 다음 문단 참고)를
// OutfitSelfEvaluator.run()으로 20회 반복 평가해 총점의 변동 폭을
// 잰다. self_eval_pair_generation_probe.dart와 같은 진입점을
// 재구현 없이 그대로 호출하며(§7-C가 못박은 것과 같은 원칙), 조합은
// 매회 동일하다(생성하지 않고 고정 itemIds로 조회한다).
//
// 조합 선정 근거(결과를 보기 전에 고정): §7 15쌍 답안지
// (tools/eval_harness_selfeval/answer_key/pairs_answer_key.json)에
// 이미 전체 아이템 구성이 기록된 조합 중 점수가 66~74 범위인 것을
// 후보로 하고(원 40개 하네스 전체가 아니라 답안지에 itemIds까지
// 남아있는 것만 - §6-나2 실행 시점의 문서 참고), 70과의 거리가 가장
// 가까운 것을 고르고(동률이면 pairId 사전순), 실행 전 4개 아이템의
// 현재 옷장 생존을 확인했다. 결과: p007 왼쪽 조합
// (6vVNoavk5DLduhTNKu0d/Q2TqinzkRVKNgDoQE5dp/t16mhpuSrkQq4KvRxiqx/
// eX4cHUhrSMhv5GIGaB5Z, 원 점수 70, kind=extreme).
//
// 실행: 연결된 실기기에 이미 로그인된 세션이 있어야 한다(다른
// integration_test 하네스와 동일한 전제). 결과는 Firestore에 쓰지
// 않고 표준 출력에만 남긴다(`[REPEAT_RESULT] {...}` 줄 하나당 회차
// 하나).
//
// 실행 명령 예:
//   flutter test integration_test/self_eval_repeat_probe.dart -d <deviceId>

import 'dart:convert';

import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:ai_fashion_assistant/firebase_options.dart';
import 'package:ai_fashion_assistant/services/firestore_service.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';
import 'package:ai_fashion_assistant/services/outfit_self_evaluator.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// §6-가 사전 등록 - 결과를 보기 전에 고정.
const int _kRepeatCount = 20;
const List<String> _kFixedComboItemIds = [
  '6vVNoavk5DLduhTNKu0d',
  'Q2TqinzkRVKNgDoQE5dp',
  't16mhpuSrkQq4KvRxiqx',
  'eX4cHUhrSMhv5GIGaB5Z',
];

void _printResult(Map<String, dynamic> data) {
  // ignore: avoid_print
  print('[REPEAT_RESULT] ${jsonEncode(data)}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('self-eval 반복 일관성 하네스 (N=20, 고정 조합)', (tester) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    final uid = FirebaseAuth.instance.currentUser?.uid;
    // ignore: avoid_print
    print('[REPEAT] 로그인 uid: $uid');
    expect(uid, isNotNull, reason: '기기에 로그인된 세션이 필요합니다(main.dart와 같은 지속성 의존).');

    final wardrobe = await FirestoreService.wardrobeStream(uid!).first;
    final byId = {for (final it in wardrobe) it.id: it};

    final combo = <WardrobeItem>[];
    for (final id in _kFixedComboItemIds) {
      final item = byId[id];
      if (item == null) {
        // ignore: avoid_print
        print('[REPEAT] 아이템 소실: $id - 실행 중단');
        return;
      }
      combo.add(item);
    }
    // ignore: avoid_print
    print('[REPEAT] 고정 조합 확인: '
        '${combo.map((it) => '${it.category}:${it.id}').toList()}');

    for (var i = 0; i < _kRepeatCount; i++) {
      final match = OutfitMatch(combo);
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
