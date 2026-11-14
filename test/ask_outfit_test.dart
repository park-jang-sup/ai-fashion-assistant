// 고른 조합을 하나로(docs/task_agent_ask_v2.md 실행 기록 "v2.1" A) — finish의 outfit, 이번 턴의 조합을 정하는
// 순서(finish의 outfit → 성공한 try_on → 옷이 붙은 마지막 단계 → 이전 [현재 코디]), 대화 내역.
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

AskFittingPort _port() => AskFittingPort(
      hasUserPhoto: () => true,
      busy: () => false,
      run: (_) async => AskFittingOutcome(shot: AskFittingShot(bytes: Uint8List(3), cacheKey: 'k1')),
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

    test('4) 이번 턴에 조합이 없으면 이전 [현재 코디] — 사진도 그것', () async {
      final (tools, combos, _) = await _setup();
      final current = AskOutfit(date: DateTime(2026, 11, 17), tpo: '데이트', items: combos[1]);
      final o = await _run(tools, [_a('finish', {'answer': '그 코디가 좋아요.\n- 따뜻해요.\n- 색이 이어져요.'})], current: current);
      expect(o.outfit, same(current));
      expect(_ids(askCombo(o)), _ids(combos[1]));
      // finish의 outfit만 있고 이번 턴에 미리 보기가 없으면 날짜·상황은 이전 [현재 코디]에서
      final (tools2, combos2, nums2) = await _setup();
      final o2 = await _run(tools2, [
        _a('finish', {'answer': '그 코디예요.\n- 따뜻해요.\n- 이어져요.', 'outfit': nums2(combos2[0])}),
      ], current: current);
      expect(_ids(o2.outfit!.items), _ids(combos2[0]));
      expect((o2.outfit!.date, o2.outfit!.tpo), (DateTime(2026, 11, 17), '데이트'));
    });
  });

  testWidgets('대화 화면·대화 내역 — 답 아래 사진, 다시 열었을 때의 사진, 다음 턴의 [현재 코디]가 모두 finish의 outfit', (tester) async {
    final (seedTools, combos, nums) = await _setup();
    final prompts = <String>[];
    final replies = [
      _a('preview_outfit', _pv),
      _a('finish', {'answer': '2번 조합을 가장 권해요.\n- 따뜻해요.\n- 색이 이어져요.', 'outfit': nums(combos[1])}),
      _a('finish', {'answer': '그 코디로 가요.\n- 따뜻해요.\n- 이어져요.'}),
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
      now: () => DateTime(2026, 11, 16, 10),
    );
    await tester.pumpWidget(MaterialApp(home: AskScreen(controller: c)));
    await tester.pump();
    c.start('코디 두 가지 보여 주고 하나 골라줘');
    await tester.pumpAndSettle();
    final thumbs = tester.widgetList<AskItemThumb>(find.byType(AskItemThumb)).map((t) => t.id).toList();
    expect(thumbs, _ids(combos[1]));
    expect(_ids(c.currentOutfit!.items), _ids(combos[1]));
    expect([for (final it in store.records.single.turns.single.items) it.id], _ids(combos[1]));
    // 다음 턴의 [현재 코디]
    c.start('그걸로 할게');
    await tester.pumpAndSettle();
    final cur = RegExp(r'^\[현재 코디\] .*$', multiLine: true).firstMatch(prompts.last)!.group(0)!;
    for (final n in nums(combos[1])) {
      expect(cur, contains(n));
    }
    // 대화 내역에서 다시 열었을 때
    final record = store.records.single;
    await tester.pumpWidget(MaterialApp(home: AskRecordScreen(record: record)));
    await tester.pump();
    final reopened = tester.widgetList<AskItemThumb>(find.byType(AskItemThumb)).map((t) => t.id).toList();
    expect(reopened, [..._ids(combos[1]), ..._ids(combos[1])]); // 두 턴 모두 같은 조합(2턴은 이전 [현재 코디])
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
