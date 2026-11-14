// 추천 카드 후보에 오늘 날씨(docs/task_demo_flow_v1.md §10-1) — 판정 기준 (가)~(라).
// 데모 옷장 테스트(style_candidates_weather_test.dart)와 실기기 옷장 점검
// (real_wardrobe_weather_check_test.dart)이 같이 쓰는 도우미라 이름이 _test.dart가 아니다.
// ignore_for_file: avoid_print
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/style_recommendations.dart';
import 'package:ai_fashion_assistant/services/weather_fit.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

String styleDesc(WardrobeItem i) => '${i.category} ${i.attributes!.color} ${i.attributes!.tags.take(3).join('·')}';

WardrobeItem findItem(List<WardrobeItem> w, String category, String color, String tag) => w.firstWhere(
    (i) => i.category == category && i.attributes?.color == color && i.attributes!.tags.contains(tag));

// 코디보드 조합 둘 — 캐주얼(맨투맨 + 데님 와이드), 세미포멀(반팔 카라티 + 와이드 슬랙스 + 블레이저).
List<(String, List<WardrobeItem>)> styleBoards(List<WardrobeItem> w) => [
      ('캐주얼 보드', [findItem(w, '상의', '블랙', '맨투맨'), findItem(w, '하의', '블랙', '턱팬츠')]),
      (
        '세미포멀 보드',
        [findItem(w, '상의', '블랙', '카라티'), findItem(w, '하의', '블랙', '벨티드'), findItem(w, '아우터', '블랙', '블레이저')]
      ),
    ];

DailyWeather styleDay(double mx, double mn) =>
    DailyWeather(date: DateTime(2026, 11, 15), maxTempC: mx, minTempC: mn, precipitationProbability: 10);

// 날씨에 맞는 옷인가 — 일일 추천 규칙에서 빼는 대상도 감점 대상도 아닌 옷.
bool styleFits(WardrobeItem i, List<WardrobeItem> wardrobe, WeatherContext ctx) =>
    !filterWardrobeForBand(wardrobe, ctx).removedIds.contains(i.id) && !isWeatherPenaltyTarget(i, ctx);

void checkStyleCandidates(String label, List<WardrobeItem> wardrobe, {bool printTable = false}) {
  for (final (board, selected) in styleBoards(wardrobe)) {
    final before = matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: analysisCandidateCount);
    // (다) 예보가 없으면 예전과 같다 — weather: null은 인자 없이 부른 예전 경로 그대로.
    final beforeNull =
        matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: analysisCandidateCount, weather: null);
    expect([for (final c in beforeNull) c.item.id], [for (final c in before) c.item.id], reason: '$label $board (다)');
    for (final (dl, mx, mn) in [('16/7', 16.0, 7.0), ('3/−3', 3.0, -3.0)]) {
      final day = styleDay(mx, mn);
      final ctx = weatherContextFor(day, wardrobe: wardrobe)!;
      final after =
          matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: analysisCandidateCount, weather: day);
      if (printTable) {
        String cell(List<StyleCandidate> l, int i) {
          if (i >= l.length) return '—';
          final it = l[i].item;
          return '${styleDesc(it)} ${styleFits(it, wardrobe, ctx) ? '○' : '✗'}';
        }
        for (var i = 0; i < analysisCandidateCount; i++) {
          print('STYLE|$label|$board|$dl|${i + 1}|${cell(before, i)}|${cell(after, i)}');
        }
      }
      expect(after.length, analysisCandidateCount, reason: '$label $board $dl');
      // (가) 대안이 있으면 반바지 계열·샌들 없음.
      final hasLongBottom = wardrobe.any((i) => i.category == '하의' && i.attributes != null && !isShorts(i));
      final hasOtherShoes = wardrobe.any((i) => i.category == '신발' && i.attributes != null && !isSandal(i));
      if (hasLongBottom) expect(after.any((c) => isShorts(c.item)), isFalse, reason: '$label $board $dl (가) 반바지');
      if (hasOtherShoes) expect(after.any((c) => isSandal(c.item)), isFalse, reason: '$label $board $dl (가) 샌들');
      // (나) 날씨에 맞는 옷이 2벌 이상인 종류는 그 종류의 후보가 모두 날씨에 맞는 옷.
      final ids = {for (final s in selected) s.id};
      for (final cat in ['상의', '하의', '아우터', '신발', '액세서리']) {
        final good = wardrobe.where(
            (i) => i.category == cat && i.attributes != null && !ids.contains(i.id) && styleFits(i, wardrobe, ctx));
        if (good.length < 2) continue;
        for (final c in after.where((c) => c.item.category == cat)) {
          expect(styleFits(c.item, wardrobe, ctx), isTrue, reason: '$label $board $dl (나) ${styleDesc(c.item)}');
        }
      }
      // (라) 같은 입력이면 같은 결과 — 옷장 조회 순서가 달라도.
      final again = matchStyleCandidates(
          selected: selected, wardrobe: wardrobe.reversed.toList(), maxItems: analysisCandidateCount, weather: day);
      expect([for (final c in again) c.item.id], [for (final c in after) c.item.id], reason: '$label $board $dl (라)');
    }
  }
}
