// AI에게 부탁하기 — 날짜표(docs/task_agent_ask_v2.md §2-A). 날짜를 모델이 계산하지 않게, 오늘부터
// 14일의 날짜·요일·그 날짜를 가리키는 말을 표로 만들어 프롬프트에 넣는다. 부탁할 때마다 기기의 현재
// 날짜로 새로 만든다(날짜를 코드에 고정하지 않는다). 순수 함수.
import 'ask_tools.dart';

const askDateTableDays = 14;
const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];
const _nearWords = ['오늘', '내일', '모레', '글피'];
const _weekWords = ['이번 주', '다음 주', '다다음 주'];

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

int _daysBetween(DateTime a, DateTime b) => _day(b).difference(_day(a)).inHours ~/ 24;

// 그 날짜를 가리키는 말 — 오늘·내일·모레·글피, "이번 주/다음 주/다다음 주 ○요일"(한 주는 월~일), 주말.
List<String> askDateWords(DateTime date, DateTime today) {
  final offset = _daysBetween(today, date);
  final words = <String>[];
  if (offset >= 0 && offset < _nearWords.length) words.add(_nearWords[offset]);
  final monday = _day(today).subtract(Duration(days: today.weekday - 1));
  final week = _daysBetween(monday, date) ~/ 7;
  if (offset >= 0 && week < _weekWords.length) words.add('${_weekWords[week]} ${_weekdays[date.weekday - 1]}요일');
  if (date.weekday >= DateTime.saturday) words.add('주말');
  return words;
}

// 프롬프트용 날짜표 — 줄마다 "2026-11-16(월): 모레 · 다음 주 월요일".
String buildAskDateTable(DateTime today, {int days = askDateTableDays}) {
  final start = _day(today);
  return [
    for (var i = 0; i < days; i++)
      () {
        // 서머타임이 있는 지역에서도 날짜가 밀리지 않게 달력으로 더한다.
        final d = DateTime(start.year, start.month, start.day + i);
        return '${askDateLabel(d)}: ${askDateWords(d, today).join(' · ')}';
      }(),
  ].join('\n');
}

// 확인 카드용 — "11/16(월) · 다음 주 월요일". 오늘·내일은 그 말을, 나머지는 주를 가리키는 말을 쓴다.
String askDateCardLabel(DateTime date, DateTime today) {
  final base = '${date.month}/${date.day}(${_weekdays[date.weekday - 1]})';
  final offset = _daysBetween(today, date);
  final words = askDateWords(date, today);
  final pick = offset == 0 || offset == 1
      ? words.first
      : words.where((w) => w.endsWith('요일')).firstOrNull;
  return pick == null ? base : '$base · $pick';
}
