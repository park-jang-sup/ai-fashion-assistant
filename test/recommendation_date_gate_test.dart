// FirestoreService.selectDateRecommendation의 순수 로직 단위 테스트.
// recommendationForDateSilently의 "이 날짜 일정 중복 게이트" 문서 선택을
// Firestore 없이 검증한다(candidates 리스트 -> 대상/정리 대상).
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/services/firestore_service.dart';

RecommendationEntry _entry({
  required String id,
  required String triggerItemId,
  required DateTime createdAt,
}) {
  return RecommendationEntry(
    id: id,
    itemIds: const [],
    itemSummaries: const [],
    summaryText: '',
    triggerItemId: triggerItemId,
    createdAt: createdAt,
  );
}

void main() {
  group('FirestoreService.selectDateRecommendation', () {
    test('새 옷 등록 추천만 있으면 일정 중복 게이트 대상이 아니므로 대상 없음', () {
      final candidates = [
        _entry(id: 'a', triggerItemId: 'item-1', createdAt: DateTime(2026, 7, 28, 9)),
        _entry(id: 'b', triggerItemId: 'item-2', createdAt: DateTime(2026, 7, 28, 10)),
      ];
      final result = FirestoreService.selectDateRecommendation(candidates);
      expect(result.target, isNull);
      expect(result.toDismiss, isEmpty);
    });

    test('일정 기반 추천 1건만 있으면 그대로 대상', () {
      final entry = _entry(id: 'a', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 9));
      final result = FirestoreService.selectDateRecommendation([entry]);
      expect(result.target?.id, 'a');
      expect(result.toDismiss, isEmpty);
    });

    test('새 옷 추천과 일정 추천이 섞이면 일정 추천만 대상, 새 옷 추천은 정리 대상도 아님', () {
      final scheduleEntry =
          _entry(id: 'sched', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 9));
      final newItemEntry =
          _entry(id: 'new-item', triggerItemId: 'item-1', createdAt: DateTime(2026, 7, 28, 10));
      final result = FirestoreService.selectDateRecommendation([newItemEntry, scheduleEntry]);
      expect(result.target?.id, 'sched');
      expect(result.toDismiss, isEmpty);
    });

    test('새 옷 추천이 섞이고 일정 추천도 여럿이면, 정리 대상에 새 옷 추천은 절대 포함되지 않음', () {
      final olderSchedule =
          _entry(id: 'sched-older', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 8));
      final newerSchedule =
          _entry(id: 'sched-newer', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 11));
      final newItemEntry =
          _entry(id: 'new-item', triggerItemId: 'item-1', createdAt: DateTime(2026, 7, 28, 12));
      final result = FirestoreService
          .selectDateRecommendation([newItemEntry, olderSchedule, newerSchedule]);
      expect(result.target?.id, 'sched-newer');
      expect(result.toDismiss.map((e) => e.id).toList(), ['sched-older']);
      expect(result.toDismiss.any((e) => e.triggerItemId.isNotEmpty), isFalse);
    });

    test('일정 기반 추천이 2건 이상이면 최신 1건만 대상, 나머지는 정리 대상', () {
      final older = _entry(id: 'older', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 9));
      final newer = _entry(id: 'newer', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 11));
      final middle = _entry(id: 'middle', triggerItemId: '', createdAt: DateTime(2026, 7, 28, 10));
      final result = FirestoreService.selectDateRecommendation([older, newer, middle]);
      expect(result.target?.id, 'newer');
      expect(result.toDismiss.map((e) => e.id).toSet(), {'older', 'middle'});
    });

    test('빈 리스트면 대상도 정리 대상도 없음', () {
      final result = FirestoreService.selectDateRecommendation(const []);
      expect(result.target, isNull);
      expect(result.toDismiss, isEmpty);
    });
  });
}
