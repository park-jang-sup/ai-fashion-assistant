// 음성 입력 — 에이전트 입력창의 마이크 버튼. 가짜 음성 엔진과 가짜 모델로 확인한다.
import 'dart:async';

import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/voice_input.dart';
import 'package:ai_fashion_assistant/widgets/voice_mic_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

class FakeVoice implements VoiceEngine {
  bool permission;
  VoiceInitResult initResult;
  FakeVoice({this.permission = true, this.initResult = VoiceInitResult.ready});

  var initCalls = 0;
  var listenCalls = 0;
  var stopCalls = 0;
  void Function(String, bool)? _onWords;
  void Function(double)? _onLevel;
  VoidCallback? _onDone;

  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<VoiceInitResult> init() async {
    initCalls++;
    return initResult;
  }

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
    required void Function(double level) onLevel,
    required VoidCallback onDone,
  }) async {
    listenCalls++;
    _onWords = onWords;
    _onLevel = onLevel;
    _onDone = onDone;
  }

  @override
  Future<void> stop() async => stopCalls++;

  void hear(String words, {bool isFinal = false}) => _onWords?.call(words, isFinal);
  void level(double v) => _onLevel?.call(v);
  void pause() => _onDone?.call(); // 말이 끊겨 기기 인식기가 이 세션을 끝냄
}

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

class _Store implements AskHistoryStore {
  final records = <AskRecord>[];
  @override
  Future<List<AskRecord>> recent() async => List.of(records);
  @override
  Future<void> save(AskRecord record) async {
    records.removeWhere((r) => r.id == record.id);
    records.insert(0, record);
  }

  @override
  Future<void> delete(String id) async => records.removeWhere((r) => r.id == id);
  @override
  Future<void> clear() async => records.clear();
}

({AskController c, List<String> prompts}) _ctl(List<Map<String, dynamic>> replies,
    {Map<int, Completer<void>> gates = const {}}) {
  final d = FakeAskData(snap: askSnapshot(), prepareResult: false);
  final prompts = <String>[];
  var i = 0;
  final c = AskController(
    currentUid: () => 'u',
    toolsFor: (_) => askTools(d),
    callModel: (p) async {
      final n = i++;
      prompts.add(p);
      await gates[n]?.future;
      return AskModelReply(replies[n], 'text-primary');
    },
    logSink: (_) {},
    historyFor: (_) => _Store(),
    now: () => DateTime(2026, 11, 16, 10, 5),
  );
  return (c: c, prompts: prompts);
}

Future<void> _open(WidgetTester tester, AskController c, FakeVoice v) async {
  await tester.pumpWidget(MaterialApp(home: AskScreen(controller: c, voiceEngine: v)));
  await tester.pumpAndSettle();
}

TextField _field(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).first);

Future<FakeVoice> _listening(WidgetTester tester, {String before = ''}) async {
  final v = FakeVoice();
  await _open(tester, _ctl([]).c, v);
  if (before.isNotEmpty) await tester.enterText(find.byType(TextField), before);
  await tester.tap(find.byKey(const Key('ask-mic')));
  await tester.pump();
  return v;
}

String _text(WidgetTester tester) => _field(tester).controller!.text;

double _ringScale(WidgetTester tester) =>
    tester.widget<Transform>(find.byKey(const Key('voice-ring'))).transform.getMaxScaleOnAxis();

void main() {
  test('소리 크기 값(rms dB) → 0~1, 원의 크기는 소리에 따라', () {
    expect(voiceLevelFromRms(-10), 0);
    expect(voiceLevelFromRms(10), 1);
    expect(voiceLevelFromRms(4), closeTo(0.5, 1e-9));
    expect(voiceRingScale(1), greaterThan(voiceRingScale(0)));
  });

  testWidgets('확정 글이 이어 붙는다 — 시작할 때 있던 글 뒤에', (tester) async {
    final v = await _listening(tester, before: '내일');
    v.hear('금요일 저녁', isFinal: true);
    v.hear('모임 옷', isFinal: true);
    await tester.pump();
    expect(_text(tester), '내일 금요일 저녁 모임 옷');
  });

  testWidgets('임시 글이 확정 글을 지우지 않는다', (tester) async {
    final v = await _listening(tester);
    v.hear('오늘', isFinal: true);
    v.hear('날씨');
    await tester.pump();
    expect(_text(tester), '오늘 날씨');
    v.hear('날씨 어때');
    await tester.pump();
    expect(_text(tester), '오늘 날씨 어때');
    v.hear('날씨 어때', isFinal: true);
    v.hear('알려줘');
    await tester.pump();
    expect(_text(tester), '오늘 날씨 어때 알려줘');
  });

  testWidgets('누적형 결과(앞 구간을 다시 담아 옴)도 겹치지 않는다', (tester) async {
    final v = await _listening(tester);
    v.hear('빠르게 말한 것', isFinal: true);
    v.hear('빠르게 말한 것 천천히');
    await tester.pump();
    expect(_text(tester), '빠르게 말한 것 천천히');
  });

  testWidgets('말이 끊겨 기기 인식이 끝나도 이어 듣고, 앞의 글이 남는다', (tester) async {
    final v = await _listening(tester);
    v.hear('빠르게 말한 것'); // 임시 글인 채로 끊김
    v.pause();
    await tester.pump(voiceRestartDelay + const Duration(milliseconds: 10));
    expect(v.listenCalls, 2);
    expect(v.stopCalls, 0);
    v.hear('천천히 말한 것');
    await tester.pump();
    expect(_text(tester), '빠르게 말한 것 천천히 말한 것');
    // 늦게 온 앞 세션의 결과는 무시된다(세션이 바뀜).
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
  });

  testWidgets('6초 동안 새 말이 없으면 스스로 끈다 — 말이 오면 다시 잰다', (tester) async {
    final v = await _listening(tester);
    await tester.pump(const Duration(seconds: 4));
    v.hear('안녕');
    await tester.pump(const Duration(seconds: 4));
    expect(v.stopCalls, 0); // 마지막 말에서 4초
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    expect(v.stopCalls, 1);
    expect(find.byKey(const Key('voice-ring')), findsNothing);
    expect(_text(tester), '안녕'); // 글은 그대로
  });

  testWidgets('한 번 켠 뒤 60초가 지나면 끈다', (tester) async {
    final v = await _listening(tester);
    for (var i = 0; i < 12; i++) {
      v.hear('말 $i');
      await tester.pump(const Duration(seconds: 5));
    }
    expect(v.stopCalls, 1);
  });

  testWidgets('듣는 중에 손으로 고치면 멈춘다', (tester) async {
    final v = await _listening(tester);
    v.hear('금요일');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '금요일 저녁');
    await tester.pump();
    expect(v.stopCalls, 1);
    v.hear('금요일 점심');
    await tester.pump();
    expect(_text(tester), '금요일 저녁');
  });

  testWidgets('소리 크기에 따라 원이 커졌다 작아지고, 값이 없으면 맥박, 꺼지면 원이 없다', (tester) async {
    final v = await _listening(tester);
    // 값이 아직 없으면 일정한 맥박 — 시간에 따라 크기가 바뀐다.
    await tester.pump(const Duration(milliseconds: 100));
    final p1 = _ringScale(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_ringScale(tester), isNot(closeTo(p1, 1e-3)));
    v.level(1);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final loud = _ringScale(tester);
    v.level(0);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final quiet = _ringScale(tester);
    expect(loud, greaterThan(quiet + 0.3));
    // 원이 움직여도 보내기 버튼 자리는 그대로.
    final send = tester.getTopLeft(find.byTooltip('보내기'));
    v.level(1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(find.byTooltip('보내기')), send);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    expect(find.byKey(const Key('voice-ring')), findsNothing);
  });

  testWidgets('첫 화면 안내 글은 고정, 이어서 말하기 안내는 음성 입력 여부로', (tester) async {
    final t = _ctl([_a('finish', {'answer': '알겠어요'})]);
    await _open(tester, t.c, FakeVoice());
    expect(_field(tester).decoration!.hintText, askHomeHint);
    await tester.enterText(find.byType(TextField), '내일 뭐 입지?');
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();
    expect(_field(tester).decoration!.hintText, askContinueHintVoice);
  });

  testWidgets('쓸 수 없으면 마이크 버튼이 없고, 오류 창도 없다', (tester) async {
    final t = _ctl([_a('finish', {'answer': '알겠어요'})]);
    await _open(tester, t.c, FakeVoice(permission: true, initResult: VoiceInitResult.unavailable));
    expect(find.byKey(const Key('ask-mic')), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await tester.enterText(find.byType(TextField), '내일 뭐 입지?');
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();
    expect(_field(tester).decoration!.hintText, askContinueHintText);
  });

  testWidgets('권한이 없으면 화면을 열 때 묻지 않고, 누른 뒤 지원하지 않으면 버튼을 숨긴다', (tester) async {
    final v = FakeVoice(permission: false, initResult: VoiceInitResult.unavailable);
    await _open(tester, _ctl([]).c, v);
    expect(v.initCalls, 0);
    expect(find.byKey(const Key('ask-mic')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pumpAndSettle();
    expect(v.initCalls, 1);
    expect(find.byKey(const Key('ask-mic')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('알아들은 글자가 입력창에 들어가고, 자동으로 보내지 않는다', (tester) async {
    final t = _ctl([_a('finish', {'answer': '알겠어요'})]);
    final v = FakeVoice();
    await _open(tester, t.c, v);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    expect(v.listenCalls, 1);
    expect(tester.widget<Icon>(find.descendant(of: find.byKey(const Key('ask-mic')), matching: find.byType(Icon))).icon,
        Icons.mic);
    v.hear('내일');
    v.hear('내일 뭐 입지');
    await tester.pump();
    expect(_field(tester).controller!.text, '내일 뭐 입지');
    await tester.tap(find.byKey(const Key('ask-mic'))); // 끈다
    await tester.pumpAndSettle();
    expect(tester.widget<Icon>(find.descendant(of: find.byKey(const Key('ask-mic')), matching: find.byType(Icon))).icon,
        Icons.mic_none);
    expect(t.prompts, isEmpty);
    expect(t.c.hasConversation, isFalse);
    // 고쳐서 보내기.
    await tester.enterText(find.byType(TextField), '내일 뭐 입지?');
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();
    expect(t.c.turns.single.request, '내일 뭐 입지?');
  });

  testWidgets('다시 누르면 멈춘다 — 멈춘 뒤 늦게 온 글자는 채우지 않는다', (tester) async {
    final v = FakeVoice();
    await _open(tester, _ctl([]).c, v);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    v.hear('안녕');
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    expect(v.stopCalls, 1);
    v.hear('안녕 하세요');
    await tester.pump();
    expect(_field(tester).controller!.text, '안녕');
  });

  testWidgets('권한을 거절하면 한 줄 안내가 나오고, 글로 입력은 된다', (tester) async {
    final t = _ctl([_a('finish', {'answer': '알겠어요'})]);
    final v = FakeVoice(permission: false, initResult: VoiceInitResult.denied);
    await _open(tester, t.c, v);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    expect(find.text(voiceDeniedMessage), findsOneWidget);
    expect(v.listenCalls, 0);
    await tester.enterText(find.byType(TextField), '내일 뭐 입지?');
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();
    expect(t.c.turns.single.request, '내일 뭐 입지?');
  });

  testWidgets('턴이 진행 중이면 듣기를 멈춘다', (tester) async {
    final gate = Completer<void>();
    final t = _ctl([_a('finish', {'answer': '알겠어요'})], gates: {0: gate});
    final v = FakeVoice();
    await _open(tester, t.c, v);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    // 듣는 중에 다른 경로(전신 사진 다시 입혀 보기 등)로 턴이 시작된다 — 입력창 대신 진행 줄.
    t.c.start('내일 뭐 입지?');
    await tester.pump();
    expect(find.byKey(const Key('ask-mic')), findsNothing);
    expect(t.c.isRunning, isTrue);
    expect(v.stopCalls, greaterThanOrEqualTo(1));
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('질문에 답하기 입력창에도 마이크 — 채우기만 하고, 질문이 끝나면 멈춘다', (tester) async {
    final t = _ctl([_a('ask_user', {'question': '언제인가요?'}), _a('finish', {'answer': '알겠어요'})]);
    final v = FakeVoice();
    await _open(tester, t.c, v);
    await tester.enterText(find.byType(TextField), '모임 옷 골라줘');
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();
    expect(find.text('언제인가요?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ask-answer-mic')));
    await tester.pump();
    v.hear('금요일 저녁');
    await tester.pump();
    final answer = tester.widget<TextField>(find.byType(TextField).last);
    expect(answer.controller!.text, '금요일 저녁');
    expect(t.prompts.length, 1); // 보내지 않았다
    await tester.tap(find.widgetWithText(FilledButton, '보내기'));
    await tester.pumpAndSettle();
    expect(v.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('언제인가요?'), findsNothing);
  });

  testWidgets('화면을 떠나면 듣기를 멈춘다', (tester) async {
    final v = FakeVoice();
    await _open(tester, _ctl([]).c, v);
    await tester.tap(find.byKey(const Key('ask-mic')));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(v.stopCalls, 1);
  });
}
