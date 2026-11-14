// 추천 카드 후보에 오늘 날씨 — docs/task_demo_flow_v1.md §10-1 판정 기준 (가)~(라), 데모 옷장.
// DEMO_TABLE=1이면 바꾸기 전·후 후보 8벌 표를 출력한다.
import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/style_recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'style_candidates_weather_check.dart';

List<WardrobeItem> _loadDemo() {
  final raw = jsonDecode(File('test/data/demo_wardrobe_attrs.json').readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final m in (raw['items'] as List).cast<Map<String, dynamic>>())
      WardrobeItem(
        id: m['id'] as String,
        imageUrl: '',
        category: m['category'] as String,
        subCategory: m['subCategory'] as String?,
        createdAt: DateTime(2026),
        attributes: ClothingAttributes.fromJson(m['attributes'] as Map<String, dynamic>),
      ),
  ];
}

void main() {
  final demo = _loadDemo();
  test('데모 옷장 — (가)~(라)', () {
    checkStyleCandidates('데모', demo, printTable: Platform.environment['DEMO_TABLE'] == '1');
  });
  test('날씨를 써서 골랐을 때만 안내 문구', () {
    expect(weatherPickNote(16.4), '오늘 날씨(최고 16°C)에 맞는 옷 위주로 골랐어요');
    expect(StyleCandidateSet.empty.weatherMaxTempC, isNull);
  });
  test('더움·온화(일교차 없음)에는 아우터 후보를 내지 않는다, 최저 10°C 미만이면 낸다', () {
    final board = styleBoards(demo).first.$2;
    for (final (mx, mn, expectOuter) in [(31.0, 24.0, false), (22.0, 14.0, false), (22.0, 7.0, true)]) {
      final r = matchStyleCandidates(selected: board, wardrobe: demo, maxItems: 8, weather: styleDay(mx, mn));
      expect(r.any((c) => c.item.category == '아우터'), expectOuter, reason: '$mx/$mn');
    }
  });
}
