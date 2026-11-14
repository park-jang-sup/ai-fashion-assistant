// "구매 제안"의 화면 이름 — 답의 "구매 제안:" 줄을 화면에서만 "옷장에 더하면 좋은 옷" 묶음으로 그린다.
// 저장되는 대화 내역과 다음 턴에 모델에게 주는 글은 "구매 제안:" 그대로다.
import 'package:ai_fashion_assistant/screens/ask_screen.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

const _one = '긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.\n구매 제안: 울 니트 — 블랙 와이드팬츠와 어울려요';
const _three = '긴팔 상의와 포멀 옷이 부족해요.\n- 포멀 격식은 0벌이에요.\n'
    '구매 제안: 차콜 니트 — 블랙 하의와 어울려요\n'
    '- 구매 제안: 블랙 더비 슈즈 — 블랙 슬랙스와 어울려요\n'
    '구매 제안: 차콜 슬랙스 — 블랙 상의와 어울려요';

Finder get _extras => find.byKey(const Key('ask-extras'));

Future<void> _box(WidgetTester tester, String answer) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AskAnswerBox(answer: answer, stopped: false)))));

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

void main() {
  test('줄 나누기 — 0개·1개·3개, 앞에 "- "가 붙은 줄도', () {
    final none = askSplitExtras('내일은 블랙 카라티를 입으세요.\n- 선선해요.');
    expect(none.extras, isEmpty);
    expect(none.body, '내일은 블랙 카라티를 입으세요.\n- 선선해요.');
    final one = askSplitExtras(_one);
    expect(one.body, '긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.');
    expect(one.extras, ['울 니트 — 블랙 와이드팬츠와 어울려요']);
    final three = askSplitExtras(_three);
    expect(three.body, '긴팔 상의와 포멀 옷이 부족해요.\n- 포멀 격식은 0벌이에요.');
    expect(three.extras, ['차콜 니트 — 블랙 하의와 어울려요', '블랙 더비 슈즈 — 블랙 슬랙스와 어울려요', '차콜 슬랙스 — 블랙 상의와 어울려요']);
  });

  testWidgets('구매 제안 줄이 없으면 묶음을 그리지 않는다', (tester) async {
    await _box(tester, '내일은 블랙 카라티를 입으세요.\n- 선선해요.');
    expect(_extras, findsNothing);
    expect(find.text(askExtrasTitle), findsNothing);
    expect(find.text('내일은 블랙 카라티를 입으세요.\n- 선선해요.'), findsOneWidget);
  });

  testWidgets('1개 — 본문에서 떼어 답 아래 묶음으로, "구매 제안" 글자는 보이지 않는다', (tester) async {
    await _box(tester, _one);
    expect(_extras, findsOneWidget);
    expect(find.text(askExtrasTitle), findsOneWidget);
    expect(find.text(askExtrasNote), findsOneWidget);
    expect(find.text('울 니트 — 블랙 와이드팬츠와 어울려요'), findsOneWidget);
    expect(find.text('긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.'), findsOneWidget);
    expect(find.textContaining('구매 제안'), findsNothing);
    // 묶음은 본문 아래
    expect(tester.getTopLeft(_extras).dy,
        greaterThan(tester.getBottomLeft(find.text('긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.')).dy));
  });

  testWidgets('3개 — 내용만 한 줄씩', (tester) async {
    await _box(tester, _three);
    for (final item in askSplitExtras(_three).extras) {
      expect(find.descendant(of: _extras, matching: find.text(item)), findsOneWidget);
    }
    expect(find.descendant(of: _extras, matching: find.byIcon(Icons.add_circle_outline)), findsNWidgets(3));
    expect(find.textContaining('구매 제안'), findsNothing);
  });

  testWidgets('대화 내역 — buy가 없는 예전 기록은 그대로, "구매 제안:" 줄이 있는 기록은 묶음으로', (tester) async {
    final old = AskRecord.single(
      request: '내일 뭐 입지?',
      createdAt: DateTime(2026, 11, 1, 9),
      end: 'finished',
      answer: '내일은 블랙 카라티를 입으세요.',
    );
    await tester.pumpWidget(MaterialApp(home: AskRecordScreen(record: old)));
    expect(find.text('내일은 블랙 카라티를 입으세요.'), findsOneWidget);
    expect(_extras, findsNothing);
    final withBuy = AskRecord.single(
        request: '내 옷장에 부족한 옷 알려줘', createdAt: DateTime(2026, 11, 2, 9), end: 'finished', answer: _one);
    await tester.pumpWidget(MaterialApp(home: AskRecordScreen(record: withBuy)));
    expect(find.text('울 니트 — 블랙 와이드팬츠와 어울려요'), findsOneWidget);
    expect(find.textContaining('구매 제안'), findsNothing);
  });

  testWidgets('대화 화면 — 화면은 묶음, 저장되는 대화 내역의 글은 "구매 제안:" 그대로', (tester) async {
    final store = _Store();
    final c = AskController(
      currentUid: () => 'u',
      toolsFor: (_) => askTools(FakeAskData(snap: askSnapshot())),
      callModel: (_) async => AskModelReply({
        'thought': '끝낼게요',
        'action': 'finish',
        'args': {
          'answer': '긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.',
          'buy': ['울 니트 — 블랙 와이드팬츠와 어울려요'],
        },
      }, 'text-primary'),
      logSink: (_) {},
      historyFor: (_) => store,
      now: () => DateTime(2026, 11, 16, 10),
    );
    await tester.pumpWidget(MaterialApp(home: AskScreen(controller: c)));
    await tester.pump();
    c.start('내 옷장에 부족한 옷 알려줘');
    await tester.pumpAndSettle();
    expect(find.text('울 니트 — 블랙 와이드팬츠와 어울려요'), findsOneWidget);
    expect(find.text(askExtrasTitle), findsOneWidget);
    expect(find.textContaining('구매 제안'), findsNothing);
    expect(c.outcome!.answer, endsWith('\n구매 제안: 울 니트 — 블랙 와이드팬츠와 어울려요'));
    expect(store.records.single.turns.single.answer, contains('구매 제안: 울 니트'));
  });
}
