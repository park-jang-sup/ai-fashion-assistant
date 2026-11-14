// AI에게 부탁하기 단계 프롬프트 골든 — docs/task_agent_ask_v1.md §2-4.
// 분석 프롬프트 골든 6개와 따로 둔다(그쪽은 바뀌면 안 된다). 다시 만들려면
//   UPDATE_ASK_GOLDENS=1 flutter test test/ask_prompt_golden_test.dart
import 'dart:io';

import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void _golden(String name, String actual) {
  final file = File('test/goldens/$name.txt');
  if (Platform.environment['UPDATE_ASK_GOLDENS'] == '1') {
    file.writeAsStringSync(actual);
    return;
  }
  expect(actual, file.readAsStringSync().replaceAll('\r\n', '\n'), reason: 'test/goldens/$name.txt와 다르다');
}

final _today = DateTime(2026, 11, 16);

void main() {
  test('첫 단계(기록 없음)', () {
    _golden('ask_prompt_first', buildAskPrompt(request: '금요일 저녁 모임에 입을 옷 준비해줘', steps: const [], today: _today));
  });

  test('세 단계 뒤(실패한 단계 포함)', () {
    final steps = [
      AskStep(
          thought: '금요일 예보부터 볼게요',
          action: 'get_weather',
          args: {'from': '2026-11-20', 'to': '2026-11-20'},
          observation: '2026-11-20(금): 최고 13°C 최저 5°C 강수 30% · 선선',
          status: AskStepStatus.done),
      AskStep(
          thought: '(출력을 읽지 못함)',
          action: '-',
          args: const {},
          observation: '출력 오류: JSON 하나로만 답해 주세요(잘림)',
          status: AskStepStatus.failed),
      AskStep(
          thought: '모임 코디를 미리 볼게요',
          action: 'preview_outfit',
          args: {'date': '2026-11-20', 'tpo': '모임'},
          observation: '2026-11-20(금) [모임] 미리 보기(저장 안 함): 상의 베이지 니트·울·헨리넥(세미포멀)',
          status: AskStepStatus.done),
    ];
    _golden('ask_prompt_steps', buildAskPrompt(request: '금요일 저녁 모임에 입을 옷 준비해줘', steps: steps, today: _today));
  });

  test('오늘 날짜·요일과 상황 태그 9개가 들어간다', () {
    final p = buildAskPrompt(request: 'x', steps: const [], today: _today);
    expect(p, contains('[오늘] 2026-11-16(월)'));
    for (final t in ['출근(세미포멀)', '면접(포멀)', '일상(캐주얼)']) {
      expect(p, contains(t));
    }
    for (final a in askActions) {
      expect(p, contains('- $a {'));
    }
  });

  test('남은 호출 수는 단계 기록 끝, [다음] 앞에 붙는다', () {
    final steps = [
      AskStep(thought: '예보', action: 'get_weather', args: const {}, observation: 'o', status: AskStepStatus.done),
    ];
    final p = buildAskPrompt(request: 'x', steps: steps, today: _today, remainingCalls: 2);
    expect(p, contains('   결과: o\n남은 호출 2회\n\n[다음]'));
    expect(buildAskPrompt(request: 'x', steps: steps, today: _today), isNot(contains('남은 호출')));
  });

  test('6단계째 요청도 30,000자 안 — 관찰이 꽉 차면 오래된 것부터 줄인다', () {
    final long = '가' * askObservationMaxChars;
    final steps = [
      for (var i = 0; i < 5; i++)
        AskStep(thought: '단계 $i', action: 'search_wardrobe', args: const {}, observation: long, status: AskStepStatus.done),
    ];
    final p = buildAskPrompt(request: '겨울 아우터 뭐 있는지 보고 가장 추운 날 입을 것 골라줘', steps: steps, today: _today);
    expect(p.length, lessThanOrEqualTo(30000));
    expect(p, contains(long)); // 마지막 관찰은 그대로
    // 다섯 개 다 담아도 상한 안이면 줄이지 않는다.
    expect(p.contains('(줄임)'), p.length > askPromptMaxChars);
    final huge = [
      for (var i = 0; i < 5; i++)
        AskStep(thought: '단계 $i', action: 'search_wardrobe', args: const {}, observation: '나' * 9000, status: AskStepStatus.done),
    ];
    final p2 = buildAskPrompt(request: 'x', steps: huge, today: _today);
    expect(p2.length, lessThanOrEqualTo(askPromptMaxChars));
    expect(p2, contains('(줄임)'));
  });
}
