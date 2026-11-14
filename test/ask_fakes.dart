// AI에게 부탁하기 테스트 공용 가짜 데이터(옷장·일정·7일 예보) — 도구·엔진 테스트가 같이 쓴다.
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/outfit_calendar_entry.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';

WardrobeItem askW(String id, String category,
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

final askWardrobe = [
  askW('t1', '상의', tags: ['맨투맨', '코튼']),
  askW('t2', '상의', color: '화이트', formality: '세미포멀', tags: ['셔츠', '가을/겨울']),
  askW('p1', '하의', tags: ['슬랙스', '사계절'], formality: '세미포멀'),
  askW('p2', '하의', color: '차콜', tags: ['데님', '사계절']),
  askW('o1', '아우터', color: '카키', tags: ['코듀로이', '퀼팅안감', '가을/겨울']),
  askW('o2', '아우터', tags: ['블레이저', '봄가을'], formality: '세미포멀'),
  askW('s1', '신발', tags: ['스니커즈', '가죽']),
  askW('a1', '액세서리', sub: '가방', tags: ['토트백']),
];

final askToday = DateTime(2026, 11, 16); // 월요일

WeatherSnapshot askSnapshot({bool assumed = false}) => WeatherSnapshot(
      current: const CurrentWeather(tempC: 10, weatherCode: 3),
      daily: [
        for (var i = 0; i < 7; i++)
          DailyWeather(
            date: askToday.add(Duration(days: i)),
            maxTempC: [14.0, 9.0, 12.0, 16.0, 13.0, 4.0, 11.0][i],
            minTempC: [6.0, 2.0, 5.0, 8.0, 5.0, -3.0, 3.0][i],
            precipitationProbability: [10, 70, 20, 0, 30, 10, 0][i],
          ),
      ],
      isAssumed: assumed,
    );

class FakeAskData implements AskDataSource {
  List<OutfitCalendarEntry> entries;
  List<RecommendationEntry> recs;
  WeatherSnapshot? snap;
  List<WardrobeItem> items;
  bool prepareResult;
  final writes = <(DateTime, String, bool)>[];
  FakeAskData({
    this.entries = const [],
    this.recs = const [],
    this.snap,
    List<WardrobeItem>? items,
    this.prepareResult = true,
  }) : items = items ?? askWardrobe;

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
        createdAt: askToday,
        colorScore: 82,
        targetDate: date,
        targetTpoTag: tpo,
        weatherNote: '최고 13°C라 긴팔에 아우터를 더했어요',
      ),
    );
  }
}

OutfitCalendarEntry askEntry(DateTime d, String tpo, {bool planned = true}) => OutfitCalendarEntry(
      id: 'e${d.day}',
      date: d,
      tpoTag: tpo,
      status: planned ? OutfitCalendarEntry.statusPlanned : OutfitCalendarEntry.statusRecorded,
      itemIds: planned ? const [] : const ['t1'],
      createdAt: askToday,
    );

AskTools askTools(FakeAskData f) => AskTools(f, now: () => DateTime(2026, 11, 16, 10));

