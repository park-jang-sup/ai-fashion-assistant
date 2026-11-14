// 모델용 안내 "없는 옷을 권할 때는 '구매 제안:' 줄에만 쓴다."(T7 run2 준비) — 부족을 알리는 관찰 문장 뒤에
// 한 번 붙고, 화면용 한 줄에는 붙지 않는다.
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

List<String> _lines(AskToolResult r) => r.observation.split('\n');

void main() {
  test('preview_outfit — 요청한 수를 채우지 못하면 머리 줄 뒤에', () async {
    final r = await askTools(FakeAskData(snap: askSnapshot())).previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'count': 5});
    final lines = _lines(r);
    expect(lines.first, contains('요청 5개 중 2개'));
    expect(lines[1], askBuyNote);
    expect(lines.where((l) => l == askBuyNote).length, 1);
    expect(r.display, isNot(contains('구매 제안')));
  });

  test('preview_outfit — 다 채우고 날씨·격식도 맞으면 붙이지 않는다', () async {
    final r = await askTools(FakeAskData(snap: askSnapshot())).previewOutfit({'date': '2026-11-16', 'tpo': '일상'});
    expect(r.observation, isNot(contains(askBuyNote)));
  });

  test('search_wardrobe — 일치 없음, 종류 요약의 한겨울용 없음', () async {
    final t = askTools(FakeAskData());
    expect(_lines(await t.searchWardrobe({'keyword': '패딩'})), [startsWith('일치하는 옷 없음'), askBuyNote]);
    final shoes = _lines(await t.searchWardrobe({'category': '신발'}));
    final at = shoes.indexWhere((l) => l.endsWith(' 옷: 없음'));
    expect(shoes[at + 1], askBuyNote);
    final outer = await t.searchWardrobe({'category': '아우터'}); // 한겨울용이 있다
    expect(outer.observation, isNot(contains(askBuyNote)));
    expect(outer.display, '아우터 2벌을 찾았어요');
  });

  test('get_wardrobe_profile — 빈 부분 줄 뒤에', () async {
    final r = await askTools(FakeAskData(snap: askSnapshot())).getWardrobeProfile({});
    final lines = _lines(r);
    final at = lines.indexWhere((l) => l.startsWith('빈 부분 — '));
    expect(lines[at + 1], askBuyNote);
    expect(r.display, '옷장 8벌을 요약했어요');
  });
}
