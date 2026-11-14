// 여러 세트의 사진 — 번호를 붙인 조합 줄이 둘 이상이면 줄마다 그 줄의 옷 사진(번호표로 찾고 없는 번호는
// 건너뛴다), 고른 조합과 같은 줄에 "추천", 맨 아래 사진 한 줄은 숨긴다. 대화 내역에서 다시 열어도 같다.
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

AskRecordItem _it(String id) => AskRecordItem(id: id, category: '상의', imageUrl: '');

Finder get _lineRows => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('ask-line-thumbs-'));
Finder get _recommended => find.byKey(const Key('ask-line-recommended'));

Future<void> _box(WidgetTester tester, AskAnswerBox box) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: box))));
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 5));
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

const _three = '세 가지를 골랐어요.\n'
    '- 1. 블랙 니트(#1) + 블랙 슬랙스(#2)\n'
    '- 2. 화이트 셔츠(#3) + 블랙 슬랙스(#2) + 없는 옷(#99)\n'
    '- 3. 그레이 니트(#4) + 차콜 데님(#5)\n'
    '- 선선한 날씨예요.';

void main() {
  test('조합 줄 읽기 — 0개·1개면 없음, 3개면 줄마다 번호', () {
    expect(askNumberedComboLines('결론이에요.\n- 이유 하나\n- 이유 둘'), isEmpty);
    expect(askNumberedComboLines('결론이에요.\n- 1. 블랙 니트(#1) + 슬랙스(#2)\n- 이유'), isEmpty);
    final three = askNumberedComboLines(_three);
    expect([for (final l in three) l.line], [1, 2, 3]);
    expect([for (final l in three) l.numbers], [
      [1, 2],
      [3, 2, 99],
      [4, 5],
    ]);
  });

  testWidgets('3개 — 줄마다 사진(번호표에 없는 #99는 건너뛴다), 고른 조합 줄에만 "추천", 맨 아래 사진 줄은 숨긴다', (tester) async {
    await _box(
        tester,
        AskAnswerBox(
          answer: _three,
          stopped: false,
          thumbs: const [SizedBox(key: Key('bottom-thumbs'))],
          lineItems: {1: _it('n1'), 2: _it('n2'), 3: _it('n3'), 4: _it('n4'), 5: _it('n5')},
          recommendedIds: const {'n3', 'n2'},
        ));
    expect(_lineRows, findsNWidgets(3));
    expect(find.descendant(of: find.byKey(const Key('ask-line-thumbs-2')), matching: find.byType(AskItemThumb)), findsNWidgets(2));
    expect(_recommended, findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('ask-line-thumbs-2')), matching: _recommended), findsOneWidget);
    expect(find.byKey(const Key('bottom-thumbs')), findsNothing);
    expect(find.text('- 2. 화이트 셔츠(#3) + 블랙 슬랙스(#2) + 없는 옷(#99)'), findsOneWidget);
    expect(find.text('- 선선한 날씨예요.'), findsOneWidget);
    await _done(tester);
  });

  testWidgets('조합 줄이 0개·1개면 지금과 같다 — 맨 아래 사진 줄', (tester) async {
    for (final answer in ['결론이에요.\n- 이유 하나\n- 이유 둘', '결론이에요.\n- 1. 블랙 니트(#1) + 블랙 슬랙스(#2)\n- 이유']) {
      await _box(
          tester,
          AskAnswerBox(
            answer: answer,
            stopped: false,
            thumbs: const [SizedBox(key: Key('bottom-thumbs'))],
            lineItems: {1: _it('n1'), 2: _it('n2')},
            recommendedIds: const {'n1', 'n2'},
          ));
      expect(_lineRows, findsNothing);
      expect(_recommended, findsNothing);
      expect(find.byKey(const Key('bottom-thumbs')), findsOneWidget);
      expect(find.text(answer), findsOneWidget);
    }
    await _done(tester);
  });

  test('대화 내역 저장 형식 — lineItems 왕복, 예전 기록(없음)은 빈 맵', () {
    final t = AskRecordTurn(
        request: '코디 두 가지', createdAt: DateTime(2026, 11, 16), end: 'finished', answer: _three, lineItems: {1: _it('n1'), 99: _it('x')});
    final back = AskRecordTurn.fromMap(t.toMap());
    expect(back.lineItems.keys, [1, 99]);
    expect(back.lineItems[1]!.id, 'n1');
    final old = AskRecordTurn.fromMap({'request': 'a', 'createdAt': 0, 'end': 'finished', 'answer': '답'});
    expect(old.lineItems, isEmpty);
  });

  testWidgets('대화 화면과 대화 내역 — 미리 보기 두 가지를 번호 붙여 적은 답', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tools = askTools(FakeAskData(snap: askSnapshot()));
    final combos = (await tools.previewOutfit({'date': '2026-11-16', 'tpo': '일상', 'count': 5})).combos;
    expect(combos.length, 2);
    String line(int k, List<WardrobeItem> c) => '- ${k + 1}. ${c.map((i) => '옷(#${tools.book.numberOf(i)})').join(' + ')}';
    final answer = '두 가지를 골랐어요.\n${line(0, combos[0])}\n${line(1, combos[1])}\n- 선선해요.';
    final replies = [
      _a('preview_outfit', {'date': '2026-11-16', 'tpo': '일상', 'count': 5}),
      _a('finish', {
        'answer': answer,
        'outfit': [for (final i in combos[1]) '#${tools.book.numberOf(i)}'],
      }),
    ];
    var i = 0;
    final store = _Store();
    final c = AskController(
      currentUid: () => 'u',
      toolsFor: (_) => tools,
      callModel: (_) async => AskModelReply(replies[i++], 'text-primary'),
      logSink: (_) {},
      historyFor: (_) => store,
      now: () => DateTime(2026, 11, 16, 10),
    );
    await tester.pumpWidget(MaterialApp(home: AskScreen(controller: c, onOpenFittingRoom: (_) {})));
    await tester.pump();
    c.start('코디 두 가지 보여 줘');
    await tester.pumpAndSettle();
    expect(_lineRows, findsNWidgets(2));
    expect(find.descendant(of: find.byKey(const Key('ask-line-thumbs-2')), matching: _recommended), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('ask-line-thumbs-1')), matching: _recommended), findsNothing);
    // 맨 아래 사진 줄은 없다 — 사진은 두 줄의 것뿐
    final allThumbs = tester.widgetList<AskItemThumb>(find.byType(AskItemThumb)).map((t) => t.id).toList();
    expect(allThumbs, [for (final c in combos) for (final x in c) x.id]);
    expect(find.text('피팅룸에서 입어 보기'), findsOneWidget); // outfit(2번 조합)으로 동작
    // 대화 내역에서 다시 열어도 같다
    final record = store.records.single;
    expect(record.turns.single.lineItems.length, {for (final c in combos) for (final x in c) x.id}.length);
    await tester.pumpWidget(MaterialApp(home: AskRecordScreen(record: AskRecord.fromMap(record.toMap()))));
    await tester.pump();
    expect(_lineRows, findsNWidgets(2));
    expect(find.descendant(of: find.byKey(const Key('ask-line-thumbs-2')), matching: _recommended), findsOneWidget);
    await _done(tester);
  });
}
