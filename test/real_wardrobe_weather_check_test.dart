// 실기기 옷장 속성으로 기온대 규칙 점검 — docs/task_demo_flow_v1.md §2-8 (사)·(아).
// 옷장 속성은 저장소에 두지 않는다(실제 사용자 옷 id). Firestore에서 읽기 전용으로 받은
// JSON 경로를 넘길 때만 돈다 — 평소 `flutter test`에서는 건너뛴다:
//   REAL_WARDROBE_JSON=<경로> flutter test test/real_wardrobe_weather_check_test.dart
// JSON 형식: [{id, category, subCategory, attributes:{color,style,pattern,formality,fit,tags}}]
// 이 점검은 최근 착용 감점(이력)을 넣지 않은 matchForWeather 1순위다.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:ai_fashion_assistant/services/weather_fit.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'style_candidates_weather_check.dart';

void main() {
  final path = Platform.environment['REAL_WARDROBE_JSON'];
  test('실기기 옷장 점검 (사)·(아)', () {
    if (path == null) {
      markTestSkipped('REAL_WARDROBE_JSON 경로를 넘길 때만 돈다');
      return;
    }
    final raw = (jsonDecode(File(path).readAsStringSync()) as List).cast<Map<String, dynamic>>();
    final wardrobe = [
      for (final m in raw)
        if (m['attributes'] != null)
          WardrobeItem(
            id: m['id'] as String,
            imageUrl: '',
            category: m['category'] as String,
            subCategory: m['subCategory'] as String?,
            createdAt: DateTime(2026),
            attributes: ClothingAttributes.fromJson(m['attributes'] as Map<String, dynamic>),
          ),
    ];
    String desc(WardrobeItem? i) =>
        i == null ? '—' : '${i.attributes!.color} ${i.attributes!.tags.take(3).join('·')}(${i.attributes!.formality})';
    WardrobeItem? cat(List<WardrobeItem> items, String c) => items.where((i) => i.category == c).firstOrNull;
    DailyWeather day(double mx, double mn) =>
        DailyWeather(date: DateTime(2026, 11, 15), maxTempC: mx, minTempC: mn, precipitationProbability: 10);

    // (사) [모임] 선선·추움 아우터.
    final outers = <String, WardrobeItem?>{};
    for (final (label, mx, mn) in [('더움 31/24', 31.0, 24.0), ('온화 22/14', 22.0, 14.0), ('선선 14/8', 14.0, 8.0), ('추움 3/−3', 3.0, -3.0), ('실제 16/7', 16.0, 7.0)]) {
      final d = day(mx, mn);
      final m = AgentPlanner.matchForWeather(wardrobe: wardrobe, formalityHint: '세미포멀', day: d);
      final top = m.match.candidates.first.items;
      final note = buildWeatherNote(
        ctx: weatherContextFor(d),
        baselineTop: m.baseline!.candidates.first.items,
        weatherTop: top,
        finalItems: top,
        wardrobe: wardrobe,
        removedIds: (m.fellBack || m.formalityOverride) ? const {} : m.filter!.removedIds,
        formalityHint: '세미포멀',
        coldOuterRuleApplied: !m.fellBack && !m.formalityOverride && m.filter!.coldOuterRuleApplied,
      );
      outers[label] = cat(top, '아우터');
      print('ROW|모임 $label|${desc(cat(top, '상의'))}|${desc(cat(top, '하의'))}|${desc(cat(top, '아우터'))}|'
          '${desc(cat(top, '신발'))}|$note');
      if (label.startsWith('선선') || label.startsWith('추움') || label.startsWith('실제')) {
        expect(isShorts(cat(top, '하의')!), isFalse, reason: label);
      }
    }
    expect(desc(outers['선선 14/8']), '블랙 블레이저·봄가을·아우터(세미포멀)');
    expect(isHeavyOuter(outers['추움 3/−3']!), isTrue);

    // (아) 한겨울용 태그가 붙은 후드 아우터를 새 옷으로 — 16/7·3/−3 예보에서 반바지 계열
    // 하의가 없다. 그런 옷이 없는 옷장에서는 이 점검만 건너뛴다.
    final hood = wardrobe.where((i) =>
        i.category == '아우터' && isHeavyOuter(i) && i.attributes!.tags.contains('후드')).firstOrNull;
    if (hood == null) print('NEW|한겨울용 후드 아우터 없음 — (아) 건너뜀');
    if (hood != null) {
      final noWeather = AgentPlanner.newItemCandidatesForWeather(newItem: hood, existingItems: wardrobe);
      print('NEW|예보 없음|${noWeather.map((c) => c.items.map(desc).join(' + ')).join('  //  ')}');
      for (final (label, mx, mn) in [('16/7', 16.0, 7.0), ('3/−3', 3.0, -3.0)]) {
        final c = AgentPlanner.newItemCandidatesForWeather(newItem: hood, existingItems: wardrobe, today: day(mx, mn));
        print('NEW|$label|${c.map((m) => m.items.map(desc).join(' + ')).join('  //  ')}');
        expect(c, isNotEmpty, reason: label);
        for (final m in c) {
          expect(m.items.where((i) => i.category == '하의').any(isShorts), isFalse, reason: label);
        }
      }
    }

    // §10-1 추천 카드 후보 — (가)~(라), 바꾸기 전·후 표.
    checkStyleCandidates('실기기', wardrobe, printTable: true);
  });
}
