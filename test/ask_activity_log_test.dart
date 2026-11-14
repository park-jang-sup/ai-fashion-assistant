// AI에게 부탁하기 활동 내역(docs/task_agent_ask_v1.md §2-5).
import 'package:ai_fashion_assistant/models/agent_log_entry.dart';
import 'package:ai_fashion_assistant/services/ask_activity_log.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:flutter_test/flutter_test.dart';

AskStep _s(String action, String? obs, [Map<String, dynamic> args = const {}]) =>
    AskStep(thought: 't', action: action, args: args, observation: obs, status: AskStepStatus.done);

void main() {
  test('첫 줄은 요청 문장, 도구마다 한 줄(한 번씩), 끝은 답의 첫 문장 — 모두 같은 relatedDocId', () {
    final out = <AgentLogEntry>[];
    final log = AskActivityLog(write: out.add, relatedId: 'ask_1');
    log.started('금요일 저녁 모임에 입을 옷 준비해줘');
    final steps = [
      _s('get_weather', '2026-11-20(금): 최고 13°C 최저 5°C 강수 30% · 선선'),
      _s('-', '출력 오류: JSON 하나로만 답해 주세요'),
      _s('add_plan', null),
    ];
    log.steps(steps);
    log.steps(steps); // 같은 단계는 다시 남기지 않는다
    steps[2].observation = '2026-11-20(금) [모임] 일정을 등록했어요\n날씨: …';
    log.ended(AskOutcome(AskEnd.finished, '금요일 모임을 등록했어요. 블레이저를 챙기세요.', [...steps, _s('finish', null)], 4));
    expect([for (final e in out) e.message], [
      'AI에게 부탁: 금요일 저녁 모임에 입을 옷 준비해줘',
      '예보 확인 — 2026-11-20(금): 최고 13°C 최저 5°C 강수 30% · 선선',
      '일정 등록 — 2026-11-20(금) [모임] 일정을 등록했어요',
      'AI 답: 금요일 모임을 등록했어요.',
    ]);
    expect([for (final e in out) e.eventType], [
      AgentLogEntry.typeAskRequested,
      AgentLogEntry.typeAskStep,
      AgentLogEntry.typeAskStep,
      AgentLogEntry.typeAskAnswered,
    ]);
    expect(out.every((e) => e.relatedDocId == 'ask_1'), isTrue);
  });

  test('질문은 사용자의 답 대신 질문을 남기고, 멈춘 요청은 멈춤으로 남긴다', () {
    final out = <AgentLogEntry>[];
    final log = AskActivityLog(write: out.add, relatedId: 'ask_2');
    log.ended(AskOutcome(
        AskEnd.cancelled, '요청을 멈췄어요', [_s('ask_user', '사용자의 답: 금요일', {'question': '언제인가요?'})], 1));
    expect([for (final e in out) e.message], ['질문 — 언제인가요?', 'AI에게 부탁 멈춤: 요청을 멈췄어요']);
  });

  test('첫 문장 자르기', () {
    expect(askFirstSentence('내일은 비가 와요. 우산을 챙기세요.'), '내일은 비가 와요.');
    expect(askFirstSentence('정말요? 네'), '정말요?');
    expect(askFirstSentence('마침표 없는 답'), '마침표 없는 답');
    expect(askFirstSentence('첫 줄\n둘째 줄'), '첫 줄');
    expect(askFirstSentence('가' * 300).length, 100);
  });
}
