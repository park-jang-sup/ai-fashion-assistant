// AI에게 부탁하기 — 도구 계층(docs/task_agent_ask_v1.md §2-2·§2-3), 가짜 데이터.
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/outfit_calendar_entry.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

WardrobeItem _w(String id, String category,
        {String color = '블랙', String formality = '캐주얼', List<String> tags = const [], String? sub, int day = 1}) =>
    WardrobeItem(
      id: id,
      imageUrl: '',
      category: category,
      subCategory: sub,
      createdAt: DateTime(2026, 11, day),
      attributes: ClothingAttributes(
          color: color, style: '캐주얼', pattern: '무지', formality: formality, fit: '레귤러', tags: tags),
    );

final _wardrobe = [
  _w('t1', '상의', tags: ['맨투맨', '코튼']),
  _w('t2', '상의', color: '화이트', formality: '세미포멀', tags: ['셔츠', '가을/겨울']),
  _w('p1', '하의', tags: ['슬랙스', '사계절'], formality: '세미포멀'),
  _w('p2', '하의', color: '차콜', tags: ['데님', '사계절']),
  _w('o1', '아우터', color: '카키', tags: ['코듀로이', '퀼팅안감', '가을/겨울']),
  _w('o2', '아우터', tags: ['블레이저', '봄가을'], formality: '세미포멀'),
  _w('s1', '신발', tags: ['스니커즈', '가죽']),
  _w('a1', '액세서리', sub: '가방', tags: ['토트백']),
];

final _today = DateTime(2026, 11, 16); // 월요일

WeatherSnapshot _snapshot({bool assumed = false}) => WeatherSnapshot(
      current: const CurrentWeather(tempC: 10, weatherCode: 3),
      daily: [
        for (var i = 0; i < 7; i++)
          DailyWeather(
            date: _today.add(Duration(days: i)),
            maxTempC: [14.0, 9.0, 12.0, 16.0, 13.0, 4.0, 11.0][i],
            minTempC: [6.0, 2.0, 5.0, 8.0, 5.0, -3.0, 3.0][i],
            precipitationProbability: [10, 70, 20, 0, 30, 10, 0][i],
          ),
      ],
      isAssumed: assumed,
    );

class _Fake implements AskDataSource {
  List<OutfitCalendarEntry> entries;
  List<RecommendationEntry> recs;
  WeatherSnapshot? snap;
  List<WardrobeItem> items;
  bool prepareResult;
  final writes = <(DateTime, String, bool)>[];
  _Fake({
    this.entries = const [],
    this.recs = const [],
    this.snap,
    List<WardrobeItem>? items,
    this.prepareResult = true,
  }) : items = items ?? _wardrobe;

  @override
  Future<List<OutfitCalendarEntry>> calendar(DateTime from, DateTime to) async =>
      entries.where((e) => !e.date.isBefore(from) && !e.date.isAfter(to)).toList();
  @override
  Future<List<RecommendationEntry>> recommendations(DateTime from, DateTime to) async => recs;
  @override
  Future<WeatherSnapshot?> weather() async => snap;
  @override
  Future<List<WardrobeItem>> wardrobe() async => items;
  @override
  Future<Set<String>> recentItemIds() async => const {};
  @override
  Future<AskPlanWrite> addPlan(DateTime date, String tpo, {required bool prepare}) async {
    writes.add((date, tpo, prepare));
    if (!prepare || !prepareResult) return const AskPlanWrite(prepared: false);
    return AskPlanWrite(
      prepared: true,
      recommendation: RecommendationEntry(
        id: 'r',
        itemIds: const ['t2', 'p1', 'o2', 's1'],
        itemSummaries: const [],
        summaryText: '',
        triggerItemId: '',
        createdAt: _today,
        colorScore: 82,
        targetDate: date,
        targetTpoTag: tpo,
        weatherNote: '최고 13°C라 긴팔에 아우터를 더했어요',
      ),
    );
  }
}

OutfitCalendarEntry _entry(DateTime d, String tpo, {bool planned = true}) => OutfitCalendarEntry(
      id: 'e${d.day}',
      date: d,
      tpoTag: tpo,
      status: planned ? OutfitCalendarEntry.statusPlanned : OutfitCalendarEntry.statusRecorded,
      itemIds: planned ? const [] : const ['t1'],
      createdAt: _today,
    );

AskTools _tools(_Fake f) => AskTools(f, now: () => DateTime(2026, 11, 16, 10));

void main() {
  group('인자 검증', () {
    test('날짜는 YYYY-MM-DD만, 없는 날짜는 거절', () {
      expect(parseAskDate('2026-11-20'), DateTime(2026, 11, 20));
      expect(parseAskDate('2026-11-5'), isNull);
      expect(parseAskDate('11/20'), isNull);
      expect(parseAskDate('2026-02-30'), isNull);
      expect(parseAskDate(20261120), isNull);
    });
    test('상황 태그 9개, 카테고리 5개', () {
      for (final t in ['출근', '데이트', '여행', '운동', '모임', '결혼식', '면접', '경조사', '일상']) {
        expect(isAskTpo(t), isTrue, reason: t);
      }
      expect(isAskTpo('파티'), isFalse);
      expect(isAskCategory('아우터'), isTrue);
      expect(isAskCategory('모자'), isFalse);
    });
    test('날짜 표시는 요일까지', () => expect(askDateLabel(DateTime(2026, 11, 20)), '2026-11-20(금)'));
  });

  group('get_calendar', () {
    test('기간 인자 오류', () async {
      final t = _tools(_Fake());
      expect((await t.getCalendar({'from': '2026-11-20', 'to': '2026-11-16'})).ok, isFalse);
      expect((await t.getCalendar({'from': '2026-11-16', 'to': '2026-12-01'})).observation, contains('최대 14일'));
      expect((await t.getCalendar({'from': '11/16', 'to': '2026-11-20'})).ok, isFalse);
    });
    test('일정 없음', () async {
      final r = await _tools(_Fake()).getCalendar({'from': '2026-11-16', 'to': '2026-11-22'});
      expect(r.ok, isTrue);
      expect(r.observation, contains('일정 없음'));
    });
    test('예정 일정과 준비된 추천 요약, 기록 일정', () async {
      final f = _Fake(
        entries: [_entry(DateTime(2026, 11, 17), '데이트'), _entry(DateTime(2026, 11, 16), '일상', planned: false)],
        recs: [
          RecommendationEntry(
              id: 'r1',
              itemIds: const ['t1', 'p2'],
              itemSummaries: const [],
              summaryText: '',
              triggerItemId: '',
              createdAt: _today,
              colorScore: 80,
              targetDate: DateTime(2026, 11, 17),
              targetTpoTag: '데이트'),
        ],
      );
      final r = await _tools(f).getCalendar({'from': '2026-11-16', 'to': '2026-11-22'});
      expect(r.observation, contains('2026-11-17(화) [데이트] 예정 — 준비된 추천: 상의 블랙 맨투맨·코튼(캐주얼)'));
      expect(r.observation, contains('80점'));
      expect(r.observation, contains('2026-11-16(월) [일상] 기록 — 착장 기록됨'));
      expect(r.items.map((i) => i.id), ['t1', 'p2']);
    });
  });

  group('get_weather', () {
    test('날짜별 최고·최저·강수·기온대·비, 7일 밖은 범위 밖', () async {
      final r = await _tools(_Fake(snap: _snapshot())).getWeather({'from': '2026-11-17', 'to': '2026-11-23'});
      expect(r.observation, contains('2026-11-17(화): 최고 9°C 최저 2°C 강수 70% · 추움 · 비'));
      expect(r.observation, contains('2026-11-21(토): 최고 4°C 최저 -3°C 강수 10% · 추움'));
      expect(r.observation, contains('2026-11-23(월): 예보 범위 밖'));
    });
    test('가정 예보면 표시, 조회 실패면 실패를 관찰로', () async {
      expect((await _tools(_Fake(snap: _snapshot(assumed: true))).getWeather({'from': '2026-11-16', 'to': '2026-11-16'}))
          .observation, contains('테스트용 가정 예보'));
      final fail = await _tools(_Fake()).getWeather({'from': '2026-11-16', 'to': '2026-11-16'});
      expect(fail.ok, isFalse);
      expect(fail.observation, contains('예보를 불러오지 못했어요'));
    });
  });

  group('search_wardrobe', () {
    test('인자가 없으면 종류별 벌수', () async {
      final r = await _tools(_Fake()).searchWardrobe({});
      expect(r.observation, '옷장 8벌 — 상의 2, 하의 2, 아우터 2, 신발 1, 액세서리 1');
    });
    test('종류·키워드로 찾고 최대 8벌', () async {
      final r = await _tools(_Fake()).searchWardrobe({'category': '아우터', 'keyword': '퀼팅안감'});
      expect(r.observation, contains('일치 1벌'));
      expect(r.observation, contains('아우터 카키 코듀로이·퀼팅안감·가을/겨울(캐주얼)'));
      final many = [for (var i = 0; i < 12; i++) _w('x$i', '상의', tags: ['반팔'], day: i + 1)];
      final r2 = await _tools(_Fake(items: many)).searchWardrobe({'category': '상의'});
      expect(r2.observation, contains('일치 12벌(앞 8벌)'));
      expect(r2.items.length, 8);
    });
    test('잘못된 종류·빈 옷장·일치 없음', () async {
      expect((await _tools(_Fake()).searchWardrobe({'category': '모자'})).ok, isFalse);
      expect((await _tools(_Fake(items: const [])).searchWardrobe({})).observation, '옷장이 비어 있어요');
      expect((await _tools(_Fake()).searchWardrobe({'keyword': '패딩'})).observation, contains('일치하는 옷 없음'));
    });
  });

  group('preview_outfit — 저장 없음', () {
    test('예보 안 날짜는 기온대 반영 조합과 날씨 문구', () async {
      final f = _Fake(snap: _snapshot());
      final r = await _tools(f).previewOutfit({'date': '2026-11-20', 'tpo': '모임'});
      expect(r.ok, isTrue);
      expect(r.observation, contains('2026-11-20(금) [모임] 미리 보기(저장 안 함)'));
      expect(r.observation, contains('날씨: 최고 13°C'));
      expect(r.items, isNotEmpty);
      expect(f.writes, isEmpty);
    });
    test('예보 범위 밖·예보 실패면 날씨 없이', () async {
      expect((await _tools(_Fake(snap: _snapshot())).previewOutfit({'date': '2026-11-30', 'tpo': '일상'})).observation,
          contains('예보 범위 밖이라 날씨 없이'));
      expect((await _tools(_Fake()).previewOutfit({'date': '2026-11-17', 'tpo': '일상'})).observation,
          contains('예보를 불러오지 못해 날씨 없이'));
    });
    test('인자 오류·옷 부족', () async {
      expect((await _tools(_Fake()).previewOutfit({'date': '2026-11-17', 'tpo': '파티'})).ok, isFalse);
      expect((await _tools(_Fake()).previewOutfit({'date': '내일', 'tpo': '일상'})).ok, isFalse);
      expect((await _tools(_Fake(items: [_wardrobe.first])).previewOutfit({'date': '2026-11-17', 'tpo': '일상'})).ok,
          isFalse);
    });
  });

  group('add_plan — 유일한 쓰기', () {
    test('검증: 지난 날짜·60일 밖·잘못된 태그는 거절(쓰지 않음)', () async {
      final f = _Fake(snap: _snapshot());
      final t = _tools(f);
      expect(t.validatePlan({'date': '2026-11-15', 'tpo': '모임'}), contains('지난 날짜'));
      expect(t.validatePlan({'date': '2027-01-16', 'tpo': '모임'}), contains('60일'));
      expect(t.validatePlan({'date': '2026-11-20', 'tpo': '파티'}), contains('인자 오류'));
      expect(t.validatePlan({'date': '2026-11-20', 'tpo': '모임'}), isNull);
      expect((await t.addPlan({'date': '2026-11-15', 'tpo': '모임'})).ok, isFalse);
      expect(f.writes, isEmpty);
    });
    test('같은 날짜에 예정 일정이 있으면 새로 넣지 않는다', () async {
      final f = _Fake(entries: [_entry(DateTime(2026, 11, 20), '출근')]);
      final r = await _tools(f).addPlan({'date': '2026-11-20', 'tpo': '모임'});
      expect(r.observation, contains('이미 [출근] 예정 일정'));
      expect(f.writes, isEmpty);
    });
    test('예보 범위 안이면 등록하고 바로 준비, 결과에 조합·점수·문구', () async {
      final f = _Fake(snap: _snapshot());
      final r = await _tools(f).addPlan({'date': '2026-11-20', 'tpo': '모임'});
      expect(f.writes, [(DateTime(2026, 11, 20), '모임', true)]);
      expect(r.observation, contains('일정을 등록하고 코디를 준비했어요'));
      expect(r.observation, contains('82점'));
      expect(r.plannedDate, DateTime(2026, 11, 20));
      expect(r.items.map((i) => i.id), ['t2', 'p1', 'o2', 's1']);
    });
    test('예보 범위 밖이면 등록만', () async {
      final f = _Fake(snap: _snapshot());
      final r = await _tools(f).addPlan({'date': '2026-11-25', 'tpo': '면접'});
      expect(f.writes, [(DateTime(2026, 11, 25), '면접', false)]);
      expect(r.observation, contains('코디는 일정이 가까워지면 예보를 보고 준비해요'));
    });
    test('준비에 실패하면 등록 사실과 실패를 함께', () async {
      final f = _Fake(snap: _snapshot(), prepareResult: false);
      final r = await _tools(f).addPlan({'date': '2026-11-18', 'tpo': '일상'});
      expect(r.observation, contains('코디는 준비하지 못했어요'));
      expect(r.plannedDate, DateTime(2026, 11, 18));
    });
  });

  test('관찰은 1,500자 이하로 줄인다', () async {
    final many = [
      for (var i = 0; i < 14; i++) _entry(DateTime(2026, 11, 16).add(Duration(days: i)), '일상'),
    ];
    final long = List.generate(30, (i) => '아주긴태그$i');
    final f = _Fake(entries: many, items: [_w('t', '상의', tags: long), _w('p', '하의', tags: long)], recs: [
      for (final e in many)
        RecommendationEntry(
            id: 'r${e.date.day}',
            itemIds: const ['t', 'p'],
            itemSummaries: const [],
            summaryText: '',
            triggerItemId: '',
            createdAt: _today,
            targetDate: e.date,
            targetTpoTag: '일상',
            weatherNote: '최고 13°C라 긴팔에 아우터를 더했어요 · 비 예보에도 무리 없는 조합이에요'),
    ]);
    final r = await _tools(f).getCalendar({'from': '2026-11-16', 'to': '2026-11-29'});
    expect(r.observation.length, lessThanOrEqualTo(askObservationMaxChars));
    expect(r.observation, endsWith('(이하 생략)'));
  });
}
