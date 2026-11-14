// 같은 턴에 preview_outfit을 다시 부르면 앞서 보여 준 조합의 상의·아우터를 빼고 고른다(docs/task_agent_ask_v2.md
// 실행 기록 "v2.1" B-1). keep한 옷은 남고, 조합을 못 만들면 빼지 않고 다시 고르며, 한 번만 부르면 결과가 그대로이고,
// 턴이 바뀌면 이어지지 않는다.
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

const _date = '2026-11-16';
Map<String, dynamic> _pv(String tpo, [Map<String, dynamic> more = const {}]) => {'date': _date, 'tpo': tpo, ...more};

Set<String> _topsOuters(List<WardrobeItem> c) => {
      for (final i in c)
        if (i.category == '상의' || i.category == '아우터') i.id,
    };

Future<(AskOutcome, AskTools)> _run(List<Map<String, dynamic>> replies, {AskTools? tools}) async {
  final t = tools ?? askTools(FakeAskData(snap: askSnapshot()));
  var i = 0;
  final o = await AskEngine(
    tools: t,
    callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
    buildPrompt: buildAskPrompt,
    confirmPlan: (_, __) async => false,
    askUser: (_) async => null,
  ).run('데이트와 모임용으로 코디 추천해줘');
  return (o, t);
}

List<AskStep> _previews(AskOutcome o) => [for (final s in o.steps) if (s.action == 'preview_outfit') s];

void main() {
  _turnCapTests();

  test('한 턴에 두 번 — 두 번째는 첫 번째의 상의·아우터를 빼고 골라 겹치지 않는다', () async {
    final (o, _) = await _run([
      _a('preview_outfit', _pv('데이트')),
      _a('preview_outfit', _pv('모임')),
      _a('finish', {'answer': '두 가지예요.\n- 1. 데이트\n- 2. 모임'}),
    ]);
    final [first, second] = _previews(o);
    expect(first.observation, isNot(contains(askPreviewAvoidedNote)));
    expect(second.observation, contains(askPreviewAvoidedNote));
    expect(_topsOuters(second.items).intersection(_topsOuters(first.items)), isEmpty);
    expect(second.combos, hasLength(1));
  });

  test('keep한 옷은 빼지 않는다', () async {
    final probe = askTools(FakeAskData(snap: askSnapshot()));
    final firstCombo = (await probe.previewOutfit(_pv('데이트'))).items;
    final keptTop = firstCombo.firstWhere((i) => i.category == '상의');
    final (o, _) = await _run([
      _a('preview_outfit', _pv('데이트')),
      _a('preview_outfit', _pv('모임', {'keep': ['#${probe.book.numberOf(keptTop)}']})),
      _a('finish', {'answer': '두 가지예요.\n- 1. 데이트\n- 2. 모임'}),
    ], tools: probe);
    final [first, second] = _previews(o);
    expect(second.items.map((i) => i.id), contains(keptTop.id));
    final outer = first.items.where((i) => i.category == '아우터').map((i) => i.id).toSet();
    expect(second.items.where((i) => i.category == '아우터').map((i) => i.id).toSet().intersection(outer), isEmpty);
    expect(second.observation, contains(askPreviewAvoidedNote));
  });

  test('빼고 나서 조합을 못 만들면 빼지 않고 다시 고르고, 겹칠 수 있다고 적는다', () async {
    final (o, _) = await _run([
      _a('preview_outfit', _pv('데이트', {'count': 5})), // 상의 2벌을 모두 쓴다
      _a('preview_outfit', _pv('모임')),
      _a('finish', {'answer': '세 가지예요.\n- 1. 데이트\n- 2. 데이트\n- 3. 모임'}),
    ]);
    final [first, second] = _previews(o);
    expect(first.combos, hasLength(2));
    expect(second.status, AskStepStatus.done);
    expect(second.items, isNotEmpty);
    expect(second.observation, contains(askPreviewOverlapNote));
    expect(second.observation, isNot(contains(askPreviewAvoidedNote)));
    // 빼지 않고 고른 결과는 처음 부른 것과 같다
    final alone = await askTools(FakeAskData(snap: askSnapshot())).previewOutfit(_pv('모임'));
    expect(second.observation, '${alone.observation}\n$askPreviewOverlapNote');
  });

  test('한 번만 부르면 결과가 그대로 — 도구를 바로 부른 결과와 한 글자도 같다', () async {
    for (final args in [
      _pv('데이트'),
      _pv('모임', {'count': 3}),
      _pv('일상', {'adjust': '더 따뜻하게', 'style': '데님'}),
      _pv('면접', {'unworn_first': true}),
    ]) {
      final alone = await askTools(FakeAskData(snap: askSnapshot())).previewOutfit(args);
      final (o, _) = await _run([_a('preview_outfit', args), _a('finish', {'answer': '끝.\n- 하나\n- 둘'})]);
      final s = _previews(o).single;
      expect(s.observation, alone.observation, reason: '$args');
      expect(s.display, alone.display);
      expect([for (final c in s.combos) c.map((i) => i.id).toList()],
          [for (final c in alone.combos) c.map((i) => i.id).toList()]);
    }
  });

  test('턴이 바뀌면 이어지지 않는다 — 다음 턴의 첫 미리 보기는 빼지 않는다', () async {
    final replies = [
      _a('preview_outfit', _pv('데이트')),
      _a('finish', {'answer': '데이트 코디예요.\n- 하나\n- 둘'}),
      _a('preview_outfit', _pv('데이트')),
      _a('finish', {'answer': '같은 코디예요.\n- 하나\n- 둘'}),
    ];
    var i = 0;
    final tools = askTools(FakeAskData(snap: askSnapshot()));
    final c = AskController(
      currentUid: () => 'u',
      toolsFor: (_) => tools,
      callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
      logSink: (_) {},
      historyFor: (_) => _Store(),
      now: () => DateTime(2026, 11, 16, 10),
    );
    c.start('데이트 코디 보여줘');
    await pumpEventQueue();
    final first = _previews(c.turns.first.outcome!).single;
    c.start('한 번 더 보여줘');
    await pumpEventQueue();
    final second = _previews(c.turns.last.outcome!).single;
    expect(second.observation, first.observation);
    expect(second.observation, isNot(contains(askPreviewAvoidedNote)));
    expect(second.observation, isNot(contains(askPreviewOverlapNote)));
  });
}

// 턴당 조합 수 상한(T8 run2 전 결정) — 상의·아우터가 넉넉한 옷장(한 번에 5가지를 만들 수 있다).
final _big = [
  for (var i = 0; i < 8; i++) askW('bt$i', '상의', color: ['블랙', '화이트', '그레이', '네이비'][i % 4], tags: ['맨투맨', '코튼'], day: 1 + i),
  for (var i = 0; i < 8; i++) askW('bo$i', '아우터', color: ['블랙', '카키', '차콜', '네이비'][i % 4], tags: ['블레이저', '봄가을'], day: 10 + i),
  askW('bp1', '하의', tags: ['슬랙스', '사계절']),
  askW('bp2', '하의', color: '차콜', tags: ['데님', '사계절']),
  askW('bs1', '신발', tags: ['스니커즈', '가죽']),
];

AskTools _bigTools() => askTools(FakeAskData(snap: askSnapshot(), items: _big));

void _turnCapTests() {
  group('턴당 조합 수 상한(5개)', () {
    test('합이 5를 넘으면 남은 수로 줄여 고르고 한 줄을 붙인다', () async {
      final (o, _) = await _run([
        _a('preview_outfit', _pv('데이트', {'count': 4})),
        _a('preview_outfit', _pv('모임', {'count': 3})),
        _a('finish', {'answer': '다섯 세트예요.\n- 하나\n- 둘'}),
      ], tools: _bigTools());
      final [first, second] = _previews(o);
      expect(first.combos, hasLength(4));
      expect(second.combos, hasLength(1));
      expect(second.observation, isNot(contains('요청 3개'))); // count를 1로 줄여 고른 결과(한 가지 형식)
      expect(second.observation, endsWith('\n${askTurnComboCutNote(1)}'));
      expect(askTurnComboCutNote(1), '한 답에는 5세트까지라 1가지만 골랐어요.');
      expect(second.display, isNot(contains('5세트까지')));
    });

    test('남은 수가 0이면 실행하지 않고 돌려준다 — 화면에는 막힌 호출과 같은 한 줄', () async {
      final (o, _) = await _run([
        _a('preview_outfit', _pv('데이트', {'count': 5})),
        _a('preview_outfit', _pv('모임', {'count': 2})),
        _a('finish', {'answer': '다섯 세트예요.\n- 하나\n- 둘'}),
      ], tools: _bigTools());
      final [first, second] = _previews(o);
      expect(first.combos, hasLength(5));
      expect(second.observation, '이번 답에는 이미 5세트를 골랐어요. 얻은 결과로 답하세요.');
      expect(second.display, askDisplayBlocked);
      expect(second.status, AskStepStatus.failed);
      expect(second.combos, isEmpty);
      expect(o.end, AskEnd.finished);
    });

    test('합이 5 이하면 결과가 그대로 — 상한이 없을 때 도구가 낸 결과와 한 글자도 같다', () async {
      final a1 = _pv('데이트', {'count': 2}), a2 = _pv('모임', {'count': 3});
      final (o, _) = await _run([
        _a('preview_outfit', a1),
        _a('preview_outfit', a2),
        _a('finish', {'answer': '다섯 세트예요.\n- 하나\n- 둘'}),
      ], tools: _bigTools());
      final fresh = _bigTools();
      final r1 = await fresh.previewOutfit(a1);
      final r2 = await fresh.previewOutfit(a2, avoid: {for (final c in r1.combos) ..._topsOuters(c)});
      final [first, second] = _previews(o);
      expect(first.observation, r1.observation);
      expect(second.observation, r2.observation);
      expect(second.combos.length, 3);
      expect(second.observation, isNot(contains('5세트까지')));
    });

    test('턴이 바뀌면 다시 5개', () async {
      final replies = [
        _a('preview_outfit', _pv('데이트', {'count': 5})),
        _a('finish', {'answer': '다섯 세트예요.\n- 하나\n- 둘'}),
        _a('preview_outfit', _pv('모임', {'count': 5})),
        _a('finish', {'answer': '또 다섯 세트예요.\n- 하나\n- 둘'}),
      ];
      var i = 0;
      final tools = _bigTools();
      final c = AskController(
        currentUid: () => 'u',
        toolsFor: (_) => tools,
        callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
        logSink: (_) {},
        historyFor: (_) => _Store(),
        now: () => DateTime(2026, 11, 16, 10),
      );
      c.start('데이트 코디 5세트');
      await pumpEventQueue();
      c.start('모임 코디도 5세트');
      await pumpEventQueue();
      final second = _previews(c.turns.last.outcome!).single;
      expect(second.combos, hasLength(5));
      expect(second.observation, isNot(contains('5세트까지')));
      expect(second.observation, isNot(contains('이미 5세트')));
    });
  });
}

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
