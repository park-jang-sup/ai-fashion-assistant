// AI에게 부탁하기 — 도구 계층(docs/task_agent_ask_v1.md §2-2·§2-3), 가짜 데이터.
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

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
      final t = askTools(FakeAskData());
      expect((await t.getCalendar({'from': '2026-11-20', 'to': '2026-11-16'})).ok, isFalse);
      expect((await t.getCalendar({'from': '2026-11-16', 'to': '2026-12-01'})).observation, contains('최대 14일'));
      expect((await t.getCalendar({'from': '11/16', 'to': '2026-11-20'})).ok, isFalse);
    });
    test('일정 없음', () async {
      final r = await askTools(FakeAskData()).getCalendar({'from': '2026-11-16', 'to': '2026-11-22'});
      expect(r.ok, isTrue);
      expect(r.observation, contains('일정 없음'));
    });
    test('예정 일정과 준비된 추천 요약, 기록 일정', () async {
      final f = FakeAskData(
        entries: [askEntry(DateTime(2026, 11, 17), '데이트'), askEntry(DateTime(2026, 11, 16), '일상', planned: false)],
        recs: [
          RecommendationEntry(
              id: 'r1',
              itemIds: const ['t1', 'p2'],
              itemSummaries: const [],
              summaryText: '',
              triggerItemId: '',
              createdAt: askToday,
              colorScore: 80,
              targetDate: DateTime(2026, 11, 17),
              targetTpoTag: '데이트'),
        ],
      );
      final r = await askTools(f).getCalendar({'from': '2026-11-16', 'to': '2026-11-22'});
      expect(r.observation, contains('2026-11-17(화) [데이트] 예정 — 준비된 추천: #7 상의 블랙 맨투맨·코튼(캐주얼)'));
      expect(r.observation, contains('80점'));
      expect(r.observation, contains('2026-11-16(월) [일상] 기록 — 착장 기록됨'));
      expect(r.items.map((i) => i.id), ['t1', 'p2']);
    });
  });

  group('get_weather', () {
    test('날짜별 최고·최저·강수·기온대·비, 7일 밖은 범위 밖', () async {
      final r = await askTools(FakeAskData(snap: askSnapshot())).getWeather({'from': '2026-11-17', 'to': '2026-11-23'});
      expect(r.observation, contains('2026-11-17(화): 최고 9°C 최저 2°C 강수 70% · 추움 · 비'));
      expect(r.observation, contains('2026-11-21(토): 최고 4°C 최저 -3°C 강수 10% · 추움'));
      expect(r.observation, contains('2026-11-23(월): 예보 범위 밖'));
    });
    test('가정 예보면 표시, 조회 실패면 실패를 관찰로', () async {
      expect((await askTools(FakeAskData(snap: askSnapshot(assumed: true))).getWeather({'from': '2026-11-16', 'to': '2026-11-16'}))
          .observation, contains('테스트용 가정 예보'));
      final fail = await askTools(FakeAskData()).getWeather({'from': '2026-11-16', 'to': '2026-11-16'});
      expect(fail.ok, isFalse);
      expect(fail.observation, contains('예보를 불러오지 못했어요'));
    });
  });

  group('search_wardrobe', () {
    test('인자가 없으면 종류별 벌수', () async {
      final r = await askTools(FakeAskData()).searchWardrobe({});
      expect(r.observation, '옷장 8벌 — 상의 2, 하의 2, 아우터 2, 신발 1, 액세서리 1');
    });
    test('인자 없는 조회의 총수는 종류별 벌수의 합 — "전신"(전신 사진)은 넣지 않는다', () async {
      final items = [...askWardrobe, askW('b1', '전신', tags: ['전신사진']), askW('b2', '전신')];
      final r = await askTools(FakeAskData(items: items)).searchWardrobe({});
      expect(r.observation, '옷장 8벌 — 상의 2, 하의 2, 아우터 2, 신발 1, 액세서리 1');
      final onlyPhotos = await askTools(FakeAskData(items: [askW('b1', '전신')])).searchWardrobe({});
      expect(onlyPhotos.observation, '옷장이 비어 있어요');
    });
    test('키워드 조회에서도 "전신"(전신 사진)은 빼고 찾는다(§10 D)', () async {
      final items = [...askWardrobe, askW('b1', '전신', tags: ['올블랙', '겨울']), askW('b2', '전신', color: '블랙')];
      final t = askTools(FakeAskData(items: items));
      expect((await t.searchWardrobe({'keyword': '겨울'})).observation, isNot(contains('전신')));
      expect((await t.searchWardrobe({'keyword': '블랙'})).observation, contains('일치 5벌')); // t1·p1·o2·s1·a1 — 전신 b2는 빠짐
      expect((await t.searchWardrobe({'keyword': '올블랙'})).observation, contains('일치하는 옷 없음'));
    });
    test('종류·키워드로 찾고 최대 8벌', () async {
      final r = await askTools(FakeAskData()).searchWardrobe({'category': '아우터', 'keyword': '퀼팅안감'});
      expect(r.observation, contains('일치 1벌'));
      expect(r.observation, contains('아우터 카키 코듀로이·퀼팅안감·가을/겨울(캐주얼)'));
      final many = [for (var i = 0; i < 12; i++) askW('x$i', '상의', tags: ['반팔'], day: i + 1)];
      final r2 = await askTools(FakeAskData(items: many)).searchWardrobe({'category': '상의'});
      expect(r2.observation, contains('일치 12벌(앞 8벌)'));
      expect(r2.items.length, 8);
    });
    test('잘못된 종류·빈 옷장·일치 없음', () async {
      expect((await askTools(FakeAskData()).searchWardrobe({'category': '모자'})).ok, isFalse);
      expect((await askTools(FakeAskData(items: const [])).searchWardrobe({})).observation, '옷장이 비어 있어요');
      expect((await askTools(FakeAskData()).searchWardrobe({'keyword': '패딩'})).observation, contains('일치하는 옷 없음'));
    });
    test('category만 주면 그 종류 전체 요약 — 앞 8벌 밖의 한겨울용도 보인다', () async {
      final outers = [
        for (var i = 0; i < 10; i++) askW('n$i', '아우터', tags: ['바람막이', '나일론', '간절기'], day: 20 + i),
        askW('w1', '아우터', color: '퍼플', tags: ['후드', '캔버스', '겨울', '양털안감'], day: 1),
        askW('w2', '아우터', color: '카키', tags: ['코듀로이', '퀼팅안감', '워크자켓', '가을/겨울'], day: 2),
      ];
      final r = await askTools(FakeAskData(items: outers)).searchWardrobe({'category': '아우터'});
      final o = r.observation;
      expect(o, contains('일치 12벌(앞 8벌)'));
      expect(o, isNot(contains('1. 아우터 퍼플'))); // 목록 8벌에는 없지만
      expect(o, contains('아우터 12벌 요약'));
      expect(o, contains('계절·두께 태그: 간절기 10, 가을/겨울 1, 겨울 1, 양털안감 1, 퀼팅안감 1'));
      expect(o, contains('종류·소재 태그(2벌 이상): 나일론 10, 바람막이 10'));
      // 최근 등록 먼저(w2가 w1보다 나중에 등록).
      expect(o, contains('옷 2벌:\n- 카키 코듀로이·퀼팅안감·워크자켓·가을/겨울(캐주얼)\n- 퍼플 후드·캔버스·겨울·양털안감(캐주얼)'));
      expect(o.length, lessThanOrEqualTo(askObservationMaxChars));
      // 키워드가 있으면 요약을 붙이지 않는다.
      expect((await askTools(FakeAskData(items: outers)).searchWardrobe({'category': '아우터', 'keyword': '겨울'})).observation,
          isNot(contains('요약')));
      final none = await askTools(FakeAskData()).searchWardrobe({'category': '신발'});
      expect(none.observation, contains('옷: 없음'));
    });
    test('요약이 길어도 1,500자 안', () async {
      final many = [
        for (var i = 0; i < 60; i++)
          askW('m$i', '상의', tags: ['태그$i', '겨울', '가을겨울소재$i', '긴태그이름입니다$i'], day: 1 + i % 28),
      ];
      final r = await askTools(FakeAskData(items: many)).searchWardrobe({'category': '상의'});
      expect(r.observation.length, lessThanOrEqualTo(askObservationMaxChars));
    });
    test('한 글자 검색어는 태그·색과 완전히 같을 때만, 두 글자 이상은 부분 일치', () async {
      final items = [
        askW('a', '상의', color: '네이비', tags: ['반팔']),
        askW('b', '상의', tags: ['울', '니트']),
        askW('c', '상의', tags: ['울혼방']),
        askW('d', '아우터', tags: ['비', '방수']),
      ];
      final t = askTools(FakeAskData(items: items));
      expect((await t.searchWardrobe({'keyword': '비'})).observation, contains('일치 1벌'));
      expect((await t.searchWardrobe({'keyword': '울'})).observation, contains('일치 1벌'));
      expect((await t.searchWardrobe({'keyword': '울혼'})).observation, contains('일치 1벌'));
      expect((await t.searchWardrobe({'keyword': '네이'})).observation, contains('일치 1벌'));
    });
  });

  group('preview_outfit — 저장 없음', () {
    test('예보 안 날짜는 기온대 반영 조합과 날씨 문구', () async {
      final f = FakeAskData(snap: askSnapshot());
      final r = await askTools(f).previewOutfit({'date': '2026-11-20', 'tpo': '모임'});
      expect(r.ok, isTrue);
      expect(r.observation, contains('2026-11-20(금) [모임] 미리 보기(저장 안 함)'));
      expect(r.observation, contains('날씨: 최고 13°C'));
      expect(r.items, isNotEmpty);
      expect(f.writes, isEmpty);
    });
    test('예보 범위 밖은 오늘 기온대 기준(v2 §2-C), 예보 실패면 날씨 없이', () async {
      expect((await askTools(FakeAskData(snap: askSnapshot())).previewOutfit({'date': '2026-11-30', 'tpo': '일상'})).observation,
          contains('예보 범위 밖이라 오늘 기온대 기준'));
      expect((await askTools(FakeAskData()).previewOutfit({'date': '2026-11-17', 'tpo': '일상'})).observation,
          contains('예보를 불러오지 못해 날씨 없이'));
    });
    test('인자 오류·옷 부족', () async {
      expect((await askTools(FakeAskData()).previewOutfit({'date': '2026-11-17', 'tpo': '파티'})).ok, isFalse);
      expect((await askTools(FakeAskData()).previewOutfit({'date': '내일', 'tpo': '일상'})).ok, isFalse);
      expect((await askTools(FakeAskData(items: [askWardrobe.first])).previewOutfit({'date': '2026-11-17', 'tpo': '일상'})).ok,
          isFalse);
    });
  });

  group('add_plan — 유일한 쓰기', () {
    test('검증: 지난 날짜·60일 밖·잘못된 태그는 거절(쓰지 않음)', () async {
      final f = FakeAskData(snap: askSnapshot());
      final t = askTools(f);
      expect(t.validatePlan({'date': '2026-11-15', 'tpo': '모임'}), contains('지난 날짜'));
      expect(t.validatePlan({'date': '2027-01-16', 'tpo': '모임'}), contains('60일'));
      expect(t.validatePlan({'date': '2026-11-20', 'tpo': '파티'}), contains('인자 오류'));
      expect(t.validatePlan({'date': '2026-11-20', 'tpo': '모임'}), isNull);
      expect((await t.addPlan({'date': '2026-11-15', 'tpo': '모임'})).ok, isFalse);
      expect(f.writes, isEmpty);
    });
    test('같은 날짜에 예정 일정이 있으면 새로 넣지 않는다', () async {
      final f = FakeAskData(entries: [askEntry(DateTime(2026, 11, 20), '출근')]);
      final r = await askTools(f).addPlan({'date': '2026-11-20', 'tpo': '모임'});
      expect(r.observation, contains('이미 [출근] 예정 일정'));
      expect(f.writes, isEmpty);
    });
    test('예보 범위 안이면 등록하고 바로 준비, 결과에 조합·점수·문구', () async {
      final f = FakeAskData(snap: askSnapshot());
      final r = await askTools(f).addPlan({'date': '2026-11-20', 'tpo': '모임'});
      expect(f.writes, [(DateTime(2026, 11, 20), '모임', true)]);
      expect(r.observation, contains('일정을 등록하고 코디를 준비했어요'));
      expect(r.observation, contains('82점'));
      expect(r.plannedDate, DateTime(2026, 11, 20));
      expect(r.items.map((i) => i.id), ['t2', 'p1', 'o2', 's1']);
    });
    test('예보 범위 밖이면 등록만', () async {
      final f = FakeAskData(snap: askSnapshot());
      final r = await askTools(f).addPlan({'date': '2026-11-25', 'tpo': '면접'});
      expect(f.writes, [(DateTime(2026, 11, 25), '면접', false)]);
      expect(r.observation, contains('코디는 일정이 가까워지면 예보를 보고 준비해요'));
    });
    test('준비에 실패하면 등록 사실과 실패를 함께', () async {
      final f = FakeAskData(snap: askSnapshot(), prepareResult: false);
      final r = await askTools(f).addPlan({'date': '2026-11-18', 'tpo': '일상'});
      expect(r.observation, contains('코디는 준비하지 못했어요'));
      expect(r.plannedDate, DateTime(2026, 11, 18));
    });
  });

  test('관찰은 1,500자 이하로 줄인다', () async {
    final many = [
      for (var i = 0; i < 14; i++) askEntry(DateTime(2026, 11, 16).add(Duration(days: i)), '일상'),
    ];
    final long = List.generate(30, (i) => '아주긴태그$i');
    final f = FakeAskData(entries: many, items: [askW('t', '상의', tags: long), askW('p', '하의', tags: long)], recs: [
      for (final e in many)
        RecommendationEntry(
            id: 'r${e.date.day}',
            itemIds: const ['t', 'p'],
            itemSummaries: const [],
            summaryText: '',
            triggerItemId: '',
            createdAt: askToday,
            targetDate: e.date,
            targetTpoTag: '일상',
            weatherNote: '최고 13°C라 긴팔에 아우터를 더했어요 · 비 예보에도 무리 없는 조합이에요'),
    ]);
    final r = await askTools(f).getCalendar({'from': '2026-11-16', 'to': '2026-11-29'});
    expect(r.observation.length, lessThanOrEqualTo(askObservationMaxChars));
    expect(r.observation, endsWith('(이하 생략)'));
  });
}
