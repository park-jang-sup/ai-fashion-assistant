// 착장 기록 읽기와 데모용 예시 착장(docs/task_agent_ask_v2.md §2-F).
import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/outfit_calendar_entry.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

OutfitCalendarEntry _rec(int daysAgo, String tpo, List<String> ids) => OutfitCalendarEntry(
      id: 'r$daysAgo',
      date: askToday.subtract(Duration(days: daysAgo)),
      tpoTag: tpo,
      status: OutfitCalendarEntry.statusRecorded,
      itemIds: ids,
      createdAt: askToday,
    );

RecommendationEntry _reaction(String choice) => RecommendationEntry(
      id: 'x$choice',
      itemIds: const [],
      itemSummaries: const [],
      summaryText: '',
      triggerItemId: '',
      createdAt: askToday,
      userChoice: choice,
    );

List<WardrobeItem> _demoWardrobe() {
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
  group('get_style_history', () {
    test('자주 입은 옷·색·격식, 상황별 최근 착장, 추천 반응, 기록에 없는 옷', () async {
      final data = FakeAskData(entries: [
        _rec(1, '출근', ['t2', 'p1', 's1']),
        _rec(3, '일상', ['t1', 'p2', 's1']),
        _rec(5, '출근', ['t2', 'p1', 'o2']),
        _rec(70, '데이트', ['t1', 'p1']), // 60일 밖 — FakeAskData는 기간으로 거른다
      ], recs: [
        _reaction(RecommendationEntry.choiceAccepted),
        _reaction(RecommendationEntry.choiceAccepted),
        _reaction(RecommendationEntry.choiceRejectedWithAlternative),
      ]);
      final t = askTools(data);
      final r = await t.getStyleHistory({});
      final o = r.observation;
      int n(String id) => t.book.numberOf(askWardrobe.firstWhere((i) => i.id == id));
      expect(o, startsWith('최근 60일 착장 기록 3건'));
      expect(o, contains('#${n('s1')} 신발 블랙 스니커즈·가죽(캐주얼) 2회'));
      expect(o, contains('상황별 가장 최근 착장: [출근] 11/15(일) #${n('t2')} #${n('p1')} #${n('s1')}, [일상] 11/13(금)'));
      expect(o, contains('추천 반응: 그대로 입음 2회, 다르게 입음 1회'));
      expect(o, contains('60일 동안 기록에 없는 옷 2벌 — 예: #${n('o1')}'));
      expect(r.display, '최근 60일 착장 기록 3건을 확인했어요');
    });

    test('기록이 없으면 그 사실만', () async {
      final r = await askTools(FakeAskData()).getStyleHistory({});
      expect(r.observation, '아직 착장 기록이 없어요');
    });

    test('preview_outfit unworn_first — 종류마다 최근 60일에 입지 않은 옷으로', () async {
      final t = askTools(FakeAskData(snap: askSnapshot(), entries: [_rec(2, '일상', ['t1', 'p1'])]));
      final r = await t.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'unworn_first': true});
      expect(r.observation, contains('최근 60일에 입지 않은 옷으로 좁힘: 상의 1벌, 하의 1벌'));
      final ids = {for (final i in r.items) i.id};
      expect(ids, containsAll(['t2', 'p2']));
    });
  });

  group('데모용 예시 착장', () {
    final wardrobe = _demoWardrobe();
    final today = DateTime(2026, 11, 16, 9);

    test('지난 14일 안에 6건, 상황을 섞고, 불러올 때마다 같은 결과', () {
      final a = AgentPlanner.demoOutfitRecordsFor(wardrobe, today);
      final b = AgentPlanner.demoOutfitRecordsFor(List.of(wardrobe.reversed), today);
      expect(a.length, 6);
      expect([for (final e in a) e.itemIds], [for (final e in b) e.itemIds]);
      final day = DateTime(2026, 11, 16);
      for (final e in a) {
        expect(e.isDemo, isTrue);
        expect(e.status, OutfitCalendarEntry.statusRecorded);
        expect(e.createdVia, OutfitCalendarEntry.createdViaDemoExample);
        expect(e.date.isBefore(day) && !e.date.isBefore(day.subtract(const Duration(days: 14))), isTrue);
        expect(e.itemIds, isNotEmpty);
        expect(e.toFirestore()['isDemo'], isTrue);
      }
      expect({for (final e in a) e.tpoTag}.length, greaterThanOrEqualTo(4));
      // 조합이 서로 겹치지 않게 앞에서 쓴 옷을 뒤로 미룬다.
      expect({for (final e in a) e.itemIds.join(',')}.length, 6);
      // ignore: avoid_print
      for (final e in a) {
        // ignore: avoid_print
        print('예시 착장 ${e.date.month}/${e.date.day} [${e.tpoTag}] ${e.itemSummaries.join(', ')}');
      }
    });
  });
}
