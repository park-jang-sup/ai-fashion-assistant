// AgentPlanner.buildFallbackNote의 순수 로직 단위 테스트.
// isFallback 원인(카테고리 부족 vs 궁합 점수 낮음)에 따라 다른 문구가
// 선택되는지, Firestore/Gemini 없이 결정적으로 검증한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';

void main() {
  group('buildFallbackNote', () {
    test('카테고리 차선(matchIsFallback=true)이면 부족 카테고리와 점수를 문구에 담는다', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: true,
        mismatchedCategories: const ['상의', '아우터'],
        bestScore: 62,
        dateLabel: '모레',
        tpoTag: '소개팅',
      );
      expect(note, isNotNull);
      expect(note, contains('상의·아우터'));
      expect(note, contains('62점'));
      expect(note, contains('모레'));
      expect(note, contains('소개팅'));
    });

    test('matchIsFallback=true인데 mismatchedCategories가 비어 있으면 null(배지 안 띄움)', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: true,
        mismatchedCategories: const [],
        bestScore: 62,
        dateLabel: '내일',
        tpoTag: '일상',
      );
      expect(note, isNull);
    });

    test('격식은 맞지만 점수가 낮으면(< _lowScoreFloor) 카테고리 언급 없는 다른 문구를 쓴다', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: false,
        mismatchedCategories: const [],
        bestScore: 45,
        dateLabel: '오늘',
        tpoTag: '데이트',
      );
      expect(note, isNotNull);
      expect(note, contains('45점'));
      expect(note, isNot(contains('부족해')));
    });

    test('격식도 맞고 점수도 기준 이상이면 null(배지 안 띄움)', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: false,
        mismatchedCategories: const [],
        bestScore: 80,
        dateLabel: '오늘',
        tpoTag: '일상',
      );
      expect(note, isNull);
    });

    // tpoTag가 null인 경로 — 새 옷 등록 추천(generateRecommendationForNewItem)이
    // findCandidateMatches를 쓰기 때문에 TPO 개념이 없어 항상 null로 넘어온다.
    test('tpoTag=null(새 옷 등록 경로)이고 점수가 낮으면 태그 대괄호 없이 문구를 낸다', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: false,
        mismatchedCategories: const [],
        bestScore: 65,
        dateLabel: '블랙 상의',
        tpoTag: null,
      );
      expect(note, isNotNull);
      expect(note, contains('블랙 상의'));
      expect(note, contains('65점'));
      expect(note, isNot(contains('[')));
      expect(note, isNot(contains('null')));
    });

    test('tpoTag=null이어도 점수가 기준 이상이면 null(배지 안 띄움)', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: false,
        mismatchedCategories: const [],
        bestScore: 85,
        dateLabel: '블랙 상의',
        tpoTag: null,
      );
      expect(note, isNull);
    });

    test('tpoTag=null이어도 matchIsFallback=true면 대괄호 없이 카테고리 문구를 낸다', () {
      final note = AgentPlanner.buildFallbackNote(
        matchIsFallback: true,
        mismatchedCategories: const ['하의'],
        bestScore: 62,
        dateLabel: '블랙 상의',
        tpoTag: null,
      );
      expect(note, isNotNull);
      expect(note, contains('하의'));
      expect(note, contains('62점'));
      expect(note, isNot(contains('[')));
    });
  });
}
