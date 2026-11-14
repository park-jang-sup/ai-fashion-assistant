// finish의 buy와 엔진의 finish 검사(docs/task_agent_ask_v2.md 실행 기록 "run3 전 결정").
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_finish.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _fin(String answer, [Object? buy]) => {
      'thought': '끝낼게요',
      'action': 'finish',
      'args': {'answer': answer, if (buy != null) 'buy': buy},
    };
Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

Future<(AskOutcome, List<String>)> _run(List<Map<String, dynamic>> replies) async {
  final prompts = <String>[];
  var i = 0;
  final o = await AskEngine(
    tools: askTools(FakeAskData(snap: askSnapshot())),
    callModel: (p) async {
      prompts.add(p);
      return AskModelReply(replies[i++], 'text-primary');
    },
    buildPrompt: buildAskPrompt,
    confirmPlan: (_, __) async => false,
    askUser: (_) async => null,
  ).run('내 옷장에 부족한 옷 알려줘');
  return (o, prompts);
}

void main() {
  group('buy 정리', () {
    test('목록·문자열·잘못된 형 — 빈 항목 버림, 줄바꿈은 공백, 최대 3개', () {
      expect(askNormalizeBuy(['긴팔 니트 — 블랙 슬랙스와', ' ', '코트\n— 블레이저 대신']),
          ['긴팔 니트 — 블랙 슬랙스와', '코트 — 블레이저 대신']);
      expect(askNormalizeBuy('긴팔 니트 — 블랙 슬랙스와'), ['긴팔 니트 — 블랙 슬랙스와']);
      expect(askNormalizeBuy(3), isEmpty);
      expect(askNormalizeBuy({'a': 1}), isEmpty);
      expect(askNormalizeBuy([1, '셔츠 — 차콜 팬츠와']), ['셔츠 — 차콜 팬츠와']);
      final four = askSplitFinish('결론이에요.', ['a — 1', 'b — 2', 'c — 3', 'd — 4']);
      expect(four.buy.length, 3);
    });

    test('answer의 "구매 제안:" 줄은 떼어 buy 뒤에 — 최종 답은 answer + "구매 제안:" 줄', () {
      final p = askSplitFinish('긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.\n구매 제안: 울 니트 — 블랙 슬랙스와\n- 구매 제안: 셔츠 — 차콜 팬츠와',
          ['코트 — 블레이저 대신']);
      expect(p.answerLines, ['긴팔 상의가 부족해요.', '- 상의 28벌 중 27벌이 여름용이에요.']);
      expect(p.buy, ['코트 — 블레이저 대신', '울 니트 — 블랙 슬랙스와', '셔츠 — 차콜 팬츠와']);
      expect(p.compose(),
          '긴팔 상의가 부족해요.\n- 상의 28벌 중 27벌이 여름용이에요.\n구매 제안: 코트 — 블레이저 대신\n구매 제안: 울 니트 — 블랙 슬랙스와\n구매 제안: 셔츠 — 차콜 팬츠와');
    });

    test('검사 글자 — 목록과 "있으면 … 더 잘/더 좋"(20자 안)', () {
      expect(askFinishLineHits('- 니트나 맨투맨, 긴팔 셔츠가 가장 급해요.'), isTrue);
      expect(askFinishLineHits('- 색이나 질감이 있는 옷 한 벌을 더하면 변화를 주기 좋아요.'), isTrue);
      expect(askFinishLineHits('- 긴팔 니트나 맨투맨이 있으면 선선한 날씨에 더 잘 맞을 거예요.'), isTrue);
      expect(askFinishLineHits('- 블랙 코트를 구매하면 좋아요.'), isTrue);
      // 잡지 않는 말: 앱 소개의 "구매 제안", 가진 옷에도 쓰는 "더하면", 부족하다는 사실.
      expect(askFinishLineHits('- 저는 코디 추천, 의류 구매 제안을 돕는 비서예요.'), isFalse);
      expect(askFinishLineHits('- 블레이저를 더하면 단정해요.'), isFalse);
      expect(askFinishLineHits('- 선선한 날 입을 긴팔 상의가 부족해요.'), isFalse);
      expect(askFinishLineHits('있으면 아주아주아주아주아주아주아주아주아주아주 길게 말한 뒤 더 잘'), isFalse);
    });
  });

  group('엔진의 finish 검사', () {
    test('buy가 있으면 답 끝에 "구매 제안:" 줄, 검사에 걸리지 않으면 바로 받는다', () async {
      final (o, _) = await _run([
        _fin('긴팔 상의가 부족해요.\n- 상의 대부분이 반팔이에요.\n- 선선한 날 입을 옷이 1벌뿐이에요.', '울 니트 — 블랙 와이드팬츠와'),
      ]);
      expect(o.end, AskEnd.finished);
      expect(o.answer, endsWith('\n구매 제안: 울 니트 — 블랙 와이드팬츠와'));
      expect(o.finishReturned, isFalse);
      expect(o.modelCalls, 1);
    });

    test('걸리면 한 번 돌려보내고, 다시 낸 finish를 받는다 — 돌려보낸 것도 호출 한 번', () async {
      final (o, prompts) = await _run([
        _fin('긴팔 상의가 부족해요.\n- 니트나 맨투맨이 가장 급해요.\n- 선선한 날 입을 옷이 1벌뿐이에요.'),
        _fin('긴팔 상의가 부족해요.\n- 선선한 날 입을 옷이 1벌뿐이에요.\n- 상의 대부분이 반팔이에요.', ['울 니트 — 블랙 슬랙스와']),
      ]);
      expect(o.end, AskEnd.finished);
      expect(o.modelCalls, 2);
      expect(o.finishReturned, isTrue);
      expect(o.finishTrimmed, 0);
      expect(o.answer, isNot(contains('급해요')));
      expect(o.answer, contains('구매 제안: 울 니트 — 블랙 슬랙스와'));
      expect(o.steps.first.display, askDisplayRevising);
      expect(prompts[1], contains('answer의 이 줄이 새 옷을 권하는 말이에요: "- 니트나 맨투맨이 가장 급해요."'));
    });

    test('이미 돌려보냈으면 걸린 줄을 빼고 받는다(첫 줄은 빼지 않는다)', () async {
      final (o, _) = await _run([
        _fin('긴팔 상의가 부족해요.\n- 니트가 가장 급해요.'),
        _fin('니트가 있으면 더 좋아요.\n- 코트도 장만하세요.\n- 상의 대부분이 반팔이에요.'),
      ]);
      expect(o.finishReturned, isTrue);
      expect(o.finishTrimmed, 1);
      expect(o.answer, '니트가 있으면 더 좋아요.\n- 상의 대부분이 반팔이에요.');
    });

    test('여섯 번째 호출에서 걸리면 돌려보내지 않고 줄을 빼고 받는다', () async {
      final (o, _) = await _run([
        for (var i = 0; i < 5; i++) _a('get_weather', {'from': '2026-11-${16 + i}', 'to': '2026-11-${16 + i}'}),
        _fin('긴팔 상의가 부족해요.\n- 니트를 장만하면 좋아요.\n- 상의 대부분이 반팔이에요.'),
      ]);
      expect(o.end, AskEnd.finished);
      expect(o.modelCalls, 6);
      expect(o.finishReturned, isFalse);
      expect(o.finishTrimmed, 1);
      expect(o.answer, '긴팔 상의가 부족해요.\n- 상의 대부분이 반팔이에요.');
    });
  });

  test('여러 턴 — 이전 턴 답의 "구매 제안:" 줄이 다음 턴 [이전 대화]에 그대로 들어가고, 다음 턴도 정리된다', () async {
    final prompts = <String>[];
    final replies = [
      _fin('긴팔 상의가 부족해요.\n- 상의 대부분이 반팔이에요.\n- 선선한 날 입을 옷이 1벌뿐이에요.', ['울 니트 — 블랙 슬랙스와']),
      _fin('어울리는 아우터는 워크자켓이에요.\n- 블랙 슬랙스와 이어져요.\n- 카키 한 가지만 더해져요.\n구매 제안: 코트 — 블레이저 대신'),
    ];
    var i = 0;
    final store = _Store();
    final c = AskController(
      currentUid: () => 'u',
      toolsFor: (_) => askTools(FakeAskData(snap: askSnapshot())),
      callModel: (p) async {
        prompts.add(p);
        return AskModelReply(replies[i++], 'text-primary');
      },
      logSink: (_) {},
      historyFor: (_) => store,
      now: () => DateTime(2026, 11, 16, 10),
    );
    c.start('내 옷장에 부족한 옷 알려줘');
    await pumpEventQueue();
    expect(c.outcome!.answer, endsWith('구매 제안: 울 니트 — 블랙 슬랙스와'));
    c.start('그 니트에 어울리는 아우터는?');
    await pumpEventQueue();
    expect(prompts[1], contains('답: 긴팔 상의가 부족해요.'));
    expect(prompts[1], contains('구매 제안: 울 니트 — 블랙 슬랙스와'));
    expect(c.outcome!.answer, endsWith('구매 제안: 코트 — 블레이저 대신'));
    expect(c.outcome!.answer.split('\n').where((l) => l.startsWith('구매 제안:')).length, 1);
    final saved = store.records.single;
    expect(saved.turns.first.answer, contains('구매 제안: 울 니트'));
  });
}

class _Store implements AskHistoryStore {
  final records = <AskRecord>[];
  @override
  Future<List<AskRecord>> recent() async => records;
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
