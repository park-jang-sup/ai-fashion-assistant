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

  // docs/task_demo_flow_v1.md §10-2·4 — 예전 orderWithAiPicks(고른 것 → 나머지 원래 순서)를 대체.
  group('orderForCards — 고른 것 → 안 나온 종류의 1위(상의·하의·아우터·신발·액세서리) → 나머지', () {
    // 점수순으로 들어온 후보라고 가정한 순서.
    final c = [
      StyleCandidate(item: _item('o1', '아우터'), caption: 'o1'),
      StyleCandidate(item: _item('t1', '상의'), caption: 't1'),
      StyleCandidate(item: _item('o2', '아우터'), caption: 'o2'),
      StyleCandidate(item: _item('a1', '액세서리', sub: '팔찌'), caption: 'a1'),
      StyleCandidate(item: _item('s1', '신발'), caption: 's1'),
      StyleCandidate(item: _item('t2', '상의'), caption: 't2'),
    ];
    List<String> ids(List<({StyleCandidate candidate, bool aiPick})> o) => [for (final e in o) e.candidate.caption];
    test('고른 순서 그대로 맨 앞, 그 종류는 다시 1위로 넣지 않는다', () {
      final o = orderForCards(c, [3, 2]); // 팔찌, 아우터 o2
      expect(ids(o), ['a1', 'o2', 't1', 's1', 'o1', 't2']);
      expect(o.map((e) => e.aiPick), [true, true, false, false, false, false]);
    });
    test('고른 것이 없으면 종류별 1위부터, 전부 옅은 표시(aiPick false)', () {
      final o = orderForCards(c, const []);
      expect(ids(o), ['t1', 'o1', 's1', 'a1', 'o2', 't2']);
      expect(o.every((e) => !e.aiPick), isTrue);
    });
    test('범위 밖·중복 번호는 버린다(줄을 읽지 못한 것과 같게)', () {
      expect(ids(orderForCards(c, [9, -1])), ids(orderForCards(c, const [])));
      expect(ids(orderForCards(c, [1, 1])), ['t1', 'o1', 's1', 'a1', 'o2', 't2']);
    });
    test('모든 후보가 한 번씩만', () {
      final o = orderForCards(c, [5]);
      expect(ids(o).toSet().length, c.length);
      expect(ids(o).first, 't2');
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
    // §10-1 — 후보가 있는 종류마다 1위는 반드시 들어간다(남는 자리는 점수순, 총 개수 유지).
    test('후보가 있는 종류마다 한 벌 이상', () {
      final selected = [_item('t', '상의'), _item('p', '하의')];
      final wardrobe = [
        ...selected,
        for (var i = 0; i < 3; i++) _item('o$i', '아우터'),
        for (var i = 0; i < 3; i++) _item('t$i', '상의', color: '네이비'),
        for (var i = 0; i < 3; i++) _item('p$i', '하의', color: '베이지'),
        // 궁합이 낮게 나오는 신발·액세서리(유채색·격식 차이) — 예전 규칙에선 잘려 나갈 수 있었다.
        _item('s0', '신발', color: '레드', formality: '포멀', style: '포멀'),
        _item('a0', '액세서리', sub: '모자', color: '퍼플', formality: '포멀', style: '포멀'),
      ];
      for (final max in [5, 8]) {
        final r = matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: max);
        expect(r.length, max);
        for (final cat in ['상의', '하의', '아우터', '신발', '액세서리']) {
          expect(r.any((x) => x.item.category == cat), isTrue, reason: '$cat · max $max');
        }
      }
    });
    test('자리가 종류 수보다 적으면 종류별 1위만, 서로 다른 종류로', () {
      final selected = [_item('t', '상의')];
      final wardrobe = [
        ...selected,
        for (var i = 0; i < 2; i++) _item('o$i', '아우터'),
        for (var i = 0; i < 2; i++) _item('p$i', '하의'),
        for (var i = 0; i < 2; i++) _item('s$i', '신발'),
      ];
      final r = matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: 2);
      expect(r.length, 2);
      expect(r.map((x) => x.item.category).toSet().length, 2);
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

