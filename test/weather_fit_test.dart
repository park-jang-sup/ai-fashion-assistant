// 날씨를 실제 선택에 반영 — docs/task_agent_grounding_v1.md 부분 C,
// 기온대 구성 — docs/task_demo_flow_v1.md 부분 A와 §2-5 보완.
import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';
import 'package:ai_fashion_assistant/services/weather_fit.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

WardrobeItem _w(String id, String category,
        {String color = '블랙', String formality = '캐주얼', List<String> tags = const [], String? sub}) =>
    WardrobeItem(
      id: id,
      imageUrl: '',
      category: category,
      subCategory: sub,
      createdAt: DateTime(2026),
      attributes: ClothingAttributes(
          color: color, style: '캐주얼', pattern: '무지', formality: formality, fit: '레귤러', tags: tags),
    );

DailyWeather _day({double max = 18, double min = 12, int rain = 0}) =>
    DailyWeather(date: DateTime(2026, 11, 20), maxTempC: max, minTempC: min, precipitationProbability: rain);

WeatherContext _ctx({double max = 18, double min = 12, int rain = 0}) =>
    weatherContextFor(_day(max: max, min: min, rain: rain))!;

List<List<String>> _ids(TpoMatchResult r) => [for (final c in r.candidates) [for (final i in c.items) i.id]];

// 2026-11-14 실기기 확인에서 채택된 옷과 같은 종류·색·태그(공개 데모 세트 demo_wardrobe에 있는 옷).
final _realTops = [
  _w('top_gray', '상의', color: '그레이', formality: '세미포멀', tags: ['니트', '카라티', '여름', '반소매']),
  _w('top_black', '상의', color: '블랙', formality: '세미포멀', tags: ['카라티', '니트', '반팔', '여름']),
  _w('top_white', '상의', color: '화이트', formality: '세미포멀', tags: ['반팔셔츠', '여름', '포켓', '코튼']),
];
// 긴팔 3벌(다양성 하한을 넘김) — 맨투맨, 가을겨울 니트(§2-5-5로 긴팔), 가을/겨울 셔츠.
final _longTops = [
  _w('mtm', '상의', color: '블랙', tags: ['맨투맨', '스포티', '코튼', '봄가을']),
  _w('knitFW', '상의', color: '차콜', formality: '세미포멀', tags: ['니트', '가을겨울']),
  _w('shirtFW', '상의', color: '네이비', formality: '세미포멀', tags: ['셔츠', '옥스포드', '가을/겨울']),
];
// 소매를 말하는 태그도 가을·겨울 계절 태그도 없는 상의.
final _unknownTop = _w('knitSS', '상의', color: '블랙', tags: ['니트', '봄가을']);
final _bottoms = [
  _w('pants_charcoal', '하의', color: '차콜', formality: '세미포멀', tags: ['와이드팬츠', '핀턱', '슬랙스', '가을/겨울']),
  _w('pants_black', '하의', color: '블랙', formality: '세미포멀', tags: ['슬랙스', '와이드팬츠', '사계절', '핀턱']),
];
final _blazer = _w('blazer', '아우터', color: '블랙', formality: '세미포멀', tags: ['블레이저', '봄가을', '아우터', '데일리룩']);
final _windbreaker = _w('wind', '아우터', color: '블랙', tags: ['바람막이', '나일론', '간절기', '집업']);
final _heavyOuter = _w('pad', '아우터', color: '블랙', tags: ['후드', '캔버스', '겨울', '양털안감']);
final _shoes = [_w('sneakers', '신발', color: '블랙', tags: ['스니커즈', '가죽', '사계절', '클래식'])];
// [모임](세미포멀) 옷장 — 긴팔이 충분한(3벌) 조건.
final _meeting = [..._realTops, ..._longTops, _unknownTop, ..._bottoms, _blazer, _windbreaker, ..._shoes];

// 데모 옷장(demo_wardrobe 112벌의 매칭 속성, 2026-11-14 읽기 전용 조사) — 긴팔 상의 1벌.
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

// 앱(agent_planner._prepareRecommendationFor)과 같은 선택 함수로 돌려 1순위와 문구를 낸다.
({List<WardrobeItem> top, String? note, TpoMatchResult match}) _plan(
    List<WardrobeItem> wardrobe, DailyWeather day, String formality) {
  final m = AgentPlanner.matchForWeather(wardrobe: wardrobe, formalityHint: formality, day: day);
  final top = m.match.candidates.first.items;
  final note = buildWeatherNote(
    ctx: weatherContextFor(day),
    baselineTop: m.baseline!.candidates.first.items,
    weatherTop: top,
    finalItems: top,
    wardrobe: wardrobe,
    removedIds: (m.fellBack || m.formalityOverride) ? const {} : m.filter!.removedIds,
    formalityHint: formality,
    coldOuterRuleApplied: !m.fellBack && !m.formalityOverride && m.filter!.coldOuterRuleApplied,
  );
  return (top: top, note: note, match: m.match);
}

WardrobeItem _topOf(List<WardrobeItem> items) => items.firstWhere((i) => i.category == '상의');

void main() {
  group('기온대 — 최고기온으로, 아우터는 선선·추움 또는 최저 10°C 미만', () {
    test('경계', () {
      expect(tempBandFor(25), TempBand.hot);
      expect(tempBandFor(24.9), TempBand.mild);
      expect(tempBandFor(18), TempBand.mild);
      expect(tempBandFor(17.9), TempBand.cool);
      expect(tempBandFor(10), TempBand.cool);
      expect(tempBandFor(9.9), TempBand.cold);
    });
    test('아우터', () {
      expect(needsOuterFor(TempBand.hot, 20), isFalse);
      expect(needsOuterFor(TempBand.mild, 10), isFalse);
      expect(needsOuterFor(TempBand.mild, 9.9), isTrue, reason: '일교차');
      expect(needsOuterFor(TempBand.hot, 8), isTrue, reason: '일교차');
      expect(needsOuterFor(TempBand.cool, 15), isTrue);
      expect(needsOuterFor(TempBand.cold, 0), isTrue);
    });
    test('비는 강수확률 임계 기준 그대로', () {
      expect(_ctx(rain: WeatherService.rainProbabilityThreshold).rain, isTrue);
      expect(_ctx(rain: WeatherService.rainProbabilityThreshold - 1).rain, isFalse);
    });
    test('예보 없음', () => expect(weatherContextFor(null), isNull));
  });

  group('소매 길이 — 태그로 확인되는 것만(§2-5-5 보강 포함)', () {
    test('반팔·긴팔·모름', () {
      expect(sleeveOf(_realTops[0]), Sleeve.short); // 반소매
      expect(sleeveOf(_realTops[2]), Sleeve.short); // 반팔셔츠
      expect(sleeveOf(_longTops[0]), Sleeve.long); // 맨투맨
      expect(sleeveOf(_longTops[1]), Sleeve.long); // 반팔 없음 + 가을겨울
      expect(sleeveOf(_longTops[2]), Sleeve.long); // 반팔 없음 + 가을/겨울
      expect(sleeveOf(_unknownTop), Sleeve.unknown); // 봄가을은 계절 보강 대상이 아니다
    });
    test('반팔 계열이 있으면 계절 태그와 무관하게 반팔', () {
      expect(sleeveOf(_w('x', '상의', tags: ['반팔', '겨울'])), Sleeve.short);
    });
  });

  group('매칭 대상에서 빼기 — 다양성 하한 3벌', () {
    test('더움: 아우터 전부, 긴팔 상의(반팔·모름이 3벌 이상 남을 때)', () {
      final r = filterWardrobeForBand(_meeting, _ctx(max: 31, min: 24));
      expect(r.removedIds, containsAll(['blazer', 'wind', 'mtm', 'knitFW', 'shirtFW']));
      expect(r.removedIds, isNot(contains('knitSS')));
    });
    test('온화: 아우터 전부, 반팔 상의 — 최저 10°C 미만이면 아우터는 남김', () {
      final r = filterWardrobeForBand(_meeting, _ctx(max: 22, min: 14));
      expect(r.removedIds, containsAll(['blazer', 'wind', 'top_gray', 'top_black', 'top_white']));
      final cold = filterWardrobeForBand(_meeting, _ctx(max: 22, min: 7));
      expect(cold.removedIds, isNot(contains('blazer')));
    });
    test('선선: 여름 계열 상의는 빼지 않는다(감점만), 하의·신발의 여름 계열은 뺀다', () {
      final shorts = [
        for (var i = 0; i < 3; i++) _w('pants$i', '하의', tags: ['슬랙스', '사계절']),
        _w('short', '하의', tags: ['반바지', '여름']),
      ];
      final r = filterWardrobeForBand([..._meeting, ...shorts], _ctx(max: 16, min: 7));
      expect(r.removedIds, isNot(contains('top_gray')));
      expect(r.removedIds, contains('short'));
      expect(isWeatherPenaltyTarget(_realTops[0], _ctx(max: 16, min: 7)), isTrue);
    });
    test('추움: 여름 계열 — 남는 옷이 3벌 이상일 때만', () {
      expect(filterWardrobeForBand(_meeting, _ctx(max: 3, min: -3)).removedIds,
          unorderedEquals(['top_gray', 'top_black', 'top_white']));
      final twoLong = [..._realTops, ..._longTops.take(2), ..._bottoms, _blazer];
      expect(filterWardrobeForBand(twoLong, _ctx(max: 3, min: -3)).removedIds, isEmpty);
    });
  });

  group('예보가 없으면 결과가 지금과 완전히 같다', () {
    final base = OutfitMatcher.findForTpo(wardrobe: _meeting, formalityHint: '세미포멀');
    test('weather: null', () {
      expect(_ids(OutfitMatcher.findForTpo(wardrobe: _meeting, formalityHint: '세미포멀', weather: null)), _ids(base));
      final m = AgentPlanner.matchForWeather(wardrobe: _meeting, formalityHint: '세미포멀');
      expect(_ids(m.match), _ids(base));
      expect(m.baseline, isNull);
    });
    test('정책 감점 0이면 예보가 있어도 정렬은 그대로(거르기는 호출부 몫)', () {
      expect(
          _ids(OutfitMatcher.findForTpo(
              wardrobe: _meeting,
              formalityHint: '세미포멀',
              weather: _day(max: 31, min: 24, rain: 90),
              policy: const TpoMatchPolicy(weatherPenalty: 0))),
          _ids(base));
    });
    test('날씨 문구 없음', () {
      expect(
          buildWeatherNote(ctx: null, baselineTop: _shoes, weatherTop: _shoes, finalItems: _shoes, wardrobe: _meeting),
          isNull);
    });
  });

  group('2026-11-14 사례 재현', () {
    test('기준선 — 날씨 없이는 블레이저와 반팔·여름 상의가 1순위에 든다(그때와 같음)', () {
      final top = OutfitMatcher.findForTpo(wardrobe: _meeting, formalityHint: '세미포멀').candidates.first.items;
      expect(top.map((i) => i.id), contains('blazer'));
      expect(isSummerItem(_topOf(top)), isTrue);
    });
    test('31°C: 블레이저가 빠지고 문구가 조합과 어긋나지 않는다', () {
      final p = _plan(_meeting, _day(max: 31, min: 24), '세미포멀');
      expect(p.top.where((i) => i.category == '아우터'), isEmpty);
      expect(sleeveOf(_topOf(p.top)), Sleeve.short);
      expect(p.note, '최고 31°C라 반팔에 아우터 없이 가볍게 골랐어요');
    });
    test('긴팔이 충분한 옷장(3벌 이상)에서는 추운 날 반팔이 채택되지 않는다', () {
      final p = _plan(_meeting, _day(max: 3, min: -3), '세미포멀');
      for (final c in p.match.candidates) {
        expect(isSummerItem(_topOf(c.items)), isFalse, reason: _topOf(c.items).id);
      }
      expect(p.note, isNot(contains('반팔')));
      expect(p.note, contains('긴팔에'));
    });
    test('16/7°C: 문구가 조합과 맞다(반팔이면 아우터와 함께)', () {
      final p = _plan(_meeting, _day(max: 16, min: 7), '세미포멀');
      final outer = p.top.where((i) => i.category == '아우터');
      expect(outer, isNotEmpty);
      final sleeve = sleeveOf(_topOf(p.top));
      expect(p.note, contains(sleeve == Sleeve.short ? '반팔에' : '긴팔에'));
    });
    test('추운 날 옷장에 한겨울용 아우터가 있으면 격식이 같은 다른 아우터보다 앞선다(§2-5-4)', () {
      // 감점은 격식 한 단계를 뒤집지 않는다 — 블레이저와 같은 세미포멀 한겨울용 아우터로 비교한다.
      final coat = _w('pad', '아우터', color: '블랙', formality: '세미포멀', tags: ['코트', '울혼방', '겨울']);
      final p = _plan([..._meeting, coat], _day(max: 3, min: -3), '세미포멀');
      expect(p.top.firstWhere((i) => i.category == '아우터').id, 'pad');
      expect(p.note, contains('두꺼운 아우터를 더했어요'));
    });
  });

  // 데모 옷장(긴팔 상의 1벌) — docs/task_demo_flow_v1.md §2-8 판정 기준(사전 고정).
  // §2-6 표(§2-6 보완 커밋 시점)에서 바뀌는 것: [모임] 추움 아우터(블레이저 → 한겨울용, 결정 2)와
  // 더움 하의(반바지 계열 허용, 결정 3). DEMO_TABLE=1이면 행마다 조합과 문구를 출력한다.
  group('데모 옷장 — §2-8 판정 기준', () {
    final demo = _loadDemo();
    String desc(WardrobeItem? i) =>
        i == null ? '—' : '${i.attributes!.color} ${i.attributes!.tags.take(3).join('·')}(${i.attributes!.formality})';
    WardrobeItem? cat(List<WardrobeItem> items, String c) => items.where((i) => i.category == c).firstOrNull;
    const conditions = [
      ('더움 31/24', 31.0, 24.0),
      ('온화 22/14', 22.0, 14.0),
      ('선선 14/8', 14.0, 8.0),
      ('추움 3/−3', 3.0, -3.0),
      ('실제 16/7', 16.0, 7.0),
    ];
    final rows = <String, ({List<WardrobeItem> top, String note})>{};
    for (final (tag, formality) in [('일상', '캐주얼'), ('모임', '세미포멀'), ('결혼식', '포멀')]) {
      for (final (label, mx, mn) in conditions) {
        final p = _plan(demo, _day(max: mx, min: mn), formality);
        rows['$tag $label'] = (top: p.top, note: p.note!);
      }
    }
    if (Platform.environment['DEMO_TABLE'] == '1') {
      for (final e in rows.entries) {
        final t = e.value.top;
        // ignore: avoid_print
        print('ROW|${e.key}|${desc(cat(t, '상의'))}|${desc(cat(t, '하의'))}|${desc(cat(t, '아우터'))}|'
            '${desc(cat(t, '신발'))}|${e.value.note}');
      }
    }

    test('조건 확인 — 긴팔 상의 1벌(맨투맨)', () {
      expect(demo.where((i) => i.category == '상의' && sleeveOf(i) == Sleeve.long).length, 1);
    });

    const casualBottom = '블랙 데님·와이드팬츠·턱팬츠(캐주얼)';
    const shoes = '블랙 스니커즈·캔버스·스트릿(캐주얼)';
    const mantoman = '블랙 맨투맨·스포티·코튼(캐주얼)';
    const semiTop = '블랙 카라티·니트·반팔(세미포멀)';
    const semiBottom = '블랙 와이드팬츠·슬랙스·봄가을(세미포멀)';
    const blazer = '블랙 블레이저·봄가을·아우터(세미포멀)';
    void expectRow(String key, {String? top, String? bottom, String? outer, String? note}) {
      final r = rows[key]!;
      if (top != null) expect(desc(cat(r.top, '상의')), top, reason: key);
      if (bottom != null) expect(desc(cat(r.top, '하의')), bottom, reason: key);
      if (outer != null) expect(desc(cat(r.top, '아우터')), outer, reason: key);
      expect(desc(cat(r.top, '신발')), shoes, reason: key);
      if (note != null) expect(r.note, note, reason: key);
    }

    test('(가) [일상] 추움 3/−3: 긴팔 + 한겨울용 아우터, 하의는 반바지 계열 아님', () {
      final r = rows['일상 추움 3/−3']!;
      expect(desc(cat(r.top, '상의')), mantoman);
      expect(isHeavyOuter(cat(r.top, '아우터')!), isTrue);
      expect(isShorts(cat(r.top, '하의')!), isFalse);
      expect(r.note, '최고 3°C라 긴팔에 두꺼운 아우터를 더했어요');
    });
    test('(나) [일상] 선선 14/8·실제 16/7: 직전 표와 같다', () {
      for (final (key, t) in [('일상 선선 14/8', 14), ('일상 실제 16/7', 16)]) {
        expectRow(key,
            top: mantoman,
            bottom: casualBottom,
            outer: '블랙 자켓·버클디테일·봄가을(캐주얼)',
            note: '최고 $t°C라 긴팔에 아우터를 더했어요');
      }
    });
    test('(다) [모임] 온화·선선·실제 16/7은 직전 표와 같고, 추움은 아우터만 한겨울용', () {
      expectRow('모임 온화 22/14',
          top: semiTop, bottom: semiBottom, outer: '—', note: '최고 22°C인데 옷장에 긴팔이 거의 없어 반팔로 골랐어요');
      expectRow('모임 선선 14/8', top: semiTop, bottom: semiBottom, outer: blazer, note: '최고 14°C라 반팔에 아우터를 더했어요');
      expectRow('모임 실제 16/7', top: semiTop, bottom: semiBottom, outer: blazer, note: '최고 16°C라 반팔에 아우터를 더했어요');
      final cold = rows['모임 추움 3/−3']!;
      expectRow('모임 추움 3/−3', top: semiTop, bottom: semiBottom);
      expect(isHeavyOuter(cat(cold.top, '아우터')!), isTrue);
      expect(cold.note, endsWith('격식보다 보온을 우선했어요'), reason: '채택된 한겨울용 아우터가 캐주얼');
    });
    test('(라) 더움 31/24: 상의·아우터·신발은 직전 표와 같다(하의는 반바지 계열도 통과)', () {
      expectRow('일상 더움 31/24',
          top: '화이트 반팔·여름·스트릿웨어(캐주얼)', outer: '—', note: '최고 31°C라 반팔에 아우터 없이 가볍게 골랐어요');
      expectRow('모임 더움 31/24', top: semiTop, outer: '—', note: '최고 31°C라 반팔에 아우터 없이 가볍게 골랐어요');
      for (final key in ['일상 더움 31/24', '모임 더움 31/24']) {
        final b = cat(rows[key]!.top, '하의')!;
        expect(desc(b) == casualBottom || desc(b) == semiBottom || isShorts(b), isTrue, reason: '$key ${desc(b)}');
      }
    });
    test('(마) 포멀 일정을 추움으로 돌리면 아우터가 블랙 블레이저로 유지된다', () {
      final r = rows['결혼식 추움 3/−3']!;
      expect(desc(cat(r.top, '아우터')), blazer);
      expect(r.note, isNot(contains('격식보다 보온')));
    });
    test('(바) 모든 행에서 문구가 조합과 어긋나지 않는다', () {
      for (final e in rows.entries) {
        final top = cat(e.value.top, '상의')!;
        final outer = cat(e.value.top, '아우터');
        final note = e.value.note;
        final sleeve = sleeveOf(top);
        if (sleeve == Sleeve.short) {
          expect(note, isNot(contains('긴팔에')), reason: e.key);
          expect(note, isNot(contains('긴팔로')), reason: e.key);
        }
        if (sleeve == Sleeve.long) expect(note, isNot(contains('반팔')), reason: e.key);
        expect(note.contains('아우터를 더했어요'), outer != null, reason: e.key);
        if (note.contains('두꺼운 아우터')) expect(isHeavyOuter(outer!), isTrue, reason: e.key);
        if (note.contains('격식보다 보온')) expect(isHeavyOuter(outer!), isTrue, reason: e.key);
        expect(note, isNot(contains('옷장에 긴팔 상의가 없어')), reason: '"없어"는 0벌일 때만 — ${e.key}');
        if (e.key.contains('추움') || e.key.contains('선선') || e.key.contains('16/7')) {
          expect(isShorts(cat(e.value.top, '하의')!), isFalse, reason: e.key);
        }
      }
    });
    test('상황의 격식에 따라 상의가 달라진다(맨투맨 한 벌로 고정되지 않음)', () {
      for (final label in ['선선 14/8', '추움 3/−3', '실제 16/7']) {
        expect(cat(rows['일상 $label']!.top, '상의')!.id, isNot(cat(rows['모임 $label']!.top, '상의')!.id), reason: label);
      }
    });
  });

  group('형태·아우터 계절 구분 — 합성 옷장(§2-7 3단계)', () {
    test('하의 계절 태그 때문에 다양성 하한이 걸려도 선선·추움에 반바지가 채택되지 않는다', () {
      // 긴바지 1벌(여름 태그 — 계절 규칙으로는 남는 옷이 3벌 미만이라 빼지 못함) + 반바지 3벌.
      final wardrobe = [
        _w('top', '상의', tags: ['맨투맨']),
        _w('long', '하의', color: '베이지', tags: ['린넨혼방', '와이드팬츠', '여름']),
        for (var i = 0; i < 3; i++) _w('short$i', '하의', color: '블랙', tags: ['반바지', '여름']),
        _w('shoe', '신발', tags: ['스니커즈']),
        _blazer,
      ];
      for (final day in [_day(max: 14, min: 8), _day(max: 3, min: -3)]) {
        final p = _plan(wardrobe, day, '캐주얼');
        for (final c in p.match.candidates) {
          expect(isShorts(c.items.firstWhere((i) => i.category == '하의')), isFalse, reason: '${day.maxTempC}');
        }
      }
    });
    test('한겨울용과 그 외 아우터가 둘 다 격식에 맞게 있으면 선선과 추움의 아우터가 다르다', () {
      final wardrobe = [
        ..._longTops,
        ..._bottoms,
        ..._shoes,
        _blazer,
        _w('coat', '아우터', color: '차콜', formality: '세미포멀', tags: ['코트', '울혼방', '겨울']),
      ];
      final cool = _plan(wardrobe, _day(max: 14, min: 8), '세미포멀').top.firstWhere((i) => i.category == '아우터');
      final cold = _plan(wardrobe, _day(max: 3, min: -3), '세미포멀').top.firstWhere((i) => i.category == '아우터');
      expect(cool.id, 'blazer');
      expect(cold.id, 'coat');
    });
    test('더움은 반바지 우선(긴 하의 감점), 온화는 긴바지 우선(반바지 감점) — 빼지는 않는다', () {
      final shorts = _w('s', '하의', tags: ['반바지', '여름']);
      final pants = _w('p', '하의', tags: ['와이드팬츠', '사계절']);
      expect(isWeatherPenaltyTarget(pants, _ctx(max: 31, min: 24)), isTrue);
      expect(isWeatherPenaltyTarget(shorts, _ctx(max: 31, min: 24)), isFalse);
      expect(isWeatherPenaltyTarget(shorts, _ctx(max: 22, min: 14)), isTrue);
      expect(filterWardrobeForBand([shorts, pants], _ctx(max: 22, min: 14)).removedIds, isEmpty);
      expect(filterWardrobeForBand([shorts, pants], _ctx(max: 3, min: -3)).removedIds, {'s'});
    });
  });

  group('새 옷 등록 추천에 오늘 기온대(§2-8 결정 1)', () {
    final demo = _loadDemo();
    final hood = _w('hood', '아우터', color: '그레이', tags: ['후드', '가을겨울']);
    List<List<String>> ids(List<OutfitMatch> m) => [for (final c in m) [for (final i in c.items) i.id]];
    test('예보가 없으면 결과가 지금과 완전히 같다', () {
      final before = OutfitMatcher.findCandidateMatches(newItem: hood, existingItems: demo);
      final after = AgentPlanner.newItemCandidatesForWeather(newItem: hood, existingItems: demo);
      expect(ids(after), ids(before));
    });
    test('선선·추움 예보면 반바지 계열 하의가 후보에 없고 새 옷은 거르지 않는다', () {
      for (final day in [_day(max: 16, min: 7), _day(max: 3, min: -3)]) {
        final c = AgentPlanner.newItemCandidatesForWeather(newItem: hood, existingItems: demo, today: day);
        expect(c, isNotEmpty);
        for (final m in c) {
          expect(m.items.where((i) => i.category == '하의').any(isShorts), isFalse, reason: '${day.maxTempC}');
          expect(m.items.map((i) => i.id), contains('hood'));
        }
      }
    });
  });

  group('격식 우선(§2-5-3)', () {
    test('거른 결과가 격식 차선이고 거르지 않은 결과가 적합이면 거르지 않은 결과', () {
      // 더운 날 긴팔(맨투맨 셋)을 빼면 남는 상의가 캐주얼 반팔 셋뿐 → 포멀 일정엔 차선.
      final wardrobe = [
        for (var i = 0; i < 3; i++) _w('tee$i', '상의', color: '옐로우', tags: ['반팔', '여름']),
        for (var i = 0; i < 3; i++) _w('ls$i', '상의', color: '블랙', formality: '포멀', tags: ['맨투맨']),
        _w('slacks', '하의', color: '블랙', formality: '포멀', tags: ['슬랙스']),
      ];
      final m = AgentPlanner.matchForWeather(wardrobe: wardrobe, formalityHint: '포멀', day: _day(max: 31, min: 24));
      expect(m.formalityOverride, isTrue);
      expect(m.match.isFallback, isFalse);
      expect(_topOf(m.match.candidates.first.items).id, startsWith('ls'));
    });
  });

  group('문구 — 최종 채택 조합 전체 기준, 확인된 사실만', () {
    final short = _realTops[2];
    final long = _longTops[0];
    final pants = _bottoms[1];
    String note(WeatherContext c, List<WardrobeItem> fin, List<WardrobeItem> wardrobe,
            {Set<String> removed = const {}, List<WardrobeItem>? baseline, bool assumed = false}) =>
        buildWeatherNote(
            ctx: c,
            baselineTop: baseline ?? fin,
            weatherTop: fin,
            finalItems: fin,
            wardrobe: wardrobe,
            removedIds: removed,
            isAssumed: assumed)!;
    test('규칙을 다 만족하면 구성을 그대로 말한다', () {
      expect(note(_ctx(max: 22, min: 14), [long, pants], _meeting), '최고 22°C라 긴팔로 아우터 없이 골랐어요');
      expect(note(_ctx(max: 12, min: 5), [long, pants, _windbreaker], _meeting), '최고 12°C라 긴팔에 가벼운 아우터를 더했어요');
      expect(note(_ctx(max: 22, min: 7), [long, pants, _windbreaker], _meeting),
          '최고 22°C·최저 7°C라 긴팔에 가벼운 아우터를 더했어요');
      expect(note(_ctx(max: 3, min: -3), [long, pants, _heavyOuter], _meeting), '최고 3°C라 긴팔에 두꺼운 아우터를 더했어요');
    });
    test('선선은 아우터가 있으면 반팔도 규칙 안이다', () {
      expect(note(_ctx(max: 14, min: 8), [short, pants, _blazer], _meeting), '최고 14°C라 반팔에 아우터를 더했어요');
    });
    test('소매 길이를 모르면 반팔·긴팔이라고 쓰지 않는다', () {
      expect(note(_ctx(max: 31, min: 24), [_unknownTop, pants], _meeting), '최고 31°C라 아우터 없이 가볍게 골랐어요');
    });
    test('긴팔이 0벌이면 "없어", 1~2벌이면 "거의 없어", 3벌 이상이면 실제 이유', () {
      final none = [..._realTops, ..._bottoms, _blazer];
      final few = [..._realTops, _longTops[0], ..._bottoms, _blazer];
      expect(note(_ctx(max: 5, min: 0), [short, pants, _blazer], none),
          '최고 5°C인데 옷장에 긴팔 상의가 없어 반팔에 아우터를 더했어요');
      expect(note(_ctx(max: 5, min: 0), [short, pants, _blazer], few),
          '최고 5°C인데 옷장에 긴팔이 거의 없어 반팔에 아우터를 더했어요');
      expect(note(_ctx(max: 5, min: 0), [short, pants, _blazer], _meeting),
          '최고 5°C인데 일정에 맞는 긴팔 조합이 나오지 않아 반팔에 아우터를 더했어요');
      expect(note(_ctx(max: 22, min: 14), [short, pants], none),
          '최고 22°C인데 옷장에 긴팔 상의가 없어 반팔로 골랐어요');
    });
    test('아우터를 못 맞춘 경우', () {
      expect(note(_ctx(max: 5, min: 0), [long, pants], [long, pants]), '최고 5°C인데 옷장에 아우터가 없어요');
      expect(note(_ctx(max: 5, min: 0), [long, pants], _meeting),
          '최고 5°C인데 일정에 맞는 아우터 조합이 나오지 않아 아우터 없이 골랐어요');
      expect(note(_ctx(max: 31, min: 24), [short, pants, _blazer], _meeting),
          '최고 31°C인데 일정에 맞는 조합이 나오지 않아 아우터가 들어갔어요');
    });
    test('비가 겹치면 비 문구를 이어 붙이고, 기온대로 빠진 아우터는 비 때문에 피한 옷이 아니다', () {
      final suedeOuter = _w('sue', '아우터', color: '베이지', tags: ['스웨이드', '봄', '가을', '블루종']);
      final lightPants = _w('wp', '하의', color: '화이트', tags: ['면']);
      final hotRain = _ctx(max: 31, min: 24, rain: 80);
      expect(note(hotRain, [short, pants], _meeting, baseline: [short, pants, suedeOuter], removed: {'sue'}),
          '최고 31°C라 반팔에 아우터 없이 가볍게 골랐어요 · 비 예보에도 무리 없는 조합이에요');
      expect(note(hotRain, [short, pants], _meeting, baseline: [short, lightPants], removed: const {}),
          '최고 31°C라 반팔에 아우터 없이 가볍게 골랐어요 · 비 예보라 밝은 하의 대신 어두운 톤으로 골랐어요');
      expect(note(hotRain, [short, lightPants], _meeting),
          '최고 31°C라 반팔에 아우터 없이 가볍게 골랐어요 · 비 예보지만 밝은 하의가 그대로 들어갔어요');
    });
    test('가정 예보 꼬리표', () {
      expect(note(_ctx(max: 22, min: 14), [long, pants], _meeting, assumed: true),
          '최고 22°C라 긴팔로 아우터 없이 골랐어요 (테스트용 가정 예보)');
    });
  });

  group('감점 — 기존 0.3, 덜 어울리는 정도의 옷만', () {
    test('더움·온화: 두꺼운 소재. 니트는 아님', () {
      expect(isWeatherPenaltyTarget(_bottoms[0], _ctx(max: 31, min: 24)), isTrue); // 가을/겨울
      expect(isWeatherPenaltyTarget(_realTops[0], _ctx(max: 31, min: 24)), isFalse); // 여름 니트
    });
    test('선선: 한겨울용 아우터·여름 상의, 추움: 얇은 아우터(+ 한겨울용이 있으면 그 밖의 아우터)', () {
      expect(isWeatherPenaltyTarget(_heavyOuter, _ctx(max: 14, min: 8)), isTrue);
      expect(isWeatherPenaltyTarget(_windbreaker, _ctx(max: 14, min: 8)), isFalse);
      expect(isWeatherPenaltyTarget(_windbreaker, _ctx(max: 3, min: -3)), isTrue);
      expect(isWeatherPenaltyTarget(_heavyOuter, _ctx(max: 3, min: -3)), isFalse);
      expect(isWeatherPenaltyTarget(_blazer, _ctx(max: 3, min: -3)), isFalse, reason: '한겨울용 없는 옷장');
      final withHeavy = weatherContextFor(_day(max: 3, min: -3), wardrobe: [_blazer, _heavyOuter])!;
      expect(isWeatherPenaltyTarget(_blazer, withHeavy), isTrue);
      expect(isWeatherPenaltyTarget(_heavyOuter, withHeavy), isFalse);
    });
    test('비 규칙 그대로 — 밝은 하의·신발, 니트·골지·스웨이드', () {
      final rain = _ctx(max: 14, min: 8, rain: 80);
      expect(rainAvoidReason(_w('x', '하의', color: '화이트'))?.phrase, '밝은 하의');
      expect(rainAvoidReason(_w('x', '신발', tags: ['스웨이드']))?.phrase, '스웨이드 신발');
      expect(rainAvoidReason(_w('x', '상의', color: '화이트')), isNull);
      expect(isWeatherPenaltyTarget(_w('x', '하의', color: '화이트'), rain), isTrue);
      expect(isWeatherPenaltyTarget(_w('x', '하의', color: '화이트'), _ctx(max: 14, min: 8)), isFalse);
    });
  });

  group('홈 한 줄 조언 — 같은 기온대 함수', () {
    test('반팔이라고 하는 날은 추천도 반팔(더움)일 때뿐', () {
      expect(weatherAdviceFor(_ctx(max: 31, min: 24)), '반팔이면 충분해요');
      expect(weatherAdviceFor(_ctx(max: 22, min: 14)), '긴팔 한 장이면 충분해요');
      expect(weatherAdviceFor(_ctx(max: 22, min: 7)), '긴팔에 아침저녁용 가벼운 아우터를 챙기세요');
      expect(weatherAdviceFor(_ctx(max: 14, min: 8)), '긴팔에 가벼운 아우터를 걸치세요');
      expect(weatherAdviceFor(_ctx(max: 3, min: -3)), '두꺼운 아우터가 필요한 추운 날씨예요');
      expect(weatherAdviceFor(_ctx(max: 14, min: 8, rain: 80)), '비 예보가 있어요, 우산을 챙기세요');
    });
  });

  group('예보 가정(테스트용) — 네 기온대와 비', () {
    final now = DateTime(2026, 11, 14, 9);
    WeatherContext ctxOf(ForecastAssumption a) =>
        weatherContextFor(WeatherService.assumedSnapshot(a, now).forDate(DateTime(2026, 11, 16)))!;
    test('각 가정이 해당 기온대에 들고 isAssumed가 켜진다', () {
      expect(ctxOf(ForecastAssumption.hot).band, TempBand.hot);
      expect(ctxOf(ForecastAssumption.mild).band, TempBand.mild);
      expect(ctxOf(ForecastAssumption.mild).needsOuter, isFalse);
      expect(ctxOf(ForecastAssumption.cool).band, TempBand.cool);
      expect(ctxOf(ForecastAssumption.cold).band, TempBand.cold);
      expect(ctxOf(ForecastAssumption.rain).rain, isTrue);
      for (final a in ForecastAssumption.values.where((a) => a != ForecastAssumption.none)) {
        final snap = WeatherService.assumedSnapshot(a, now);
        expect(snap.isAssumed, isTrue);
        expect(snap.daily.length, 7);
      }
    });
  });

  group('가정 예보가 관련된 다시 계획은 횟수 상한에 넣지 않는다', () {
    int? next(int count, {bool existing = false, bool current = false}) =>
        AgentPlanner.replanCountAfterWeatherChange(
            existingCount: count, existingAssumed: existing, currentAssumed: current);
    test('실제 예보끼리는 상한(2회) 그대로', () {
      expect(next(0), 1);
      expect(next(1), 2);
      expect(next(2), isNull);
    });
    test('가정 예보로 바뀌는 경우·가정 예보 추천이 실제로 돌아오는 경우 — 세지 않고 막지 않는다', () {
      expect(next(2, current: true), 2);
      expect(next(2, existing: true), 2);
      expect(next(0, existing: true, current: true), 0);
    });
    test('가정 예보가 켜진 채 실행이 반복돼도 다시 계획되지 않는다(저장된 예보가 이미 가정 값)', () {
      final now = DateTime(2026, 11, 14, 9);
      for (final a in ForecastAssumption.values.where((a) => a != ForecastAssumption.none)) {
        final day = WeatherService.assumedSnapshot(a, now).forDate(DateTime(2026, 11, 15))!;
        final d = AgentPlanner.shouldReplanForWeather(
          snapshotPrecipProbability: day.precipitationProbability,
          snapshotMaxTempC: day.maxTempC,
          currentForecast: WeatherService.assumedSnapshot(a, now.add(const Duration(hours: 3)))
              .forDate(DateTime(2026, 11, 15)),
        );
        expect(d.replan, isFalse, reason: a.name);
      }
    });
    test('가정을 끄면(실제 예보로 돌아오면) 값이 달라 다시 계획되고, 상한에 막히지 않는다', () {
      final assumed = WeatherService.assumedSnapshot(ForecastAssumption.hot, DateTime(2026, 11, 14))
          .forDate(DateTime(2026, 11, 15))!;
      final d = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: assumed.precipitationProbability,
        snapshotMaxTempC: assumed.maxTempC,
        currentForecast: _day(max: 16, min: 7, rain: 53),
      );
      expect(d.replan, isTrue);
      expect(next(2, existing: true), 2);
    });
  });
}
