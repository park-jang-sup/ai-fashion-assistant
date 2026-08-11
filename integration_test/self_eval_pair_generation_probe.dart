// docs/task_selfeval_validity_v1.md §7 - 3단계 쌍 생성용 하네스.
//
// 목적: 현재 옷장의 실재 아이템으로 조합을 새로 만들고, 그 조합을
// OutfitSelfEvaluator.run()으로 채점해 총점·축 3종·응답 모델을 얻는다.
// analyzeOutfitFromAttributes를 재구현하지 않고 실제 앱이 쓰는 진입점
// (OutfitSelfEvaluator.run, enableRepair=false, 이력 없음 - §7-C가
// agent_planner.dart:859 경로와 같은 조건으로 못박은 것)을 그대로
// 호출한다.
//
// 실행: 연결된 실기기에 이미 로그인된 세션이 있어야 한다(main.dart와
// 같은 FirebaseAuth 지속성에 의존 - 이 파일이 별도로 로그인하지
// 않는다). 결과는 Firestore에 쓰지 않고 표준 출력에만 남긴다
// (`[HARNESS_RESULT] {...}` 줄 하나당 조합 하나) - 실사용 데이터와
// 섞이지 않게 하기 위해서다(§6-가 설계).
//
// 실행 명령 예:
//   flutter test integration_test/self_eval_pair_generation_probe.dart -d <deviceId>

import 'dart:convert';
import 'dart:math';

import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:ai_fashion_assistant/firebase_options.dart';
import 'package:ai_fashion_assistant/services/firestore_service.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';
import 'package:ai_fashion_assistant/services/outfit_self_evaluator.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// §7-D 사전 등록 규칙 - 결과를 보기 전에 고정.
const int _kRandomComboCount = 20; // 무작위 조합
const int _kExtremeComboCount = 20; // 격식 극단 조합
const int _kRandomSeed = 20260811;

// 결과 한 줄 = 조합 하나. 나중에 `[HARNESS_RESULT] ` 접두어로 grep해
// JSON만 뽑아낸다.
void _printResult(Map<String, dynamic> data) {
  // ignore: avoid_print
  print('[HARNESS_RESULT] ${jsonEncode(data)}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('self-eval 조합 생성 + 채점 하네스', (tester) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    final uid = FirebaseAuth.instance.currentUser?.uid;
    // ignore: avoid_print
    print('[HARNESS] 로그인 uid: $uid');
    expect(uid, isNotNull, reason: '기기에 로그인된 세션이 필요합니다(main.dart와 같은 지속성 의존).');

    final wardrobe = await FirestoreService.wardrobeStream(uid!).first;
    final withAttrs = wardrobe.where((i) => i.attributes != null).toList();
    // ignore: avoid_print
    print('[HARNESS] 옷장 전체 ${wardrobe.length}벌, 속성 보유 ${withAttrs.length}벌');

    final byCategory = <String, List<WardrobeItem>>{};
    for (final item in withAttrs) {
      byCategory.putIfAbsent(item.category, () => []).add(item);
    }
    // ignore: avoid_print
    print('[HARNESS] 카테고리별 보유 수: '
        '${byCategory.map((k, v) => MapEntry(k, v.length))}');

    final rng = Random(_kRandomSeed);
    final combos = <List<WardrobeItem>>[];
    final comboKinds = <String>[]; // combos와 같은 인덱스 - "random" | "extreme"

    WardrobeItem? pickRandom(String category) {
      final pool = byCategory[category];
      if (pool == null || pool.isEmpty) return null;
      return pool[rng.nextInt(pool.length)];
    }

    // ── 무작위 조합 ──────────────────────────────────────────
    for (var i = 0; i < _kRandomComboCount; i++) {
      final combo = <WardrobeItem>[];
      for (final cat in ['상의', '하의', '신발']) {
        final item = pickRandom(cat);
        if (item != null) combo.add(item);
      }
      if (rng.nextBool()) {
        final item = pickRandom('아우터');
        if (item != null) combo.add(item);
      }
      if (rng.nextBool()) {
        final item = pickRandom('액세서리');
        if (item != null) combo.add(item);
      }
      if (combo.length >= 3) {
        combos.add(combo);
        comboKinds.add('random');
      }
    }

    // ── 격식 극단 조합 ──────────────────────────────────────
    // OutfitMatcher.formalityRankOf - 이미 코드에 있는 결정론적 함수.
    // Gemini도 사람도 아니다(§7-D "순환을 피하는 이유").
    final tops = byCategory['상의'];
    final bottoms = byCategory['하의'];
    final shoesPool = byCategory['신발'];
    if (tops != null && bottoms != null && shoesPool != null &&
        tops.isNotEmpty && bottoms.isNotEmpty && shoesPool.isNotEmpty) {
      final sortedTops = [...tops]
        ..sort((a, b) => OutfitMatcher.formalityRankOf(a.attributes!.formality)
            .compareTo(OutfitMatcher.formalityRankOf(b.attributes!.formality)));
      final sortedBottoms = [...bottoms]
        ..sort((a, b) => OutfitMatcher.formalityRankOf(a.attributes!.formality)
            .compareTo(OutfitMatcher.formalityRankOf(b.attributes!.formality)));
      for (var i = 0; i < _kExtremeComboCount; i++) {
        final useHighTop = i.isEven; // 상의 고격식+하의 저격식 / 그 반대를 번갈아
        final top = useHighTop ? sortedTops.last : sortedTops.first;
        final bottom = useHighTop ? sortedBottoms.first : sortedBottoms.last;
        final combo = <WardrobeItem>[top, bottom, shoesPool[rng.nextInt(shoesPool.length)]];
        if (rng.nextBool()) {
          final item = pickRandom('아우터');
          if (item != null) combo.add(item);
        }
        combos.add(combo);
        comboKinds.add('extreme');
      }
    } else {
      // ignore: avoid_print
      print('[HARNESS] 격식 극단 조합 생략 - 상의/하의/신발 중 재고가 빈 카테고리 있음');
    }

    // ignore: avoid_print
    print('[HARNESS] 생성된 조합 수: ${combos.length} '
        '(random=${comboKinds.where((k) => k == 'random').length}, '
        'extreme=${comboKinds.where((k) => k == 'extreme').length})');

    // ── 채점 ── OutfitSelfEvaluator.run()을 그대로 호출한다.
    // enableRepair=false, recentHistoryText 없음(§7-C) - 후보 1개짜리
    // 리스트로 넘겨 그 후보 자체의 총점·축·모델만 얻는다(수리 로직은
    // 타지 않는다 - candidates가 1개면 최초 평가가 곧 최종 결과).
    for (var i = 0; i < combos.length; i++) {
      final combo = combos[i];
      final match = OutfitMatch(combo);
      try {
        final outcome = await OutfitSelfEvaluator.run([match]);
        if (outcome == null) {
          _printResult({
            'index': i,
            'kind': comboKinds[i],
            'itemIds': combo.map((it) => it.id).toList(),
            'error': 'outcome-null(모든 후보 평가 실패)',
          });
          continue;
        }
        _printResult({
          'index': i,
          'kind': comboKinds[i],
          'itemIds': combo.map((it) => it.id).toList(),
          'itemSummaries': combo
              .map((it) => '${it.category}: ${it.attributes!.toPromptLine()}')
              .toList(),
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
        _printResult({
          'index': i,
          'kind': comboKinds[i],
          'itemIds': combo.map((it) => it.id).toList(),
          'error': e.toString(),
        });
      }
    }

    // ignore: avoid_print
    print('[HARNESS] 완료');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
