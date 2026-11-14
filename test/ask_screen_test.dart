// AI에게 부탁하기 전용 화면(docs/task_agent_ask_v1.md §2-5) — 가짜 모델·가짜 자료로 화면 흐름 확인.
import 'dart:async';

import 'package:ai_fashion_assistant/models/agent_log_entry.dart';
import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

class _Model {
  final List<Map<String, dynamic>> replies;
  var calls = 0;
  _Model(this.replies);
  Future<AskModelReply> call(String prompt) async => AskModelReply(replies[calls++], 'text-primary');
}

final _plan = [
  _a('get_weather', {'from': '2026-11-20', 'to': '2026-11-20'}),
  _a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}),
  _a('finish', {'answer': '금요일 모임 일정을 등록했어요'}),
];

Widget _host(Widget screen, {double textScale = 1}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('단계·확인 카드·답 카드 — 확인을 눌러야 등록된다', (tester) async {
    final data = FakeAskData(snap: askSnapshot(), prepareResult: false);
    final model = _Model(_plan);
    int? navigated;
    await tester.pumpWidget(_host(AskScreen(
      request: '금요일 저녁 모임에 입을 옷 준비해줘',
      tools: askTools(data),
      callModel: model.call,
      onNavigate: (i) => navigated = i,
    )));
    await _open(tester);
    expect(find.text('금요일 저녁 모임에 입을 옷 준비해줘'), findsOneWidget);
    expect(find.text('예보 확인'), findsOneWidget);
    expect(find.text('일정 등록'), findsOneWidget);
    expect(find.text('2026-11-20(금) [모임] 일정을 등록할까요?'), findsOneWidget);
    expect(data.writes, isEmpty);
    await tester.tap(find.text('등록하기'));
    await tester.pumpAndSettle();
    expect(data.writes.length, 1);
    expect(find.text('금요일 모임 일정을 등록했어요'), findsOneWidget);
    expect(find.text('새로 부탁하기'), findsOneWidget);
    expect(find.text('피팅룸에서 입어 보기'), findsNothing); // 사진 조합이 없으면 뺀다
    await tester.tap(find.text('캘린더에서 보기'));
    await tester.pumpAndSettle();
    expect(navigated, 3);
    expect(find.text('열기'), findsOneWidget);
  });

  testWidgets('확인 카드에서 뒤로 나가면 등록하지 않고 멈춘다', (tester) async {
    final data = FakeAskData(snap: askSnapshot(), prepareResult: false);
    final model = _Model(_plan);
    final logs = <AgentLogEntry>[];
    await tester.pumpWidget(
        _host(AskScreen(request: 'x', tools: askTools(data), callModel: model.call, logSink: logs.add)));
    await _open(tester);
    expect(find.text('등록하기'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('열기'), findsOneWidget);
    expect(data.writes, isEmpty);
    expect(model.calls, 2); // 확인 뒤의 호출(finish)은 하지 않았다
    // 활동 내역: 요청 문장 → 도구 줄 → 멈춤, 모두 같은 묶음.
    expect(logs.first.message, 'AI에게 부탁: x');
    expect(logs.last.message, startsWith('AI에게 부탁 멈춤'));
    expect(logs.map((e) => e.relatedDocId).toSet().length, 1);
  });

  testWidgets('질문 카드에 답하면 이어서 진행한다', (tester) async {
    final model = _Model([
      _a('ask_user', {'question': '언제 어떤 상황인가요?'}),
      _a('finish', {'answer': '알겠어요'}),
    ]);
    await tester.pumpWidget(_host(AskScreen(request: '옷 좀 준비해줘', tools: askTools(FakeAskData()), callModel: model.call)));
    await _open(tester);
    expect(find.text('언제 어떤 상황인가요?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '금요일 저녁 모임이에요');
    await tester.tap(find.text('보내기'));
    await tester.pumpAndSettle();
    expect(find.text('알겠어요'), findsOneWidget);
  });

  testWidgets('새로 부탁하기 — 같은 화면에서 다시 시작한다', (tester) async {
    final model = _Model([_a('finish', {'answer': '첫 답'}), _a('finish', {'answer': '둘째 답'})]);
    await tester.pumpWidget(_host(AskScreen(request: '첫 요청', tools: askTools(FakeAskData()), callModel: model.call)));
    await _open(tester);
    await tester.tap(find.text('새로 부탁하기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '둘째 요청');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('둘째 요청'), findsOneWidget);
    expect(find.text('둘째 답'), findsOneWidget);
  });

  testWidgets('글자를 두 배로 키운 좁은 화면에서도 버튼이 가려지지 않는다', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final data = FakeAskData(snap: askSnapshot(), prepareResult: false);
    await tester.pumpWidget(
        _host(AskScreen(request: '금요일 저녁 모임에 입을 옷 준비해줘', tools: askTools(data), callModel: _Model(_plan).call),
            textScale: 2));
    await _open(tester);
    await tester.scrollUntilVisible(find.text('등록하기'), 200);
    expect(find.text('등록하기').hitTestable(), findsOneWidget);
    await tester.tap(find.text('등록하기'));
    await tester.pumpAndSettle();
    for (final label in ['캘린더에서 보기', '새로 부탁하기']) {
      await tester.scrollUntilVisible(find.text(label), 200);
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('마스코트 이미지를 못 불러와도 깨지지 않는다(기본 아이콘)', (tester) async {
    final c = Completer<AskModelReply>();
    await tester.pumpWidget(_host(AskScreen(request: 'x', tools: askTools(FakeAskData()), callModel: (_) => c.future)));
    await tester.tap(find.text('열기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    c.complete(AskModelReply(_a('finish', {'answer': '끝'}), 'text-primary'));
    await tester.pumpAndSettle();
    expect(find.text('끝'), findsOneWidget);
  });
}
