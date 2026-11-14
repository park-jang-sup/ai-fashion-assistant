// 전신 사진 기본값과 채팅 안 바꾸기 — 선택이 없으면 앱이 고르고(마지막으로 쓴 것 → 가장 최근 등록),
// 모델에게 가는 글은 평소 성공 문장 그대로, 등록된 전신 사진이 없을 때만 실패와 카드,
// "다른 전신 사진으로"는 둘 이상일 때만·마지막 턴만·한 번만.
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:ai_fashion_assistant/services/full_body_default.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

final _bodies = [
  askW('b1', '전신', day: 1),
  askW('b2', '전신', day: 5),
  askW('b3', '전신', day: 3),
];

// 앱 쪽 피팅 경로 흉내 — main.dart의 _ensureFittingUserPhoto·_askTryOn과 같은 순서.
class _App {
  WardrobeItem? photo;
  bool auto = false;
  List<WardrobeItem> bodies;
  String? lastUsed;
  final runs = <String>[];
  _App(this.bodies, {this.photo, this.lastUsed});

  Future<bool> ensure() async {
    if (photo != null) return true;
    final pick = pickDefaultFullBody(bodies, lastUsed);
    if (pick == null) return false;
    photo = pick;
    auto = true;
    return true;
  }

  AskFittingPort port() => AskFittingPort(
        hasUserPhoto: () => photo != null,
        busy: () => false,
        ensureUserPhoto: ensure,
        run: (items) async {
          runs.add(photo!.id);
          return AskFittingOutcome(shot: AskFittingShot(bytes: Uint8List.fromList(_png), cacheKey: 'k', autoPicked: auto));
        },
      );
}

Future<(AskOutcome, AskTools)> _engine(_App app, List<Map<String, dynamic>> Function(List<String>) script) async {
  final tools = askTools(FakeAskData(snap: askSnapshot()));
  final combo = (await tools.previewOutfit({'date': '2026-11-16', 'tpo': '일상'})).items;
  final replies = script([for (final i in combo) '#${tools.book.numberOf(i)}']);
  var i = 0;
  final o = await AskEngine(
    tools: tools,
    callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
    buildPrompt: buildAskPrompt,
    confirmPlan: (_, __) async => false,
    askUser: (_) async => null,
    fitting: app.port(),
  ).run('입혀 봐줘');
  return (o, tools);
}

List<Map<String, dynamic>> _tryOnScript(List<String> nums) => [
      _a('preview_outfit', {'date': '2026-11-16', 'tpo': '일상'}),
      _a('try_on', {'outfit': nums}),
      _a('finish', {'answer': '입혀 봤어요.\n- 코디보드에도 올려 두었어요.\n- 따뜻해요.'}),
    ];

class _Store implements AskHistoryStore {
  @override
  Future<List<AskRecord>> recent() async => const [];
  @override
  Future<void> save(AskRecord record) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  group('기본값 순서', () {
    test('여러 장 — 마지막으로 쓴 것, 기록이 없거나 지워졌으면 가장 최근에 등록한 것', () {
      expect(pickDefaultFullBody(_bodies, 'b3')!.id, 'b3');
      expect(pickDefaultFullBody(_bodies, null)!.id, 'b2');
      expect(pickDefaultFullBody(_bodies, 'gone')!.id, 'b2');
    });
    test('한 장이면 그것, 0장이면 없음', () {
      expect(pickDefaultFullBody([_bodies.first], null)!.id, 'b1');
      expect(pickDefaultFullBody(const [], 'b1'), isNull);
    });
  });

  group('try_on', () {
    test('선택이 없으면 기본값을 잡고 입힌다 — 모델에게 가는 글은 선택이 있을 때의 성공 문장과 같다', () async {
      final auto = _App(_bodies, lastUsed: 'b3');
      final (o1, _) = await _engine(auto, _tryOnScript);
      final picked = _App(_bodies, photo: _bodies[2]);
      final (o2, _) = await _engine(picked, _tryOnScript);
      final s1 = o1.steps.firstWhere((s) => s.action == 'try_on');
      final s2 = o2.steps.firstWhere((s) => s.action == 'try_on');
      expect(auto.runs, ['b3']);
      expect(s1.status, AskStepStatus.done);
      expect(s1.observation, s2.observation); // 모델에게 가는 글 그대로
      expect(s1.display, s2.display);
      expect(s1.observation, isNot(contains(askAutoPickedNote)));
      expect(s1.fitting!.autoPicked, isTrue);
      expect(s2.fitting!.autoPicked, isFalse);
    });

    test('등록된 전신 사진이 0장이면 지금처럼 실패한다', () async {
      final none = _App(const []);
      final (o, _) = await _engine(none, _tryOnScript);
      final s = o.steps.firstWhere((s) => s.action == 'try_on');
      expect(s.status, AskStepStatus.failed);
      expect(s.observation, startsWith('전신 사진이 선택돼 있지 않아 입혀 보지 못했어요'));
      expect(none.runs, isEmpty);
      expect(askNoFullBody(o.steps), isTrue);
    });
  });

  group('채팅 화면', () {
    Future<(AskController, _App, List<String>)> pump(WidgetTester tester, List<WardrobeItem> bodies,
        {required int turns}) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tools = askTools(FakeAskData(snap: askSnapshot()));
      final combo = (await tools.previewOutfit({'date': '2026-11-16', 'tpo': '일상'})).items;
      final nums = [for (final i in combo) '#${tools.book.numberOf(i)}'];
      final app = _App(bodies);
      final replies = [for (var k = 0; k < turns; k++) ..._tryOnScript(nums)];
      var i = 0;
      final sent = <String>[];
      final c = AskController(
        currentUid: () => 'u',
        toolsFor: (_) => tools,
        callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
        logSink: (_) {},
        historyFor: (_) => _Store(),
        fitting: app.port(),
        now: () => DateTime(2026, 11, 16, 10),
      );
      c.addListener(() {
        if (c.turns.isNotEmpty && (sent.isEmpty || sent.length < c.turns.length)) sent.add(c.turns.last.request);
      });
      await tester.pumpWidget(MaterialApp(
        home: AskScreen(
          controller: c,
          loadFullBodies: () async => bodies,
          onPickFullBody: (b) => app
            ..photo = b
            ..auto = false,
        ),
      ));
      await tester.pump();
      return (c, app, sent);
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }

    testWidgets('기본값으로 입히면 단계 아래 "자동으로 골랐어요", 전신 사진이 둘 이상이면 바꾸기 버튼', (tester) async {
      final (c, _, _) = await pump(tester, _bodies, turns: 1);
      c.start('입혀 봐줘');
      await tester.pumpAndSettle();
      expect(find.text(askAutoPickedNote), findsOneWidget);
      expect(find.byKey(const Key('ask-other-full-body')), findsOneWidget);
      expect(find.byKey(const Key('ask-no-full-body')), findsNothing);
      await done(tester);
    });

    testWidgets('전신 사진이 한 장이면 바꾸기 버튼이 없다', (tester) async {
      final (c, _, _) = await pump(tester, [_bodies.first], turns: 1);
      c.start('입혀 봐줘');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask-other-full-body')), findsNothing);
      await done(tester);
    });

    testWidgets('0장이면 "등록된 전신 사진이 없어요" 카드와 옷장 버튼', (tester) async {
      final (c, _, _) = await pump(tester, const [], turns: 1);
      c.start('입혀 봐줘');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask-no-full-body')), findsOneWidget);
      expect(find.text(askNoFullBodyTitle), findsOneWidget);
      expect(find.text('옷장으로'), findsOneWidget);
      await done(tester);
    });

    testWidgets('고르면 선택 상태가 되고 "이 전신 사진으로 다시 입혀 줘"가 한 번만 나간다 — 지난 턴의 버튼은 동작하지 않는다',
        (tester) async {
      final (c, app, _) = await pump(tester, _bodies, turns: 2);
      c.start('입혀 봐줘');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ask-other-full-body')));
      await tester.pumpAndSettle();
      final b1 = find.byKey(const Key('ask-full-body-b1'));
      expect(b1, findsOneWidget);
      await tester.tap(b1);
      await tester.tap(b1, warnIfMissed: false); // 두 번 눌러도
      await tester.pumpAndSettle();
      expect(c.turns.length, 2);
      expect(c.turns.last.request, askRetryWithFullBody);
      expect(app.photo!.id, 'b1');
      expect(app.runs.last, 'b1');
      // 지난 턴(1턴)의 버튼은 꺼져 있고, 마지막 턴(2턴)의 버튼만 동작한다
      final buttons = tester.widgetList<OutlinedButton>(find.byKey(const Key('ask-other-full-body'))).toList();
      expect(buttons.length, 2);
      expect(buttons.first.onPressed, isNull);
      expect(buttons.last.onPressed, isNotNull);
      // 2턴은 사용자가 고른 사진이라 "자동으로 골랐어요"는 1턴에만
      expect(find.text(askAutoPickedNote), findsOneWidget);
      await done(tester);
    });
  });
}
