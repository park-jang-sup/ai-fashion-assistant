// 옷장 추천 후보와 [추천후보] 처리 — docs/task_agent_grounding_v1.md 부분 B.
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/user_profile.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:ai_fashion_assistant/services/style_recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

WardrobeItem _item(String id, String category,
        {String? sub, String color = '블랙', String formality = '캐주얼', String style = '캐주얼'}) =>
    WardrobeItem(
      id: id,
      imageUrl: '',
      category: category,
      subCategory: sub,
      createdAt: DateTime(2026),
      attributes: ClothingAttributes(
          color: color, style: style, pattern: '무지', formality: formality, fit: '레귤러', tags: const ['코튼']),
    );

void main() {
  group('parseRecommendedCandidates', () {
    test('번호 1~2개를 0-based로', () {
      expect(parseRecommendedCandidates('[점수] 80\n[추천후보] 2, 5\n본문', 8), [1, 4]);
      expect(parseRecommendedCandidates('[추천후보] 3', 8), [2]);
    });
    test('없음·줄 없음·빈 값은 빈 리스트(분석은 실패로 처리하지 않음)', () {
      expect(parseRecommendedCandidates('[추천후보] 없음', 8), isEmpty);
      expect(parseRecommendedCandidates('[점수] 80\n본문', 8), isEmpty);
      expect(parseRecommendedCandidates('[추천후보]', 8), isEmpty);
    });
    test('범위 밖·0·중복은 버리고 앞에서부터 최대 2개', () {
      expect(parseRecommendedCandidates('[추천후보] 0, 9, 3', 8), [2]);
      expect(parseRecommendedCandidates('[추천후보] 2, 2, 4, 6', 8), [1, 3]);
      expect(parseRecommendedCandidates('[추천후보] 12', 8), isEmpty);
    });
    test('후보가 0개면 무엇이 와도 빈 리스트', () {
      expect(parseRecommendedCandidates('[추천후보] 1', 0), isEmpty);
    });
  });

  group('visibleAnalysisText — [추천후보] 줄은 화면에 보이지 않는다', () {
    test('완성된 줄을 지운다', () {
      expect(visibleAnalysisText('[점수] 80\n[분위기점수] 85\n[분위기] 시크\n[추천후보] 2\n1. 스타일링 팁: x'),
          '[점수] 80\n[분위기점수] 85\n[분위기] 시크\n1. 스타일링 팁: x');
    });
    test('스트리밍 도중 반쯤 온 마지막 줄도 숨긴다', () {
      for (final partial in ['[', '[추', '[추천후', '[추천후보]', '[추천후보] 2']) {
        expect(visibleAnalysisText('[분위기] 시크\n$partial'), '[분위기] 시크', reason: partial);
      }
    });
    test('다른 머리 줄이 반쯤 온 상태는 숨겼다가(접두가 같은 "[") 이어지면 보인다', () {
      expect(visibleAnalysisText('[분위기] 시크\n[점'), '[분위기] 시크\n[점');
    });
    test('[추천후보] 줄이 없으면 그대로', () {
      const t = '[점수] 80\n1. 스타일링 팁: x';
      expect(visibleAnalysisText(t), t);
    });
  });

  group('orderWithAiPicks', () {
    final c = [for (final id in ['a', 'b', 'c', 'd']) StyleCandidate(item: _item(id, '상의'), caption: id)];
    test('고른 후보를 고른 순서대로 맨 앞에, 나머지는 원래 순서', () {
      final o = orderWithAiPicks(c, [2, 0]);
      expect(o.map((e) => e.candidate.caption), ['c', 'a', 'b', 'd']);
      expect(o.map((e) => e.aiPick), [true, true, false, false]);
    });
    test('고른 것이 없거나 범위 밖이면 지금 순서 그대로', () {
      expect(orderWithAiPicks(c, const []).map((e) => e.candidate.caption), ['a', 'b', 'c', 'd']);
      expect(orderWithAiPicks(c, [9]).map((e) => e.aiPick), [false, false, false, false]);
    });
  });

  group('추가 가능 / 교체 후보', () {
    final selected = [_item('t', '상의'), _item('h', '액세서리', sub: '모자')];
    test('그 종류가 지금 조합에 없으면 추가 가능, 있으면 교체 후보', () {
      expect(candidatePromptLine(0, _item('o', '아우터'), selected), startsWith('1. 아우터(추가 가능): '));
      expect(candidatePromptLine(1, _item('t2', '상의'), selected), startsWith('2. 상의(교체 후보): '));
    });
    test('액세서리는 세부 종류 기준 — 모자가 있어도 가방은 추가 가능', () {
      expect(candidatePromptLine(0, _item('b', '액세서리', sub: '가방'), selected), startsWith('1. 가방(추가 가능): '));
      expect(candidatePromptLine(0, _item('h2', '액세서리', sub: '모자'), selected), startsWith('1. 모자(교체 후보): '));
    });
  });

  group('matchStyleCandidates — 옮기기 전 규칙 그대로', () {
    test('선택한 옷은 제외, 카테고리당 최대 2개, 최대 maxItems', () {
      final selected = [_item('t', '상의'), _item('p', '하의')];
      final wardrobe = [
        ...selected,
        for (var i = 0; i < 4; i++) _item('o$i', '아우터'),
        for (var i = 0; i < 4; i++) _item('s$i', '신발'),
      ];
      final r = matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: 8);
      expect(r.any((c) => c.item.id == 't' || c.item.id == 'p'), isFalse);
      expect(r.where((c) => c.item.category == '아우터').length, 2);
      expect(r.where((c) => c.item.category == '신발').length, 2);
      expect(matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: 3).length, 3);
    });
    test('속성 있는 선택 옷이 없으면 빈 리스트', () {
      expect(matchStyleCandidates(selected: const [], wardrobe: [_item('o', '아우터')]), isEmpty);
    });
  });

  group('프롬프트 — 후보가 있을 때만 바뀐다', () {
    final items = [(category: '상의', attributes: _item('t', '상의').attributes!)];
    const lines = '1. 아우터(추가 가능): 색상 브라운';
    for (final kind in ['photo', 'profile']) {
      test('$kind: 후보 구간·[추천후보] 머리 줄·새 팁 지시·네 줄 예시', () {
        final p = GeminiService.analysisPromptsForGoldenTest(items,
            kind: kind, profile: const UserProfile(heightCm: 175), candidateLines: lines);
        expect(p, contains('[내 옷장 후보] (착용자가 실제로 가진 옷입니다)\n$lines\n'));
        expect(p, contains('[추천후보] (위 후보 중 이 코디에 가장 도움이 되는 것의 번호 1~2개'));
        expect(p, contains('[내 옷장 후보]에 없는 옷은 추천하지 마세요.'));
        expect(p, contains('응답의 첫 네 줄은'));
        expect(p, contains('[분위기] 캐주얼\n[추천후보] 2\n'));
        expect(p, isNot(contains('전체 코디를 더욱 완성도 있게 만들 액세서리나 추가 아이템')));
      });
    }
    test('자기평가 프롬프트는 후보 인자를 받아도 그대로(인자를 쓰지 않는다)', () {
      final a = GeminiService.analysisPromptsForGoldenTest(items, kind: 'selfEval');
      final b = GeminiService.analysisPromptsForGoldenTest(items, kind: 'selfEval', candidateLines: lines);
      expect(b, a);
    });
  });
}

