// preview_outfit 확장과 옷 번호(docs/task_agent_ask_v2.md §2-C).
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

WeatherSnapshot _hot() => WeatherSnapshot(
      current: const CurrentWeather(tempC: 28, weatherCode: 0),
      daily: [
        for (var i = 0; i < 7; i++)
          DailyWeather(date: askToday.add(Duration(days: i)), maxTempC: 29, minTempC: 22, precipitationProbability: 0),
      ],
    );

Future<(AskTools, int Function(String id))> _tools({WeatherSnapshot? snap}) async {
  final t = askTools(FakeAskData(snap: snap ?? askSnapshot()));
  await t.searchWardrobe({}); // 옷장을 한 번 읽어 번호를 매긴다
  return (t, (String id) => t.book.numberOf(askWardrobe.firstWhere((i) => i.id == id)));
}

Set<String> _ids(List items) => {for (final i in items) i.id as String};

void main() {
  test('옷 번호 — 같은 옷장이면 늘 같은 번호, 결과의 옷 앞에 #번호', () async {
    final (a, numA) = await _tools();
    final (b, numB) = await _tools();
    for (final i in askWardrobe) {
      expect(numA(i.id), numB(i.id));
    }
    final r = await a.previewOutfit({'date': '2026-11-17', 'tpo': '일상'});
    expect(RegExp(r'#\d+ 상의').hasMatch(r.observation), isTrue);
    expect(b.book.item(numB('o1'))!.id, 'o1');
  });

  test('count — 앞 조합의 상의·아우터를 빼고 다시, 만들 수 있는 만큼만', () async {
    final (t, _) = await _tools();
    final r = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'count': 5});
    expect(r.combos.length, 2); // 상의가 2벌뿐
    expect(r.observation, contains('요청 5개 중 2개'));
    expect(r.observation, contains('조합 1: '));
    expect(r.observation, contains('조합 2: '));
    final tops = [for (final c in r.combos) c.firstWhere((i) => i.category == '상의').id];
    expect(tops.toSet().length, 2);
    expect(r.items, r.combos.first);
    expect(r.display, '11/16(월) [일상] 코디 2가지');
  });

  test('style — 태그에 그 글자가 든 옷이 있는 종류만 좁히고 결과에 적는다', () async {
    final (t, _) = await _tools();
    final r = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'style': '데님'});
    expect(r.observation, contains("스타일 '데님'로 좁힘: 하의 1벌"));
    expect(_ids(r.items), contains('p2'));
    final none = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'style': '레이스'});
    expect(none.observation, contains("스타일 '레이스': 태그가 맞는 옷이 없어 좁히지 않았어요"));
  });

  test('keep·exclude — 고정한 옷은 기온대 규칙으로 빼지 않는다(더운 날의 아우터도)', () async {
    final (t, num) = await _tools(snap: _hot());
    final plain = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상'});
    expect(plain.items.any((i) => i.category == '아우터'), isFalse); // 더움: 아우터 없음
    final kept = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'keep': [num('o1')]});
    expect(_ids(kept.items), contains('o1'));
    final ex = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'exclude': ['#${num('t1')}']});
    expect(_ids(ex.items), isNot(contains('t1')));
    expect(_ids(ex.items), contains('t2'));
  });

  test('adjust — 기온대를 한 단계 옮겨 고르고 결과에 적는다', () async {
    final (t, _) = await _tools();
    final w = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'adjust': '더 따뜻하게'});
    expect(w.observation, contains('더 따뜻하게: 선선 → 추움 기준으로 골랐어요'));
    final l = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'adjust': '더 가볍게'});
    expect(l.observation, contains('더 가볍게: 선선 → 온화 기준으로 골랐어요'));
  });

  test('검증 — 보여 준 적 없는 번호, count 범위, adjust 값', () async {
    final (t, num) = await _tools();
    Map<String, dynamic> pv(Map<String, dynamic> extra) =>
        {'thought': 't', 'action': 'preview_outfit', 'args': {'date': '2026-11-16', 'tpo': '일상', ...extra}};
    expect(validateAskReply(pv({'keep': [num('o1')]}), knownItem: t.book.has), isNull);
    expect(validateAskReply(pv({'exclude': [99]}), knownItem: t.book.has), '출력 오류: 이 대화에서 보여 준 적 없는 옷 번호예요(#99)');
    expect(validateAskReply(pv({'count': 7})), startsWith('출력 오류: count는'));
    expect(validateAskReply(pv({'adjust': '더 춥게'})), startsWith('출력 오류: adjust는'));
    expect(validateAskReply(pv({'keep': 'o1'})), startsWith('출력 오류: keep는'));
  });
}
