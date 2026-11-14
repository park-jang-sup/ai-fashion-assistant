// AI에게 부탁하기 — 루프 엔진(docs/task_agent_ask_v1.md §2-1), 가짜 모델.
import 'dart:async';

import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/gemini_api_exception.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

// 정해진 답을 차례로 내는 가짜 모델. 값이 Exception이면 던진다.
class _Script {
  final List<Object> replies;
  final prompts = <String>[];
  var i = 0;
  _Script(this.replies);
  Future<AskModelReply> call(String prompt) async {
    prompts.add(prompt);
    final r = replies[i++];
    if (r is Exception) throw r;
    if (r is Future<Map<String, dynamic>>) return AskModelReply(await r, 'text-primary');
    return AskModelReply(r as Map<String, dynamic>, 'text-primary');
  }
}

String _prompt(
        {required String request, required List<AskStep> steps, required DateTime today, int? remainingCalls, String? profile}) =>
    'REQ:$request\n${steps.map((s) => '${s.action}=>${s.observation}').join('\n')}'
    '${remainingCalls == null ? '' : '\nLEFT:$remainingCalls'}';

({AskEngine engine, FakeAskData data, _Script model, List<(DateTime, String)> confirms}) _engine(
  List<Object> replies, {
  bool confirm = true,
  String? userAnswer = '금요일 모임',
  Duration stepTimeout = askStepTimeout,
}) {
  final data = FakeAskData(snap: askSnapshot());
  final model = _Script(replies);
  final confirms = <(DateTime, String)>[];
  final engine = AskEngine(
    tools: askTools(data),
    callModel: model.call,
    buildPrompt: _prompt,
    confirmPlan: (d, t) async {
      confirms.add((d, t));
      return confirm;
    },
    askUser: (_) async => userAnswer,
    stepTimeout: stepTimeout,
  );
  return (engine: engine, data: data, model: model, confirms: confirms);
}

void main() {
  group('출력 규약 검증', () {
    test('맞는 출력', () {
      expect(validateAskReply(_a('get_weather', {'from': '2026-11-16', 'to': '2026-11-22'})), isNull);
      expect(validateAskReply(_a('finish', {'answer': '네'})), isNull);
      expect(validateAskReply(_a('search_wardrobe')), isNull);
    });
    test('모르는 도구·생각 없음·인자 형식', () {
      expect(validateAskReply(_a('delete_item')), contains('action은'));
      expect(validateAskReply({'action': 'finish', 'args': {'answer': 'x'}}), contains('thought'));
      expect(validateAskReply(_a('preview_outfit', {'date': '11/20', 'tpo': '모임'})), contains('date'));
      expect(validateAskReply(_a('add_plan', {'date': '2026-11-20', 'tpo': '파티'})), contains('tpo'));
      expect(validateAskReply(_a('search_wardrobe', {'category': '모자'})), contains('category'));
      expect(validateAskReply(_a('finish')), contains('answer'));
      expect(validateAskReply(_a('ask_user')), contains('question'));
    });
  });

  test('정상 흐름 — 예보 → 미리 보기 → 끝, 관찰이 다음 프롬프트에 붙는다', () async {
    final e = _engine([
      _a('get_weather', {'from': '2026-11-17', 'to': '2026-11-17'}),
      _a('preview_outfit', {'date': '2026-11-17', 'tpo': '일상'}),
      _a('finish', {'answer': '내일은 비 예보라 어두운 하의로 골랐어요'}),
    ]);
    final o = await e.engine.run('내일 비 오면 뭐 입지?');
    expect(o.end, AskEnd.finished);
    expect(o.answer, '내일은 비 예보라 어두운 하의로 골랐어요');
    expect(o.modelCalls, 3);
    expect(o.steps.map((s) => s.action), ['get_weather', 'preview_outfit', 'finish']);
    expect(e.model.prompts[1], contains('get_weather=>2026-11-17(화): 최고 9°C'));
    expect(e.data.writes, isEmpty);
  });

  test('잘못된 JSON은 한 번 더 기회, 두 번 연속이면 끝', () async {
    final once = _engine([const FormatException('잘림'), _a('finish', {'answer': '네'})]);
    expect((await once.engine.run('x')).end, AskEnd.finished);
    expect(once.model.prompts[1], contains('출력 오류: JSON 하나로만'));
    final twice = _engine([const FormatException('a'), const FormatException('b'), _a('finish', {'answer': '네'})]);
    final o = await twice.engine.run('x');
    expect(o.end, AskEnd.invalidOutput);
    expect(o.modelCalls, 2);
  });

  test('모르는 도구는 관찰로 돌려주고, 바로 맞게 내면 이어간다(연속 실패만 끝)', () async {
    final e = _engine([_a('delete_item'), _a('finish', {'answer': '할 수 없는 일이에요'})]);
    final o = await e.engine.run('옷 지워줘');
    expect(o.end, AskEnd.finished);
    expect(e.model.prompts[1], contains('출력 오류: action은'));
    final bad = _engine([_a('delete_item'), _a('rm_all'), _a('finish', {'answer': 'x'})]);
    expect((await bad.engine.run('x')).end, AskEnd.invalidOutput);
  });

  test('search_wardrobe는 한 턴에 3회까지, 같은 인자는 다시 실행하지 않는다 — 막힌 호출도 호출 수에는 든다', () async {
    final e = _engine([
      _a('search_wardrobe'),
      _a('search_wardrobe', {'category': '아우터'}),
      _a('search_wardrobe', {'category': '아우터'}), // 같은 인자
      _a('search_wardrobe', {'keyword': '패딩'}),
      _a('search_wardrobe', {'keyword': '코트'}), // 네 번째 실행
      _a('finish', {'answer': '퀼팅안감 아우터가 있어요'}),
    ]);
    final o = await e.engine.run('겨울 아우터');
    expect(o.end, AskEnd.finished);
    expect(o.modelCalls, 6);
    final firstLines = [for (final s in o.steps.take(5)) s.observation!.split(String.fromCharCode(10)).first];
    expect(firstLines, [
      '옷장 8벌 — 상의 2, 하의 2, 아우터 2, 신발 1, 액세서리 1',
      '일치 2벌:',
      askRepeatMessage,
      '일치하는 옷 없음(전체, "패딩")',
      askWardrobeSearchLimitMessage,
    ]);
    // 화면에는 모델용 문장 대신 사용자 말.
    expect([for (final s in o.steps.take(5)) s.display], [
      '옷장 8벌을 확인했어요',
      '아우터 2벌을 찾았어요',
      '이미 확인한 내용으로 이어갈게요',
      "'패딩' 옷은 없어요",
      '이미 확인한 내용으로 이어갈게요',
    ]);
    expect(e.model.prompts[3], contains(askRepeatMessage));
  });

  test('모델 호출 6회 상한 — finish가 없으면 여기까지 확인했어요', () async {
    final e = _engine([for (var i = 0; i < 10; i++) _a('search_wardrobe')]);
    final o = await e.engine.run('x');
    expect(o.end, AskEnd.maxSteps);
    expect(o.modelCalls, askMaxModelCalls);
    expect(o.answer, '여기까지 확인했어요 — $askRepeatMessage');
    // 네 번째 호출 뒤부터 남은 호출 수를 알린다(5번째 요청에 2회, 6번째에 1회).
    expect([for (final p in e.model.prompts) RegExp(r'LEFT:(\d)').firstMatch(p)?.group(1)],
        [null, null, null, null, '2', '1']);
  });

  group('add_plan — 확인 뒤에만 쓴다', () {
    test('등록 확인 → 실행', () async {
      final e = _engine([
        _a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}),
        _a('finish', {'answer': '등록했어요'}),
      ]);
      final o = await e.engine.run('금요일 저녁 모임에 입을 옷 준비해줘');
      expect(e.confirms, [(DateTime(2026, 11, 20), '모임')]);
      expect(e.data.writes.length, 1);
      expect(o.plannedDate, DateTime(2026, 11, 20));
    });
    test('취소 → 사용자가 취소함, 같은 요청에서 다시 내도 실행하지 않는다', () async {
      final e = _engine([
        _a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}),
        _a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}),
        _a('finish', {'answer': '취소했어요'}),
      ], confirm: false);
      final o = await e.engine.run('x');
      expect(e.data.writes, isEmpty);
      expect(e.confirms.length, 1);
      expect(o.steps[0].observation, contains('사용자가 취소함'));
      expect(o.steps[1].observation, contains('다시 실행하지 않아요'));
    });
    test('잘못된 날짜(지난 날)는 확인 카드 없이 거절', () async {
      final e = _engine([
        _a('add_plan', {'date': '2026-11-10', 'tpo': '모임'}),
        _a('finish', {'answer': 'x'}),
      ]);
      await e.engine.run('x');
      expect(e.confirms, isEmpty);
      expect(e.data.writes, isEmpty);
    });
  });

  test('ask_user는 1회 — 두 번째는 관찰로 거절', () async {
    final e = _engine([
      _a('ask_user', {'question': '언제, 어떤 일정인가요?'}),
      _a('ask_user', {'question': '또?'}),
      _a('finish', {'answer': 'x'}),
    ]);
    final o = await e.engine.run('옷 좀 준비해줘');
    expect(o.steps[0].observation, '사용자의 답: 금요일 모임');
    expect(o.steps[1].observation, contains('한 번만'));
  });

  test('호출량 초과는 재시도하지 않고 안내하고 끝', () async {
    final e = _engine([RateLimitExceededException('상한'), _a('finish', {'answer': 'x'})]);
    final o = await e.engine.run('x');
    expect(o.end, AskEnd.rateLimited);
    expect(o.modelCalls, 1);
    expect(o.answer, contains('잠시 뒤에'));
  });

  test('단계 시한을 넘기면 끝', () async {
    final e = _engine([Future<Map<String, dynamic>>.delayed(const Duration(seconds: 2), () => _a('finish', {'answer': 'x'}))],
        stepTimeout: const Duration(milliseconds: 50));
    expect((await e.engine.run('x')).end, AskEnd.timeout);
  });

  test('사용자 차례(확인·질문)에서 기다리는 시간은 요청 전체 시한에 세지 않는다(§10)', () async {
    final data = FakeAskData(snap: askSnapshot(), prepareResult: false);
    final model = _Script([
      _a('ask_user', {'question': '언제인가요?'}),
      _a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}),
      _a('finish', {'answer': '등록했어요'}),
    ]);
    final engine = AskEngine(
      tools: askTools(data),
      callModel: model.call,
      buildPrompt: _prompt,
      totalTimeout: const Duration(milliseconds: 150),
      confirmPlan: (_, __) => Future.delayed(const Duration(milliseconds: 300), () => true),
      askUser: (_) => Future.delayed(const Duration(milliseconds: 300), () => '금요일'),
    );
    final o = await engine.run('옷 좀 준비해줘');
    expect(o.end, AskEnd.finished);
    expect(data.writes.length, 1);
  });

  group('뒤로 나가기(cancel)', () {
    test('모델 응답을 기다리는 중에 나가면 결과를 버리고 끝', () async {
      final gate = Completer<Map<String, dynamic>>();
      final e = _engine([gate.future]);
      final run = e.engine.run('x');
      await Future<void>.delayed(Duration.zero);
      e.engine.cancel();
      gate.complete(_a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}));
      final o = await run;
      expect(o.end, AskEnd.cancelled);
      expect(e.confirms, isEmpty);
      expect(e.data.writes, isEmpty);
    });
    test('확인 카드가 떠 있는 동안 나가면 [등록]이 와도 쓰지 않는다', () async {
      final data = FakeAskData(snap: askSnapshot());
      late AskEngine engine;
      engine = AskEngine(
        tools: askTools(data),
        callModel: _Script([_a('add_plan', {'date': '2026-11-20', 'tpo': '모임'})]).call,
        buildPrompt: _prompt,
        confirmPlan: (d, t) async {
          engine.cancel(); // 확인 대기 중 화면을 떠남
          return true;
        },
        askUser: (_) async => null,
      );
      final o = await engine.run('x');
      expect(o.end, AskEnd.cancelled);
      expect(data.writes, isEmpty);
    });
  });
}
