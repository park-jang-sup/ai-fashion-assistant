// response_signal.dart의 순수 함수 단위 테스트. Firestore 없이 결정적.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/services/response_signal.dart';

final _now = DateTime(2026, 8, 15, 12);

RecommendationEntry _entry({
  required String id,
  required DateTime createdAt,
  String? userChoice,
  bool dismissed = false,
}) {
  return RecommendationEntry(
    id: id,
    itemIds: const [],
    itemSummaries: const [],
    summaryText: '',
    triggerItemId: '',
    createdAt: createdAt,
    userChoice: userChoice,
    dismissed: dismissed,
  );
}

void main() {
  group('summarizeRecentResponses — N=72시간 경계', () {
    test('정확히 72시간 지난 null은 무반응', () {
      final entries = [
        _entry(id: 'a', createdAt: _now.subtract(const Duration(hours: 72))),
      ];
      final result = summarizeRecentResponses(candidates: entries, now: _now);
      expect(result.noResponseCount, 1);
      expect(result.pendingCount, 0);
    });

    test('71시간 59분 지난 null은 판정보류(무반응 아님)', () {
      final entries = [
        _entry(
          id: 'a',
          createdAt: _now.subtract(const Duration(hours: 71, minutes: 59)),
        ),
      ];
      final result = summarizeRecentResponses(candidates: entries, now: _now);
      expect(result.pendingCount, 1);
      expect(result.noResponseCount, 0);
    });

    test('판정보류는 sampleSize에 포함되지 않는다', () {
      final entries = [
        _entry(id: 'a', createdAt: _now.subtract(const Duration(hours: 1))),
      ];
      final result = summarizeRecentResponses(candidates: entries, now: _now);
      expect(result.sampleSize, 0);
      expect(result.pendingCount, 1);
    });
  });

  group('summarizeRecentResponses — 응답 분류', () {
    test('accepted는 respondedCount·acceptedCount 둘 다 증가', () {
      final entries = [
        _entry(
          id: 'a',
          createdAt: _now.subtract(const Duration(hours: 1)),
          userChoice: RecommendationEntry.choiceAccepted,
        ),
      ];
      final result = summarizeRecentResponses(candidates: entries, now: _now);
      expect(result.respondedCount, 1);
      expect(result.acceptedCount, 1);
      expect(result.sampleSize, 1);
    });

    test('rejected_with_alternative는 respondedCount만 증가, acceptedCount는 그대로', () {
      final entries = [
        _entry(
          id: 'a',
          createdAt: _now.subtract(const Duration(hours: 1)),
          userChoice: RecommendationEntry.choiceRejectedWithAlternative,
        ),
      ];
      final result = summarizeRecentResponses(candidates: entries, now: _now);
      expect(result.respondedCount, 1);
      expect(result.acceptedCount, 0);
    });

    test('응답은 생성 후 경과 시간과 무관하게 항상 응답으로 셈(72시간 미만이어도)', () {
      final entries = [
        _entry(
          id: 'a',
          createdAt: _now.subtract(const Duration(hours: 1)),
          userChoice: RecommendationEntry.choiceAccepted,
        ),
      ];
      final result = summarizeRecentResponses(candidates: entries, now: _now);
      expect(result.respondedCount, 1);
      expect(result.pendingCount, 0);
    });
  });

  group('summarizeRecentResponses — dismissed 제외 (docs §2-1 yPyw4DC2 실측 재현)', () {
    test('dismissed=true 문서는 창에서 완전히 빠지고 그다음 문서가 대신 들어온다', () {
      // windowSize=3으로 좁혀서 재현: 최신순으로 [dismissed, 무반응, 무반응, 무반응]
      // 이 있으면 dismissed를 빼고 나머지 3건(전부 무반응)이 창을 채워야 한다.
      final entries = [
        _entry(
          id: 'newest-dismissed',
          createdAt: _now.subtract(const Duration(hours: 100)),
          dismissed: true,
        ),
        _entry(id: 'b', createdAt: _now.subtract(const Duration(hours: 101))),
        _entry(id: 'c', createdAt: _now.subtract(const Duration(hours: 102))),
        _entry(id: 'd', createdAt: _now.subtract(const Duration(hours: 103))),
      ];
      final result = summarizeRecentResponses(
        candidates: entries,
        now: _now,
        windowSize: 3,
      );
      // dismissed 문서가 빠졌으므로 b·c·d 세 건(전부 72시간 이상 지난 null)만 판정 대상.
      expect(result.noResponseCount, 3);
      expect(result.sampleSize, 3);
    });
  });

  group('summarizeRecentResponses — 정렬·윈도우', () {
    test('candidates가 뒤섞인 순서로 들어와도 createdAt 최신 windowSize건만 판정한다', () {
      final entries = [
        _entry(id: 'old', createdAt: _now.subtract(const Duration(hours: 200))),
        _entry(
          id: 'accepted-recent',
          createdAt: _now.subtract(const Duration(hours: 1)),
          userChoice: RecommendationEntry.choiceAccepted,
        ),
        _entry(id: 'mid', createdAt: _now.subtract(const Duration(hours: 100))),
      ];
      final result = summarizeRecentResponses(
        candidates: entries,
        now: _now,
        windowSize: 2,
      );
      // 최신 2건: accepted-recent(응답), mid(무반응, 100시간 경과) — old는 창 밖.
      expect(result.respondedCount, 1);
      expect(result.noResponseCount, 1);
      expect(result.sampleSize, 2);
    });

    test('후보가 windowSize보다 적으면 있는 만큼만 집계한다(표본 부족 판단은 이 함수의 몫이 아니다)', () {
      final entries = [
        _entry(id: 'a', createdAt: _now.subtract(const Duration(hours: 100))),
      ];
      final result = summarizeRecentResponses(
        candidates: entries,
        now: _now,
        windowSize: 5,
      );
      expect(result.sampleSize, 1);
    });

    test('빈 리스트면 전부 0', () {
      final result = summarizeRecentResponses(candidates: const [], now: _now);
      expect(result.sampleSize, 0);
      expect(result.respondedCount, 0);
      expect(result.acceptedCount, 0);
      expect(result.noResponseCount, 0);
      expect(result.pendingCount, 0);
    });
  });
}
