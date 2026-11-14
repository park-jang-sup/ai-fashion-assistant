// AI에게 부탁하기 — 앱 수준 컨트롤러·전용 화면·떠 있는 버튼(docs/task_agent_ask_v1.md §10).
// 가짜 모델·가짜 자료·가짜 기록 저장소로 흐름을 확인한다.
import 'dart:async';

import 'package:ai_fashion_assistant/models/agent_log_entry.dart';
import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/widgets/ask_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

// 정해진 답을 차례로 낸다. gates[i]가 있으면 i번째 호출은 그 Completer가 끝날 때까지 기다린다.
class _Model {
  final List<Map<String, dynamic>> replies;
  final Map<int, Completer<void>> gates;
  var calls = 0;
  _Model(this.replies, {this.gates = const {}});
  Future<AskModelReply> call(String prompt) async {
    final i = calls++;
    await gates[i]?.future;
    return AskModelReply(replies[i], 'text-primary');
  }
}

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

final _plan = [
  _a('get_weather', {'from': '2026-11-20', 'to': '2026-11-20'}),
  _a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}),
  _a('finish', {'answer': '금요일 모임 일정을 등록했어요'}),
];

({AskController c, FakeAskData data, _Model model, _Store store, List<AgentLogEntry> logs}) _ctl(
  List<Map<String, dynamic>> replies, {
  Map<int, Completer<void>> gates = const {},
  FakeAskData? data,
}) {
  final d = data ?? FakeAskData(snap: askSnapshot(), prepareResult: false);
  final model = _Model(replies, gates: gates);
  final store = _Store();
  final logs = <AgentLogEntry>[];
  final c = AskController(
    currentUid: () => 'u',
    toolsFor: (_) => askTools(d),
    callModel: model.call,
    logSink: logs.add,
    historyFor: (_) => store,
    now: () => DateTime(2026, 11, 16, 10, 5),
  );
  return (c: c, data: d, model: model, store: store, logs: logs);
}

// 탭 화면 흉내 — 떠 있는 버튼을 누르면 전용 화면이 열린다(AppShell과 같은 배선).
Widget _shell(AskController c, {double textScale = 1, ValueChanged<int>? onNavigate}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Stack(children: [
              const Center(child: Text('탭 화면')),
              Positioned(
                right: 18,
                bottom: 84,
                child: AskFab(
                  controller: c,
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => AskScreen(controller: c, onNavigate: onNavigate))),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

Future<void> _openScreen(WidgetTester tester) async {
  await tester.tap(find.byType(AskFab));
  await tester.pumpAndSettle();
}

Finder get _ring => find.byKey(const Key('ask-fab-ring'));
Finder get _dot => find.byKey(const Key('ask-fab-dot'));

void main() {
  testWidgets('첫 상태: 인사말·예시 3개·입력·지난 부탁 — 예시를 누르면 바로 시작', (tester) async {
    final t = _ctl([_a('finish', {'answer': '내일은 비가 와요'})]);
    await tester.pumpWidget(_shell(t.c));
    await _openScreen(tester);
    expect(find.text('무엇을 도와드릴까요?\n옷장·일정·날씨를 확인해 코디를 도와드려요.'), findsOneWidget);
    for (final e in askExamples) {
      expect(find.text(e), findsOneWidget);
    }
    expect(find.text('지난 부탁'), findsOneWidget);
    expect(find.text('아직 없어요'), findsOneWidget);
    await tester.tap(find.text('내일 비 오면 뭐 입지?'));
    await tester.pumpAndSettle();
    expect(find.text('내일은 비가 와요'), findsOneWidget);
  });

  testWidgets('화면을 닫아도 진행이 이어지고, 버튼을 누르면 그 대화가 그대로 열린다', (tester) async {
    final gate = Completer<void>();
    final t = _ctl([_a('get_weather', {'from': '2026-11-17', 'to': '2026-11-17'}), _a('finish', {'answer': '우산을 챙기세요'})],
        gates: {1: gate});
    await tester.pumpWidget(_shell(t.c));
    await _openScreen(tester);
    await tester.enterText(find.byType(TextField), '내일 비 와?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump();
    expect(find.text('예보 확인'), findsOneWidget);
    await tester.pageBack(); // 닫기 — 멈추지 않는다
    // 진행 고리가 계속 돌아 settle하지 않으므로 전환이 끝날 만큼 프레임을 넘긴다.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AskScreen), findsNothing);
    expect(t.c.isRunning, isTrue);
    expect(_ring, findsOneWidget); // 진행 고리
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(t.c.outcome?.end, AskEnd.finished);
    expect(_dot, findsOneWidget); // 닫힌 동안 나온 답 → 점
    await _openScreen(tester);
    expect(find.text('내일 비 와?'), findsOneWidget);
    expect(find.text('예보 확인'), findsOneWidget);
    expect(find.text('우산을 챙기세요'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_dot, findsNothing); // 본 답은 점을 지운다
    expect(_ring, findsNothing);
  });

  testWidgets('화면이 닫힌 동안 add_plan은 실행되지 않고 확인을 기다린다', (tester) async {
    final t = _ctl(_plan);
    await tester.pumpWidget(_shell(t.c));
    t.c.start('금요일 저녁 모임에 입을 옷 준비해줘'); // 화면을 열지 않은 채
    await tester.pump(const Duration(seconds: 5));
    expect(t.c.confirmArgs, isNotNull);
    expect(t.c.userTurn, isTrue);
    expect(t.data.writes, isEmpty);
    expect(_dot, findsOneWidget); // 사용자 차례 → 점
    expect(t.model.calls, 2);
    await _openScreen(tester);
    expect(find.text('11/20(금) · 이번 주 금요일 [모임] 일정을 등록할까요?'), findsOneWidget);
    await tester.tap(find.text('등록하기'));
    await tester.pumpAndSettle();
    expect(t.data.writes.length, 1);
    expect(find.text('금요일 모임 일정을 등록했어요'), findsOneWidget);
  });

  testWidgets('[멈추기] — 기다리던 확인은 등록하지 않고, 기록은 멈춤으로 남는다', (tester) async {
    final t = _ctl(_plan);
    await tester.pumpWidget(_shell(t.c));
    await _openScreen(tester);
    await tester.tap(find.text(askExamples.first));
    await tester.pumpAndSettle();
    expect(find.text('등록하기'), findsOneWidget);
    await tester.tap(find.text('멈추기'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing); // 멈춘 뒤 남는 진행 표시 없음
    expect(t.c.outcome?.end, AskEnd.cancelled);
    expect(t.data.writes, isEmpty);
    expect(t.model.calls, 2);
    expect(find.text('여기서 멈췄어요'), findsOneWidget);
    expect(t.store.records.single.end, 'cancelled');
    expect(t.logs.last.message, startsWith('AI에게 부탁 멈춤'));
  });

  testWidgets('진행 중에 새 부탁을 하면 멈출지 묻는다', (tester) async {
    final gate = Completer<void>();
    final t = _ctl([_a('finish', {'answer': '첫 답'}), _a('finish', {'answer': '둘째 답'})], gates: {0: gate});
    await tester.pumpWidget(_shell(t.c));
    await _openScreen(tester);
    await tester.enterText(find.byType(TextField), '첫 요청');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(t.c.start('끼어든 요청'), isFalse); // 한 번에 하나만
    await tester.tap(find.text('새 대화'));
    await tester.pump();
    expect(find.text('진행 중인 부탁을 멈추고 새 대화를 시작할까요?'), findsOneWidget);
    await tester.tap(find.text('계속 진행'));
    await tester.pump();
    expect(t.c.request, '첫 요청');
    await tester.tap(find.text('새 대화'));
    await tester.pump();
    await tester.tap(find.text('멈추기').last);
    await tester.pump();
    expect(t.c.request, isNull); // 첫 상태
    expect(find.text('무엇을 도와드릴까요?\n옷장·일정·날씨를 확인해 코디를 도와드려요.'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(t.store.records.single.request, '첫 요청');
    expect(t.store.records.single.end, 'cancelled');
    await tester.enterText(find.byType(TextField), '둘째 요청');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('둘째 답'), findsOneWidget);
  });

  testWidgets('기록 저장과 다시 보기(읽기 전용)', (tester) async {
    final t = _ctl(_plan);
    await tester.pumpWidget(_shell(t.c));
    await _openScreen(tester);
    await tester.tap(find.text(askExamples.first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('등록하기'));
    await tester.pumpAndSettle();
    final r = t.store.records.single;
    expect(r.request, askExamples.first);
    expect(r.end, 'finished');
    expect(r.answer, '금요일 모임 일정을 등록했어요');
    expect([for (final s in r.steps) s.action], ['get_weather', 'add_plan']);
    expect(r.steps.first.summary, '11/20(금) 최고 13° 최저 5° · 선선');
    expect(r.createdAt, DateTime(2026, 11, 16, 10, 5));
    // 저장 형식 왕복
    final back = AskRecord.fromMap(r.toMap());
    expect(back.toMap(), r.toMap());
    await tester.tap(find.text('새 대화'));
    await tester.pumpAndSettle();
    expect(find.text('11/16 10:05 · 답'), findsOneWidget);
    await tester.tap(find.text(askExamples.first).last); // 지난 부탁 줄
    await tester.pumpAndSettle();
    expect(find.byType(AskRecordScreen), findsOneWidget);
    expect(find.text('금요일 모임 일정을 등록했어요'), findsOneWidget);
  });

  testWidgets('지난 부탁을 누르면 그 대화를 읽기 전용으로 보여 준다', (tester) async {
    final t = _ctl(const []);
    t.store.records.add(AskRecord.single(
      request: '내일 데이트 일정 있어?',
      createdAt: DateTime(2026, 11, 15, 9, 0),
      end: 'finished',
      answer: '네, 내일 데이트 일정이 있어요.',
      steps: const [AskRecordStep(action: 'get_calendar', thought: '일정을 볼게요', summary: '2026-11-17(화) [데이트] 예정')],
    ));
    await tester.pumpWidget(_shell(t.c));
    await _openScreen(tester);
    await tester.tap(find.text('내일 데이트 일정 있어?'));
    await tester.pumpAndSettle();
    expect(find.byType(AskRecordScreen), findsOneWidget);
    expect(find.text('일정 확인'), findsOneWidget);
    expect(find.text('일정을 볼게요'), findsOneWidget);
    expect(find.text('네, 내일 데이트 일정이 있어요.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('멈추기'), findsNothing);
  });

  testWidgets('버튼 상태 — 평소·진행 중(고리)·사용자 차례(점), 말풍선', (tester) async {
    final gate = Completer<void>();
    final t = _ctl([_a('ask_user', {'question': '언제인가요?'}), _a('finish', {'answer': '알겠어요'})], gates: {0: gate});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: AskFab(controller: t.c, onTap: () {}, showBubble: true)))));
    expect(_ring, findsNothing);
    expect(_dot, findsNothing);
    expect(find.byKey(const Key('ask-fab-bubble')), findsOneWidget);
    t.c.start('옷 좀 준비해줘');
    await tester.pump();
    expect(t.c.buttonState, AskButtonState.running);
    expect(_ring, findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(t.c.buttonState, AskButtonState.attention);
    expect(_dot, findsOneWidget);
    expect(_ring, findsNothing);
    t.c.answerQuestion('금요일');
    await tester.pump();
    await tester.pump();
    expect(t.c.outcome?.end, AskEnd.finished);
    expect(_dot, findsOneWidget); // 안 본 답
    t.c.attach();
    await tester.pump();
    expect(_dot, findsNothing);
    t.c.detach();
  });

  test('지난 부탁은 최신이 앞, 최대 20건', () {
    var entries = <Map<String, dynamic>>[];
    for (var i = 0; i < 25; i++) {
      entries = upsertAskRecord(entries,
          AskRecord.single(request: '요청 $i', createdAt: DateTime(2026, 11, 16, 10, i), end: 'finished', answer: '답'));
    }
    String req(Map<String, dynamic> e) => AskRecord.fromMap(e).request;
    expect(entries.length, askHistoryMax);
    expect(req(entries.first), '요청 24');
    expect(req(entries.last), '요청 5');
  });

  test('탭별 자리 — 옷장은 추가 버튼 위, 피팅룸은 머리글 오른쪽 위, 나머지는 가상 피팅 표시 위', () {
    final home = askFabPlacementFor(0);
    expect((home.right, home.bottom, home.top), (18.0, 84.0, null));
    // 가상 피팅 진행 표시: 오른쪽 아래 16px, 56px → 위쪽 끝 72px. 버튼 아래쪽 84px > 72px.
    expect(home.bottom! > 16 + 56, isTrue);
    final wardrobe = askFabPlacementFor(1);
    expect(wardrobe.bottom! > 74 + 56, isTrue); // 추가 버튼(아래 74px, 56px) 위
    final fitting = askFabPlacementFor(2);
    expect((fitting.top, fitting.bottom), (18.0, null));
    for (final tab in [3, 4]) {
      expect(askFabPlacementFor(tab).bottom, 84.0);
    }
  });

  testWidgets('글자를 두 배로 키운 좁은 화면에서도 버튼이 가려지지 않는다', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final t = _ctl(_plan);
    await tester.pumpWidget(_shell(t.c, textScale: 2));
    await _openScreen(tester);
    await tester.tap(find.text(askExamples.first));
    await tester.pumpAndSettle();
    for (final label in ['등록하기', '멈추기']) {
      await tester.scrollUntilVisible(find.text(label), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    await tester.tap(find.text('등록하기'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('캘린더에서 보기'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('캘린더에서 보기').hitTestable(), findsOneWidget);
    expect(find.text('새 대화').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('캘린더에서 보기 — 화면을 닫고 캘린더 탭으로', (tester) async {
    final t = _ctl([_a('finish', {'answer': '끝'})]);
    int? tab;
    await tester.pumpWidget(_shell(t.c, onNavigate: (i) => tab = i));
    await _openScreen(tester);
    await tester.tap(find.text(askExamples[1]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('캘린더에서 보기'));
    await tester.pumpAndSettle();
    expect(tab, 3);
    expect(find.text('탭 화면'), findsOneWidget);
  });

  testWidgets('이어지는 대화 — 답 뒤에 입력창이 남고, 다음 턴에 이전 턴과 [현재 코디]가 넘어간다', (tester) async {
    final prompts = <String>[];
    final t = _ctl([
      _a('preview_outfit', {'date': '2026-11-17', 'tpo': '일상'}),
      _a('finish', {'answer': '내일은 이 코디예요\n- 비가 와요'}),
      _a('finish', {'answer': '자켓을 바꿨어요'}),
    ]);
    final c = AskController(
      currentUid: () => 'u',
      toolsFor: (_) => askTools(t.data),
      callModel: (p) {
        prompts.add(p);
        return t.model.call(p);
      },
      logSink: t.logs.add,
      historyFor: (_) => t.store,
      now: () => DateTime(2026, 11, 16, 10, 5),
    );
    await tester.pumpWidget(_shell(c));
    await _openScreen(tester);
    await tester.enterText(find.byType(TextField), '내일 뭐 입지?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('내일은 이 코디예요\n- 비가 와요'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // 입력창이 남는다
    expect(c.currentOutfit?.tpo, '일상');
    await tester.enterText(find.byType(TextField), '자켓만 바꿔 줘');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(c.turns.length, 2);
    final second = prompts.last;
    expect(second, contains('[이전 대화]'));
    expect(second, contains('1. 사용자: 내일 뭐 입지?'));
    expect(second, contains('[현재 코디] 11/17(화) [일상] 기준: #'));
    expect(second, isNot(contains('도구: preview_outfit'))); // 이전 턴의 단계는 넣지 않는다
    expect(find.text('자켓을 바꿨어요'), findsOneWidget);
    // 대화 내역 한 건 = 대화 전체.
    final r = t.store.records.single;
    expect([for (final x in r.turns) x.request], ['내일 뭐 입지?', '자켓만 바꿔 줘']);
    expect(AskRecord.fromMap(r.toMap()).turns.length, 2);
    // 답 카드의 옷 사진(서명 URL 재시도 타이머)을 정리한다.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });

  test('대화 하나는 10턴까지 — 넘으면 시작하지 않는다', () async {
    final t = _ctl([for (var i = 0; i < 11; i++) _a('finish', {'answer': '답 $i'})]);
    for (var i = 0; i < askMaxTurns; i++) {
      expect(t.c.start('말 $i'), isTrue);
      await pumpEventQueue();
    }
    expect(t.c.turns.length, 10);
    expect(t.c.turnLimitReached, isTrue);
    expect(t.c.start('11번째'), isFalse);
    t.c.clear();
    expect(t.c.start('새 대화'), isTrue);
  });

  test('v1 형식으로 저장된 기록은 한 턴짜리 대화로 읽는다, 답은 2,000자까지', () {
    final v1 = {
      'request': '내일 비 와?',
      'createdAt': DateTime(2026, 11, 14).millisecondsSinceEpoch,
      'end': 'finished',
      'answer': '네',
      'steps': [
        {'action': 'get_weather', 'thought': 't', 'summary': '2026-11-15(일): 최고 9°C'},
      ],
      'items': const [],
    };
    final r = AskRecord.fromMap(v1);
    expect(r.turns.length, 1);
    expect(r.request, '내일 비 와?');
    expect(r.steps.single.summary, '2026-11-15(일): 최고 9°C');
    final long = AskRecord.single(request: 'x', createdAt: DateTime(2026), end: 'finished', answer: '가' * 3000);
    expect((long.toMap()['turns'] as List).first['answer'].length, askRecordAnswerMax);
  });
}
