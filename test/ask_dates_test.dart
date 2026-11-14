// 날짜표(docs/task_agent_ask_v2.md §2-A) — "오늘"은 입력으로만 넣는다.
import 'package:ai_fashion_assistant/services/ask_dates.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _table(DateTime today) => {
      for (final line in buildAskDateTable(today).split('\n'))
        line.substring(0, 10): line.substring(line.indexOf(': ') + 2),
    };

String? _find(DateTime today, String word) {
  for (final e in _table(today).entries) {
    if (e.value.split(' · ').contains(word)) return e.key;
  }
  return null;
}

String _key(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  test('예시 출력 — 오늘이 토요일', () {
    final lines = buildAskDateTable(DateTime(2026, 11, 14, 21, 30)).split('\n');
    expect(lines.length, 14);
    expect(lines.take(5), [
      '2026-11-14(토): 오늘 · 이번 주 토요일 · 주말',
      '2026-11-15(일): 내일 · 이번 주 일요일 · 주말',
      '2026-11-16(월): 모레 · 다음 주 월요일',
      '2026-11-17(화): 글피 · 다음 주 화요일',
      '2026-11-18(수): 다음 주 수요일',
    ]);
    expect(lines.last, '2026-11-27(금): 다다음 주 금요일');
  });

  test('오늘이 월~일 각각 — 이번 주·다음 주·다다음 주가 달력 주(월~일)와 맞는다', () {
    for (var wd = 0; wd < 7; wd++) {
      final today = DateTime(2026, 11, 16 + wd); // 11/16(월) ~ 11/22(일)
      final monday = DateTime(2026, 11, 16);
      final t = _table(today);
      expect(t.length, 14, reason: '$today');
      expect(t[_key(today)]!.startsWith('오늘'), isTrue);
      expect(t[_key(DateTime(2026, 11, 17 + wd))]!.startsWith('내일'), isTrue);
      const names = ['월', '화', '수', '목', '금', '토', '일'];
      for (var i = 0; i < 7; i++) {
        final next = DateTime(monday.year, monday.month, monday.day + 7 + i);
        expect(_find(today, '다음 주 ${names[i]}요일'), _key(next), reason: '오늘 $today, 다음 주 ${names[i]}요일');
        final thisWeek = DateTime(monday.year, monday.month, monday.day + i);
        expect(_find(today, '이번 주 ${names[i]}요일'), i >= wd ? _key(thisWeek) : null);
      }
      // 주말 표시는 토·일에만.
      for (final e in t.entries) {
        final d = DateTime.parse(e.key);
        expect(e.value.contains('주말'), d.weekday >= DateTime.saturday, reason: e.key);
      }
    }
  });

  test('T7 날짜 시나리오(D1·D2·D3)', () {
    expect(_find(DateTime(2026, 11, 14), '다음 주 월요일'), '2026-11-16');
    expect(_find(DateTime(2026, 11, 15), '다음 주 금요일'), '2026-11-20');
    expect(_find(DateTime(2026, 11, 18), '모레'), '2026-11-20');
  });

  test('월말을 넘는다', () {
    final today = DateTime(2026, 11, 28); // 토
    final t = _table(today);
    expect(t.keys.first, '2026-11-28');
    expect(t.keys.last, '2026-12-11');
    expect(t.containsKey('2026-12-01'), isTrue);
    expect(_find(today, '다음 주 월요일'), '2026-11-30');
    expect(_find(today, '다음 주 화요일'), '2026-12-01');
    expect(_find(today, '모레'), '2026-11-30');
  });

  test('연말을 넘는다', () {
    final today = DateTime(2026, 12, 29); // 화
    final t = _table(today);
    expect(t.keys.last, '2027-01-11');
    expect(t['2027-01-01'], '글피 · 이번 주 금요일');
    expect(_find(today, '다음 주 월요일'), '2027-01-04');
    expect(_find(today, '다다음 주 월요일'), '2027-01-11');
    expect(t['2027-01-03'], '이번 주 일요일 · 주말');
  });

  test('확인 카드 문구', () {
    final sat = DateTime(2026, 11, 14);
    expect(askDateCardLabel(DateTime(2026, 11, 16), sat), '11/16(월) · 다음 주 월요일');
    expect(askDateCardLabel(sat, sat), '11/14(토) · 오늘');
    expect(askDateCardLabel(DateTime(2026, 11, 15), sat), '11/15(일) · 내일');
    expect(askDateCardLabel(DateTime(2026, 12, 20), sat), '12/20(일)'); // 다다음 주 밖
  });
}
