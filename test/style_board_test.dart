// AI 추천 카드를 코디보드에 반영 — docs/task_demo_flow_v1.md 부분 D.
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/screens/usage_guide_screen.dart';
import 'package:ai_fashion_assistant/services/style_recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

WardrobeItem _w(String id, String category, {String? sub}) =>
    WardrobeItem(id: id, imageUrl: '', category: category, subCategory: sub, createdAt: DateTime(2026));

void main() {
  test('칸 규칙 — 옷장에서 보낼 때와 같다: 액세서리는 세부 종류, 그 외는 카테고리', () {
    expect(boardSlotKeyFor(_w('a', '아우터')), '아우터');
    expect(boardSlotKeyFor(_w('b', '신발')), '신발');
    expect(boardSlotKeyFor(_w('c', '액세서리', sub: '팔찌')), '팔찌');
    expect(boardSlotKeyFor(_w('d', '액세서리')), isNull);
  });

  test('조합 서명 — 순서·빈 칸과 무관, 옷이 바뀌면 달라진다', () {
    final top = _w('t', '상의');
    final bottom = _w('b', '하의');
    expect(comboSignature([top, null, bottom]), comboSignature([bottom, top]));
    expect(comboSignature([top, bottom]), isNot(comboSignature([top, _w('b2', '하의')])));
  });

  test('D를 구현했으니 가이드 2쪽에 반영 문장이 있다', () {
    expect(UsageGuide.pages[1].body, contains('추천 옷을 누르면 코디보드의 그 칸에 들어가요'));
  });
}
