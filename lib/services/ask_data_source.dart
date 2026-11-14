// AI에게 부탁하기 — 로그인 사용자 본인의 데이터(docs/task_agent_ask_v1.md §2-2).
// 도구 계층(ask_tools.dart)은 AskDataSource 인터페이스만 보고, 앱에서는 이 구현이
// 기존 Firestore·예보 함수를 그대로 부른다. 쓰기는 addPlan 하나뿐이다.
import '../models/outfit_calendar_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/wardrobe_item.dart';
import 'agent_planner.dart';
import 'ask_tools.dart';
import 'firestore_service.dart';
import 'weather_service.dart';

class FirestoreAskDataSource implements AskDataSource {
  final String uid;
  FirestoreAskDataSource(this.uid);

  @override
  Future<List<OutfitCalendarEntry>> calendar(DateTime from, DateTime to) =>
      FirestoreService.calendarEntriesForRange(uid, from, to);

  @override
  Future<List<RecommendationEntry>> recommendations(DateTime from, DateTime to) {
    // 기존 조회(가운데 날짜 ± 일수)로 기간을 덮는다.
    final days = to.difference(from).inDays;
    final center = from.add(Duration(days: days ~/ 2));
    return FirestoreService.recommendationsInDateRangeSilently(uid, center, (days + 1) ~/ 2 + 1);
  }

  @override
  Future<WeatherSnapshot?> weather() async {
    // 일일 추천과 같은 방법 — 지역 설정, 가정 예보 포함.
    final profile = await FirestoreService.getUserProfileSilently(uid);
    return WeatherService.fetch(latitude: profile?.regionLatitude, longitude: profile?.regionLongitude);
  }

  @override
  Future<List<WardrobeItem>> wardrobe() => FirestoreService.wardrobeStream(uid).first;

  @override
  Future<Set<String>> recentItemIds() => AgentPlanner.recentItemIdsFor(uid);

  @override
  Future<AskPlanWrite> addPlan(DateTime date, String tpo, {required bool prepare}) async {
    final draft = OutfitCalendarEntry(
      id: '',
      date: date,
      tpoTag: tpo,
      status: OutfitCalendarEntry.statusPlanned,
      createdAt: DateTime.now(),
      createdVia: OutfitCalendarEntry.createdViaAsk,
    );
    final id = await FirestoreService.addCalendarEntry(uid, draft);
    if (!prepare) return const AskPlanWrite(prepared: false);
    final plan = OutfitCalendarEntry(
      id: id,
      date: draft.date,
      tpoTag: tpo,
      status: draft.status,
      createdAt: draft.createdAt,
      createdVia: draft.createdVia,
    );
    final prepared = await AgentPlanner.preparePlanNow(uid, plan);
    final rec = prepared ? await FirestoreService.recommendationForDateSilently(uid, date) : null;
    return AskPlanWrite(prepared: prepared && rec != null, recommendation: rec);
  }
}
