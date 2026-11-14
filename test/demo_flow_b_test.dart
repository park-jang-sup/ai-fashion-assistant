// 빈 캘린더에서도 에이전트가 보이게 — docs/task_demo_flow_v1.md 부분 B.
import 'package:ai_fashion_assistant/models/outfit_calendar_entry.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/screens/home_screen.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:flutter_test/flutter_test.dart';

OutfitCalendarEntry _entry(String status, {List<String> itemIds = const []}) => OutfitCalendarEntry(
      id: 'e',
      date: DateTime(2026, 11, 15),
      tpoTag: '모임',
      status: status,
      itemIds: itemIds,
      createdAt: DateTime(2026, 11, 14),
    );

void main() {
  group('할 일 없음 기록 — 수동은 매번, 자동은 하루 한 번', () {
    final now = DateTime(2026, 11, 14, 13, 30);
    test('수동 실행은 오늘 이미 남겼어도 남긴다', () {
      expect(AgentPlanner.shouldLogIdleCheck(manual: true, lastLoggedDay: '2026-11-14', now: now), isTrue);
    });
    test('자동 실행은 오늘 처음이면 남긴다', () {
      expect(AgentPlanner.shouldLogIdleCheck(manual: false, lastLoggedDay: null, now: now), isTrue);
      expect(AgentPlanner.shouldLogIdleCheck(manual: false, lastLoggedDay: '2026-11-13', now: now), isTrue);
    });
    test('자동 실행은 오늘 이미 남겼으면 남기지 않는다', () {
      expect(AgentPlanner.shouldLogIdleCheck(manual: false, lastLoggedDay: '2026-11-14', now: now), isFalse);
    });
    test('날짜 키', () => expect(AgentPlanner.dayKey(DateTime(2026, 1, 5, 23)), '2026-01-05'));
  });

  group('예시 일정 — 다가오는 planned 일정이 없을 때만', () {
    test('비어 있으면 넣는다', () => expect(AgentPlanner.shouldAddDemoPlan(const []), isTrue));
    test('기록(recorded)만 있으면 넣는다', () {
      expect(AgentPlanner.shouldAddDemoPlan([_entry('recorded', itemIds: ['a'])]), isTrue);
    });
    test('planned가 하나라도 있으면 넣지 않는다', () {
      expect(AgentPlanner.shouldAddDemoPlan([_entry('recorded', itemIds: ['a']), _entry('planned')]), isFalse);
    });
    test('상황 태그는 일상', () => expect(AgentPlanner.demoPlanTpoTag, '일상'));
  });

  group('예시 일정 표시(isDemo)는 켰을 때만 저장한다', () {
    test('일정', () {
      final plain = _entry('planned').toFirestore();
      expect(plain.containsKey('isDemo'), isFalse);
      final demo = OutfitCalendarEntry(
              id: '', date: DateTime(2026, 11, 15), tpoTag: '일상', status: 'planned',
              createdAt: DateTime(2026), isDemo: true)
          .toFirestore();
      expect(demo['isDemo'], isTrue);
    });
    test('추천', () {
      RecommendationEntry rec({bool isDemo = false}) => RecommendationEntry(
          id: '', itemIds: const ['a'], itemSummaries: const [], summaryText: '', triggerItemId: '',
          createdAt: DateTime(2026), isDemo: isDemo);
      expect(rec().toFirestore().containsKey('isDemo'), isFalse);
      expect(rec(isDemo: true).toFirestore()['isDemo'], isTrue);
    });
  });

  group('홈 추천 카드 제목 — 추천이 가리키는 일정 날짜에 맞춘다', () {
    final now = DateTime(2026, 11, 14, 9);
    String t(DateTime? d, [String? tag = '모임']) => homeRecommendationTitle(targetDate: d, tpoTag: tag, now: now);
    test('오늘·내일·모레', () {
      expect(t(DateTime(2026, 11, 14)), '오늘 [모임] 추천 코디');
      expect(t(DateTime(2026, 11, 15)), '내일 [모임] 추천 코디');
      expect(t(DateTime(2026, 11, 16)), '모레 [모임] 추천 코디');
      expect(t(DateTime(2026, 11, 17)), '3일 뒤 [모임] 추천 코디');
    });
    test('지난 날짜는 날짜로', () => expect(t(DateTime(2026, 11, 12)), '11월 12일 [모임] 추천 코디'));
    test('일정 없이 만든 추천(새 옷 등록 계기)은 그대로', () {
      expect(t(DateTime(2026, 11, 14), null), '오늘의 추천 코디');
      expect(t(null), '오늘의 추천 코디');
    });
  });
}
