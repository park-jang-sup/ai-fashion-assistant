// AgentPlanner.recentItemIdsFrom의 순수 로직 단위 테스트.
// 최근 추천 이력에서 "동점 타이브레이커용 감점 대상"을 뽑아내는 부분만
// 다룬다(Firestore 호출 없음).
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';

RecommendationEntry _entry({
  required String id,
  required List<String> itemIds,
  required DateTime createdAt,
  String? userChoice,
}) {
  return RecommendationEntry(
    id: id,
    itemIds: itemIds,
    itemSummaries: const [],
    summaryText: '',
    triggerItemId: '',
    createdAt: createdAt,
    userChoice: userChoice,
  );
}

void main() {
  final now = DateTime(2026, 7, 28, 9);

  group('recentItemIdsFrom', () {
    test('창 안의 추천 아이템을 모두 모은다', () {
      final result = AgentPlanner.recentItemIdsFrom(
        [
          _entry(id: 'r1', itemIds: ['a', 'b'], createdAt: now.subtract(const Duration(days: 1))),
          _entry(id: 'r2', itemIds: ['b', 'c'], createdAt: now.subtract(const Duration(days: 13))),
        ],
        now,
      );
      expect(result, {'a', 'b', 'c'});
    });

    test('창 밖의 추천은 제외한다', () {
      final result = AgentPlanner.recentItemIdsFrom(
        [
          _entry(id: 'old', itemIds: ['x'], createdAt: now.subtract(const Duration(days: 15))),
          _entry(id: 'new', itemIds: ['y'], createdAt: now.subtract(const Duration(days: 2))),
        ],
        now,
      );
      expect(result, {'y'});
    });

    test('창 길이를 좁히면 대상도 줄어든다', () {
      final entries = [
        _entry(id: 'r1', itemIds: ['a'], createdAt: now.subtract(const Duration(days: 1))),
        _entry(id: 'r2', itemIds: ['b'], createdAt: now.subtract(const Duration(days: 5))),
      ];
      expect(
        AgentPlanner.recentItemIdsFrom(entries, now, window: const Duration(days: 3)),
        {'a'},
      );
    });

    test('userChoice로 거르지 않는다 — 세는 건 착용이 아니라 노출이다', () {
      // 거절당한 조합도 이미 한 번 제시된 이상 다시 1순위로 올릴 이유가 없다.
      final result = AgentPlanner.recentItemIdsFrom(
        [
          _entry(
            id: 'r1',
            itemIds: ['a'],
            createdAt: now.subtract(const Duration(days: 1)),
            userChoice: RecommendationEntry.choiceAccepted,
          ),
          _entry(
            id: 'r2',
            itemIds: ['b'],
            createdAt: now.subtract(const Duration(days: 1)),
            userChoice: RecommendationEntry.choiceRejectedWithAlternative,
          ),
          _entry(id: 'r3', itemIds: ['c'], createdAt: now.subtract(const Duration(days: 1))),
        ],
        now,
      );
      expect(result, {'a', 'b', 'c'});
    });

    test('이력이 비면 빈 집합 — findForTpo가 현행과 동일하게 동작한다', () {
      expect(AgentPlanner.recentItemIdsFrom(const [], now), isEmpty);
    });
  });
}
