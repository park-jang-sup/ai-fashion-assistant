// 날씨를 실제 선택에 반영 — docs/task_agent_grounding_v1.md 부분 C.
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
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

DailyWeather _day({double max = 18, double min = 10, int rain = 0}) =>
    DailyWeather(date: DateTime(2026, 11, 20), maxTempC: max, minTempC: min, precipitationProbability: rain);

// 매칭 픽스처 — 같은 격식 점수의 하의 두 벌(밝은 화이트 / 어두운 차콜). 같은 점수라
// 날씨 감점이 없으면 id 순(a < b)으로 화이트가 1순위가 된다.
final _wardrobe = [
  _w('top1', '상의', color: '블랙'),
  _w('top2', '상의', color: '그레이', tags: ['니트']),
  _w('bot_a', '하의', color: '화이트'),
  _w('bot_b', '하의', color: '차콜'),
  _w('shoe_a', '신발', color: '블랙', tags: ['스웨이드']),
  _w('shoe_b', '신발', color: '블랙', tags: ['가죽']),
  _w('out_a', '아우터', color: '네이비', tags: ['겨울', '울혼방']),
  _w('out_b', '아우터', color: '네이비', tags: ['봄가을']),
];

List<List<String>> _ids(TpoMatchResult r) => [for (final c in r.candidates) [for (final i in c.items) i.id]];

void main() {
  group('weatherFlagsFor — 주간 플랜 날씨 제약과 같은 기준', () {
    test('특이 조건 없음', () => expect(weatherFlagsFor(_day()), isEmpty));
    test('비(강수확률 임계 이상)', () {
      expect(weatherFlagsFor(_day(rain: WeatherService.rainProbabilityThreshold)), [WeatherFlag.rain]);
      expect(weatherFlagsFor(_day(rain: WeatherService.rainProbabilityThreshold - 1)), isEmpty);
    });
    test('더위(최고 28 이상)가 추위보다 우선', () {
      expect(weatherFlagsFor(_day(max: 28, min: 3)), [WeatherFlag.hot]);
      expect(weatherFlagsFor(_day(max: 10, min: 5)), [WeatherFlag.cold]);
    });
    test('비와 추위가 함께', () {
      expect(weatherFlagsFor(_day(max: 8, min: 2, rain: 80)), [WeatherFlag.rain, WeatherFlag.cold]);
    });
    test('예보 없음', () => expect(weatherFlagsFor(null), isEmpty));
  });

  group('weatherAvoidReason — 감점 대상', () {
    test('비: 밝은 하의·신발, 니트·스웨이드 계열. 밝은 상의는 아님', () {
      expect(weatherAvoidReason(_w('x', '하의', color: '화이트'), [WeatherFlag.rain])?.phrase, '밝은 하의');
      expect(weatherAvoidReason(_w('x', '신발', color: '아이보리'), [WeatherFlag.rain])?.phrase, '밝은 신발');
      expect(weatherAvoidReason(_w('x', '신발', tags: ['스웨이드']), [WeatherFlag.rain])?.phrase, '스웨이드 신발');
      expect(weatherAvoidReason(_w('x', '상의', tags: ['니트']), [WeatherFlag.rain])?.phrase, '니트 상의');
      expect(weatherAvoidReason(_w('x', '상의', color: '화이트'), [WeatherFlag.rain]), isNull);
      expect(weatherAvoidReason(_w('x', '하의', color: '차콜'), [WeatherFlag.rain]), isNull);
    });
    test('더위: 겨울·두꺼운 소재', () {
      expect(weatherAvoidReason(_w('x', '아우터', tags: ['양털안감']), [WeatherFlag.hot])?.phrase, '두꺼운 아우터');
      expect(weatherAvoidReason(_w('x', '상의', tags: ['반팔']), [WeatherFlag.hot]), isNull);
    });
    test('추위: 여름·얇은 소재', () {
      expect(weatherAvoidReason(_w('x', '하의', tags: ['반바지']), [WeatherFlag.cold])?.phrase, '얇은 하의');
      expect(weatherAvoidReason(_w('x', '상의', tags: ['울혼방']), [WeatherFlag.cold]), isNull);
    });
    test('태그는 전체가 같을 때만(부분 문자열 아님)', () {
      expect(weatherAvoidReason(_w('x', '상의', tags: ['여름아우터용']), [WeatherFlag.cold]), isNull);
    });
    test('액세서리는 세부 종류로 부른다', () {
      expect(weatherAvoidReason(_w('x', '액세서리', sub: '모자', tags: ['겨울']), [WeatherFlag.hot])?.phrase, '두꺼운 모자');
    });
  });

  group('findForTpo — 예보가 없으면 결과가 지금과 완전히 같다', () {
    final base = OutfitMatcher.findForTpo(wardrobe: _wardrobe, formalityHint: '캐주얼');
    test('weather: null', () {
      expect(_ids(OutfitMatcher.findForTpo(wardrobe: _wardrobe, formalityHint: '캐주얼', weather: null)), _ids(base));
    });
    test('특이 조건 없는 예보', () {
      expect(_ids(OutfitMatcher.findForTpo(wardrobe: _wardrobe, formalityHint: '캐주얼', weather: _day())), _ids(base));
    });
    test('정책 감점이 0이면 비 예보여도 그대로', () {
      expect(
          _ids(OutfitMatcher.findForTpo(
              wardrobe: _wardrobe,
              formalityHint: '캐주얼',
              weather: _day(rain: 90),
              policy: const TpoMatchPolicy(weatherPenalty: 0))),
          _ids(base));
    });
    test('기준선 확인 — 날씨 없으면 밝은 하의(bot_a)가 1순위 조합에 들어간다', () {
      expect(_ids(base).first, contains('bot_a'));
    });
  });

  group('findForTpo — 비 예보면 감점 대상이 1순위에서 밀린다', () {
    final rain = OutfitMatcher.findForTpo(wardrobe: _wardrobe, formalityHint: '캐주얼', weather: _day(rain: 90));
    test('밝은 하의 대신 어두운 하의, 스웨이드 대신 가죽 신발, 니트 아닌 상의', () {
      final top = _ids(rain).first;
      expect(top, containsAll(['bot_b', 'shoe_b', 'top1']));
      expect(top, isNot(contains('bot_a')));
    });
    test('격식 자격은 바꾸지 않는다 — 감점 대상만 있는 카테고리도 조합에 남는다', () {
      final onlyLight = [_w('t', '상의'), _w('b', '하의', color: '화이트')];
      final r = OutfitMatcher.findForTpo(wardrobe: onlyLight, formalityHint: '캐주얼', weather: _day(rain: 90));
      expect(r.isFallback, isFalse);
      expect(_ids(r).first, containsAll(['t', 'b']));
    });
  });

  group('buildWeatherNote — 실제로 한 일만 말한다', () {
    final rain = [WeatherFlag.rain];
    final light = _w('bot_a', '하의', color: '화이트');
    final dark = _w('bot_b', '하의', color: '차콜');
    final top = _w('top1', '상의');
    test('피한 옷이 있다 — 무엇을 피했는지 구체적으로', () {
      expect(
          buildWeatherNote(flags: rain, baselineTop: [top, light], weatherTop: [top, dark], finalItems: [top, dark]),
          '비 예보라 밝은 하의 대신 어두운 톤으로 골랐어요');
    });
    test('피한 옷이 없고 남은 옷도 없다', () {
      expect(buildWeatherNote(flags: rain, baselineTop: [top, dark], weatherTop: [top, dark], finalItems: [top, dark]),
          '비 예보에도 무리 없는 조합이에요');
    });
    test('피한 옷이 없고 남은 옷이 있다', () {
      expect(buildWeatherNote(flags: rain, baselineTop: [top, light], weatherTop: [top, light], finalItems: [top, light]),
          '비 예보가 있지만 옷장에 더 맞는 옷이 없어 그대로 추천해요');
    });
    test('자기평가가 날씨 1순위가 아닌 후보(감점 대상 포함)를 채택했으면 날씨 덕으로 말하지 않는다', () {
      // 날씨 1순위는 밝은 하의를 뺐지만, 최종 채택은 다시 밝은 하의 조합 → 피한 옷 없음, 남은 옷 있음.
      expect(buildWeatherNote(flags: rain, baselineTop: [top, light], weatherTop: [top, dark], finalItems: [top, light]),
          '비 예보가 있지만 옷장에 더 맞는 옷이 없어 그대로 추천해요');
    });
    test('날씨 1순위와 상관없이 다른 이유로 바뀐 옷은 "피한 옷"이 아니다(1순위에 남아 있으면)', () {
      // 날씨 1순위에도 밝은 하의가 그대로 있으면 피한 게 아니다.
      expect(buildWeatherNote(flags: rain, baselineTop: [top, light], weatherTop: [top, light], finalItems: [top, dark]),
          '비 예보에도 무리 없는 조합이에요');
    });
    test('소재·더위·추위 문구', () {
      final suede = _w('s', '신발', tags: ['스웨이드']);
      final leather = _w('l', '신발', tags: ['가죽']);
      expect(buildWeatherNote(flags: rain, baselineTop: [suede], weatherTop: [leather], finalItems: [leather]),
          '비 예보라 스웨이드 신발 대신 다른 옷으로 골랐어요');
      final thick = _w('o1', '아우터', tags: ['겨울']);
      final lightOuter = _w('o2', '아우터', tags: ['봄가을']);
      expect(buildWeatherNote(flags: [WeatherFlag.hot], baselineTop: [thick], weatherTop: [lightOuter], finalItems: [lightOuter]),
          '더운 날씨 예보라 두꺼운 아우터 대신 가벼운 옷으로 골랐어요');
      final shorts = _w('p1', '하의', tags: ['반바지']);
      final pants = _w('p2', '하의', tags: ['슬랙스']);
      expect(buildWeatherNote(flags: [WeatherFlag.cold], baselineTop: [shorts], weatherTop: [pants], finalItems: [pants]),
          '추운 날씨 예보라 얇은 하의 대신 따뜻한 옷으로 골랐어요');
    });
    test('가정 예보면 끝에 표시', () {
      expect(buildWeatherNote(flags: rain, baselineTop: [top], weatherTop: [top], finalItems: [top], isAssumed: true),
          '비 예보에도 무리 없는 조합이에요 (테스트용 가정 예보)');
    });
    test('특이 조건이 없으면 문구 없음', () {
      expect(buildWeatherNote(flags: const [], baselineTop: [top], weatherTop: [top], finalItems: [top]), isNull);
    });
    test('조합 변경 여부', () {
      expect(weatherChangedTopCombo([top, light], [top, dark]), isTrue);
      expect(weatherChangedTopCombo([top, dark], [dark, top]), isFalse);
    });
  });

  group('예보 가정(테스트용)', () {
    test('가정한 예보는 조건이 확실히 걸리고 isAssumed가 켜진다', () {
      final now = DateTime(2026, 11, 14, 9);
      for (final (a, flag) in [
        (ForecastAssumption.rain, WeatherFlag.rain),
        (ForecastAssumption.hot, WeatherFlag.hot),
        (ForecastAssumption.cold, WeatherFlag.cold),
      ]) {
        final snap = WeatherService.assumedSnapshot(a, now);
        expect(snap.isAssumed, isTrue);
        expect(snap.daily.length, 7);
        expect(weatherFlagsFor(snap.forDate(DateTime(2026, 11, 16))), contains(flag), reason: a.name);
      }
    });
  });
}
