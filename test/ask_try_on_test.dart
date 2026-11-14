// 가상 피팅 도구 try_on(docs/task_agent_ask_v2.md §2-E) — 가짜 피팅 경로.
import 'dart:typed_data';

import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

class _Port {
  bool photo = true;
  bool busy = false;
  String? error;
  Duration delay = Duration.zero;
  final runs = <List<String>>[];
  AskFittingPort get port => AskFittingPort(
        hasUserPhoto: () => photo,
        busy: () => busy,
        run: (items) async {
          runs.add([for (final i in items) i.id]);
          await Future.delayed(delay);
          if (error != null) return AskFittingOutcome(error: error);
          return AskFittingOutcome(shot: AskFittingShot(bytes: Uint8List(3), cacheKey: 'k1'));
        },
      );
}

Future<(AskOutcome, AskTools)> _run(_Port p, List<Map<String, dynamic>> Function(int Function(String id) num) script,
    {Duration total = askTotalTimeout}) async {
  final tools = askTools(FakeAskData(snap: askSnapshot()));
  await tools.searchWardrobe({}); // 번호를 매겨 둔다
  int num(String id) => tools.book.numberOf(askWardrobe.firstWhere((i) => i.id == id));
  final replies = script(num);
  var i = 0;
  final engine = AskEngine(
    tools: tools,
    callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
    buildPrompt: buildAskPrompt,
    confirmPlan: (_, __) async => false,
    askUser: (_) async => null,
    fitting: p.port,
    totalTimeout: total,
  );
  return (await engine.run('금요일 모임 옷 골라서 입혀 봐줘'), tools);
}

void main() {
  test('조합을 입혀 보고 사진을 단계에 남긴다 — 턴마다 한 번(엔진이 막는다)', () async {
    final p = _Port();
    final (o, _) = await _run(p, (no) => [
          _a('try_on', {'outfit': [no('t1'), no('p1'), no('s1')]}),
          _a('try_on', {'outfit': [no('t2'), no('p2')]}),
          _a('finish', {'answer': '입혀 봤어요\n- 코디보드에도 올려 두었어요'}),
        ]);
    expect(o.end, AskEnd.finished);
    expect(p.runs, [
      ['t1', 'p1', 's1'],
    ]);
    expect(o.steps[0].observation, contains('코디보드에도 올려 두었어요'));
    expect(o.steps[0].display, '입혀 봤어요 — 코디보드에도 올렸어요');
    expect(o.steps[0].fitting?.cacheKey, 'k1');
    expect(o.steps[1].observation, contains('한 턴에 한 번'));
    expect(o.steps[1].display, '이미 확인한 내용으로 이어갈게요');
  });

  test('전신 사진이 없으면, 다른 피팅이 진행 중이면 실행하지 않는다', () async {
    final noPhoto = _Port()..photo = false;
    final (o1, _) = await _run(noPhoto, (no) => [
          _a('try_on', {'outfit': [no('t1')]}),
          _a('finish', {'answer': '끝'}),
        ]);
    expect(noPhoto.runs, isEmpty);
    expect(o1.steps.first.observation, contains('전신 사진이 선택돼 있지 않아'));
    final busy = _Port()..busy = true;
    final (o2, _) = await _run(busy, (no) => [
          _a('try_on', {'outfit': [no('t1')]}),
          _a('finish', {'answer': '끝'}),
        ]);
    expect(busy.runs, isEmpty);
    expect(o2.steps.first.observation, contains('다른 가상 피팅이 진행 중'));
  });

  test('피팅 상한과 실패는 재시도하지 않고 사용자 말로', () async {
    final limited = _Port()..error = '호출량이 많아 잠시 후 다시 시도해주세요.';
    final (o, _) = await _run(limited, (no) => [
          _a('try_on', {'outfit': [no('t1')]}),
          _a('finish', {'answer': '끝'}),
        ]);
    expect(limited.runs.length, 1);
    expect(o.steps.first.observation, contains('시간당 6번까지'));
    expect(o.steps.first.display, '입혀 보기 한도에 걸렸어요');
  });

  test('피팅을 기다리는 시간은 요청 전체 시한에 세지 않는다', () async {
    final slow = _Port()..delay = const Duration(milliseconds: 300);
    final (o, _) = await _run(slow, (no) => [
          _a('try_on', {'outfit': [no('t1')]}),
          _a('finish', {'answer': '끝'}),
        ], total: const Duration(milliseconds: 150));
    expect(o.end, AskEnd.finished);
  });

  test('경로가 없으면(프로브·테스트 환경) 쓸 수 없다고 돌려준다, 없는 번호는 형식 오류', () async {
    final tools = askTools(FakeAskData(snap: askSnapshot()));
    await tools.searchWardrobe({});
    var i = 0;
    final replies = [
      _a('try_on', {'outfit': [999]}),
      _a('try_on', {'outfit': [tools.book.numberOf(askWardrobe.first)]}),
      _a('finish', {'answer': '끝'}),
    ];
    final o = await AskEngine(
      tools: tools,
      callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
      buildPrompt: buildAskPrompt,
      confirmPlan: (_, __) async => false,
      askUser: (_) async => null,
    ).run('입혀 봐');
    expect(o.steps[0].hidden, isTrue);
    expect(o.steps[0].observation, contains('보여 준 적 없는 옷 번호'));
    expect(o.steps[1].observation, '이 기기에서는 입혀 보기를 쓸 수 없어요');
  });

  test('프롬프트 규칙 — 입혀 달라고 했을 때만', () {
    final p = buildAskPrompt(request: 'x', steps: const [], today: DateTime(2026, 11, 16));
    expect(p, contains('try_on은 사용자가 입은 모습을 보여 달라고'));
    expect(p, contains('- try_on {"outfit":[옷 번호]}'));
  });
}
