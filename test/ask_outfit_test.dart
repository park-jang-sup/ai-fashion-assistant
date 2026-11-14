// 고른 조합을 하나로(docs/task_agent_ask_v2.md 실행 기록 "v2.1" A) — finish의 outfit, 이번 턴의 조합을 정하는
// 순서(finish의 outfit → 성공한 try_on → 옷이 붙은 마지막 단계 → 이전 [현재 코디]), 대화 내역.
// 답 아래 사진·"피팅룸에서 입어 보기"·대화 내역의 사진은 이번 턴에 정해진 조합(1~3)만, 이전 [현재 코디](4)는
// 다음 턴의 [현재 코디]에만 쓴다.
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

const _pv = {'date': '2026-11-16', 'tpo': '일상', 'count': 5};

List<String> _ids(List<WardrobeItem> items) => [for (final i in items) i.id];

// 같은 가짜 옷장의 미리 보기 결과(결정적)와 옷 번호 — 엔진 안의 미리 보기도 같은 조합을 낸다.
Future<(AskTools, List<List<WardrobeItem>>, List<String> Function(List<WardrobeItem>))> _setup() async {
  final tools = askTools(FakeAskData(snap: askSnapshot()));
  final combos = (await tools.previewOutfit(_pv)).combos;
  expect(combos.length, 2);
  List<String> nums(List<WardrobeItem> c) => [for (final i in c) '#${tools.book.numberOf(i)}'];
  return (tools, combos, nums);
}

// 1×1 투명 PNG — 대화 화면이 피팅 사진을 실제로 그리므로 읽을 수 있는 그림이어야 한다.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

AskFittingPort _port() => AskFittingPort(
      hasUserPhoto: () => true,
      busy: () => false,
      run: (_) async => AskFittingOutcome(shot: AskFittingShot(bytes: Uint8List.fromList(_png), cacheKey: 'k1')),
    );

Future<AskOutcome> _run(AskTools tools, List<Map<String, dynamic>> replies, {AskOutfit? current}) {
  var i = 0;
  return AskEngine(
    tools: tools,
    callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
    buildPrompt: buildAskPrompt,
    confirmPlan: (_, __) async => false,
    askUser: (_) async => null,
    fitting: _port(),
  ).run('코디 골라줘', current: current);
}

void main() {
  group('finish의 outfit 읽기', () {
    late AskTools tools;
    late List<List<WardrobeItem>> combos;
    late List<String> Function(List<WardrobeItem>) nums;
    setUp(() async => (tools, combos, nums) = await _setup());
    WardrobeItem? item(int n) => tools.book.item(n);

    test('목록 — "#번호", 숫자, "#" 없는 글자 모두', () {
      final c = combos[1];
      final n = [for (final i in c) tools.book.numberOf(i)];
      expect(_ids(askFinishOutfit(nums(c), item)), _ids(c));
      expect(_ids(askFinishOutfit(n, item)), _ids(c));
      expect(_ids(askFinishOutfit([for (final x in n) '$x'], item)), _ids(c));
      expect(_ids(askFinishOutfit([for (final x in n) x.toDouble()], item)), _ids(c));
    });

    test('문자열 하나 — 그 안의 번호들', () {
      final c = combos[1];
      expect(_ids(askFinishOutfit(nums(c).join(', '), item)), _ids(c));
      expect(_ids(askFinishOutfit('${nums(c).join(' ')} 조합', item)), _ids(c));
    });

    test('잘못된 형·없는 번호 — 버리고, 남은 것이 없으면 빈 목록', () {
      expect(askFinishOutfit(null, item), isEmpty);
      expect(askFinishOutfit(true, item), isEmpty);
      expect(askFinishOutfit({'a': '#1'}, item), isEmpty);
      expect(askFinishOutfit(['#999', '#998'], item), isEmpty);
      final c = combos[0];
      expect(_ids(askFinishOutfit(['#999', ...nums(c), nums(c).first], item)), _ids(c)); // 없는 번호·겹친 번호는 뺀다
    });

    test('잘못된 outfit은 규약 위반이 아니다', () {
      for (final v in [true, 3, '없음', ['#999'], {'x': 1}]) {
        expect(validateAskReply(_a('finish', {'answer': '끝', 'outfit': v}), knownItem: tools.book.has), isNull);
      }
    });
  });

  group('이번 턴의 조합을 정하는 순서', () {
    test('1) finish의 outfit — 미리 보기의 2번 조합, 날짜·상황은 미리 보기에서', () async {
      final (tools, combos, nums) = await _setup();
      final o = await _run(tools, [
        _a('preview_outfit', _pv),
        _a('finish', {'answer': '2번 조합을 가장 권해요.\n- 따뜻해요.\n- 색이 이어져요.', 'outfit': nums(combos[1])}),
      ]);
      expect(_ids(o.outfit!.items), _ids(combos[1]));
      expect(o.outfit!.date, DateTime(2026, 11, 16));
      expect(o.outfit!.tpo, '일상');
      expect(_ids(askCombo(o)), _ids(combos[1]));
    });

    test('1) finish의 outfit이 try_on보다 먼저', () async {
      final (tools, combos, nums) = await _setup();
      final o = await _run(tools, [
        _a('preview_outfit', _pv),
        _a('try_on', {'outfit': nums(combos[1])}),
        _a('finish', {'answer': '입혀 봤어요.\n- 코디보드에도 올려 두었어요.\n- 1번이 더 맞아요.', 'outfit': nums(combos[0])}),
      ]);
      expect(_ids(o.outfit!.items), _ids(combos[0]));
    });

    test('2) outfit이 없으면 성공한 try_on이 입힌 조합 — 실패한 try_on은 보지 않는다', () async {
      final (tools, combos, nums) = await _setup();
      final o = await _run(tools, [
        _a('preview_outfit', _pv),
        _a('try_on', {'outfit': nums(combos[1])}),
        _a('finish', {'answer': '입혀 봤어요.\n- 코디보드에도 올려 두었어요.\n- 따뜻해요.'}),
      ]);
      expect(_ids(o.outfit!.items), _ids(combos[1]));
      expect(o.outfit!.tpo, '일상');
      final failed = AskStep(thought: '', action: 'try_on', args: const {}, items: combos[1], status: AskStepStatus.failed);
      final shown = AskStep(
          thought: '', action: 'preview_outfit', args: _pv, items: combos[0], status: AskStepStatus.done);
      expect(_ids(askOutfitOf([shown, failed])!.items), _ids(combos[0]));
    });

    test('3) outfit·try_on이 없으면 옷이 붙은 마지막 단계(여러 가지면 1번) — 잘못된 outfit도 같다', () async {
      final (tools, combos, _) = await _setup();
      final o = await _run(tools, [
        _a('preview_outfit', _pv),
        _a('finish', {'answer': '두 가지예요.\n- 1번은 따뜻해요.\n- 2번은 가벼워요.', 'outfit': ['#999']}),
      ]);
      expect(o.end, AskEnd.finished);
      expect(_ids(o.outfit!.items), _ids(combos[0]));
    });

    test('4) 이번 턴에 조합이 없으면 다음 턴의 [현재 코디]는 이전 것을 이어받고, 사진은 없다', () async {
      final (tools, combos, _) = await _setup();
      final current = AskOutfit(date: DateTime(2026, 11, 17), tpo: '데이트', items: combos[1]);
      final o = await _run(tools, [_a('finish', {'answer': '그 코디가 좋아요.\n- 따뜻해요.\n- 색이 이어져요.'})], current: current);
      expect(o.outfit, same(current));
      expect(askCombo(o), isEmpty);
      // finish의 outfit만 있고 이번 턴에 미리 보기가 없으면 날짜·상황은 이전 [현재 코디]에서
      final (tools2, combos2, nums2) = await _setup();
      final o2 = await _run(tools2, [
        _a('finish', {'answer': '그 코디예요.\n- 따뜻해요.\n- 이어져요.', 'outfit': nums2(combos2[0])}),
      ], current: current);
      expect(_ids(o2.outfit!.items), _ids(combos2[0]));
      expect((o2.outfit!.date, o2.outfit!.tpo), (DateTime(2026, 11, 17), '데이트'));
    });
  });

  testWidgets('대화 화면·대화 내역 — 조합이 정해진 턴(outfit, try_on)에만 사진, 조합이 없는 턴은 사진 없이 [현재 코디]만 이어받는다',
      (tester) async {
    tester.view.physicalSize = const Size(800, 4000); // 세 턴이 한 화면에 다 보이게(ListView는 보이는 것만 그린다)
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (seedTools, combos, nums) = await _setup();
    final prompts = <String>[];
    final replies = [
      // 1턴 — finish의 outfit으로 2번 조합
      _a('preview_outfit', _pv),
      _a('finish', {'answer': '2번 조합을 가장 권해요.\n- 따뜻해요.\n- 색이 이어져요.', 'outfit': nums(combos[1])}),
      // 2턴 — 조합이 없는 답
      _a('finish', {'answer': '고마워요.\n- 언제든 말씀해 주세요.\n- 다른 코디도 볼 수 있어요.'}),
      // 3턴 — try_on으로 1번 조합
      _a('try_on', {'outfit': nums(combos[0])}),
      _a('finish', {'answer': '입혀 봤어요.\n- 코디보드에도 올려 두었어요.\n- 따뜻해요.'}),
    ];
    var i = 0;
    final store = _Store();
    final tools = askTools(FakeAskData(snap: askSnapshot()));
    await tools.previewOutfit(_pv); // 같은 순서로 번호를 매긴다
    expect([for (final c in combos) for (final x in c) tools.book.numberOf(x)],
        [for (final c in combos) for (final x in c) seedTools.book.numberOf(x)]);
    final c = AskController(
      currentUid: () => 'u',
      toolsFor: (_) => tools,
      callModel: (p) async {
        prompts.add(p);
        return AskModelReply(replies[i++], 'text-primary');
      },
      logSink: (_) {},
      historyFor: (_) => store,
      fitting: _port(),
      now: () => DateTime(2026, 11, 16, 10),
    );
    List<String> thumbs() => tester.widgetList<AskItemThumb>(find.byType(AskItemThumb)).map((t) => t.id).toList();
    String currentLine(String prompt) =>
        RegExp(r'^\[현재 코디\] .*$', multiLine: true).firstMatch(prompt)!.group(0)!;
    await tester.pumpWidget(MaterialApp(home: AskScreen(controller: c, onOpenFittingRoom: (_) {})));
    await tester.pump();
    final fittingButton = find.text('피팅룸에서 입어 보기'); // 마지막 턴의 답 아래에만 있다
    // 1턴 — outfit으로 정해진 조합의 사진과 "피팅룸에서 입어 보기"
    c.start('코디 두 가지 보여 주고 하나 골라줘');
    await tester.pumpAndSettle();
    expect(thumbs(), _ids(combos[1]));
    expect(fittingButton, findsOneWidget);
    expect(_ids(c.currentOutfit!.items), _ids(combos[1]));
    // 2턴 — 조합이 없는 답에는 사진이 없다(화면의 사진은 1턴 것뿐), [현재 코디]는 이어받는다
    c.start('고마워');
    await tester.pumpAndSettle();
    for (final n in nums(combos[1])) {
      expect(currentLine(prompts[2]), contains(n)); // 2턴 프롬프트
    }
    expect(thumbs(), _ids(combos[1]));
    expect(askCombo(c.turns[1].outcome!), isEmpty);
    expect(fittingButton, findsNothing);
    expect(_ids(c.currentOutfit!.items), _ids(combos[1]));
    // 3턴 — 조합이 없는 턴 뒤에도 [현재 코디]는 1턴의 조합, try_on으로 정해진 조합은 사진이 있다
    c.start('1번으로 입혀 줘');
    await tester.pumpAndSettle();
    for (final n in nums(combos[1])) {
      expect(currentLine(prompts[3]), contains(n)); // 3턴 첫 단계 프롬프트
    }
    expect(thumbs(), [..._ids(combos[1]), ..._ids(combos[0])]);
    expect(fittingButton, findsOneWidget);
    expect(_ids(c.currentOutfit!.items), _ids(combos[0]));
    // 대화 내역 — 저장된 사진도 같고, 다시 열었을 때도 2턴에는 사진이 없다
    final record = store.records.single;
    expect([for (final t in record.turns) t.items.map((i) => i.id).toList()], [_ids(combos[1]), <String>[], _ids(combos[0])]);
    await tester.pumpWidget(MaterialApp(home: AskRecordScreen(record: record)));
    await tester.pump();
    expect(thumbs(), [..._ids(combos[1]), ..._ids(combos[0])]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
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
  Future<void> delete(String id) async {}
  @override
  Future<void> clear() async {}
}
