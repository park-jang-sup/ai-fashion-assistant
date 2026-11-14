// AI에게 부탁하기 v2 §2-B — 화면용 한 줄, 옷장 요약 도구, 프로필, 스타일 원칙·답 규칙.
import 'package:ai_fashion_assistant/models/user_profile.dart';
import 'package:ai_fashion_assistant/services/ask_activity_log.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

Map<String, dynamic> _a(String action, [Map<String, dynamic> args = const {}]) =>
    {'thought': '$action 할게요', 'action': action, 'args': args};

void main() {
  group('옷장 요약 도구', () {
    test('종류별 벌수·계절·격식 분포, 많은 색·스타일, 한겨울용 아우터, 빈 부분 — 전신은 세지 않는다', () async {
      final data = FakeAskData(snap: askSnapshot(), items: [...askWardrobe, askW('b1', '전신')]);
      final r = await askTools(data).getWardrobeProfile({});
      final o = r.observation;
      expect(o, startsWith('옷장 8벌 — 상의 2, 하의 2, 아우터 2, 신발 1, 액세서리 1'));
      expect(o, contains('상의: 계절 여름 0·간절기 1·가을·겨울 1·한겨울용 0 / 격식 캐주얼 1·세미포멀 1·포멀 0'));
      expect(o, contains('아우터: 계절 여름 0·간절기 1·가을·겨울 0·한겨울용 1'));
      expect(o, contains('많은 색: 블랙 5'));
      expect(o, contains('한겨울용 아우터 1벌: #3 아우터 카키 코듀로이·퀼팅안감·가을/겨울(캐주얼)'));
      // 오늘(11/16) 최고 14°C → 선선. 신발 1벌·하의 2벌 등은 3벌 미만.
      expect(o, contains('오늘 기온대(선선)에 맞는 옷이 3벌 미만: '));
      expect(o, contains('신발 1벌'));
      expect(o, contains('격식별로 0벌: 상의 포멀'));
      expect(o.length, lessThanOrEqualTo(1500));
      expect(r.display, '옷장 8벌을 요약했어요');
    });

    test('예보가 없으면 기온대 빈 부분은 계산하지 않는다고 적는다', () async {
      final r = await askTools(FakeAskData()).getWardrobeProfile({});
      expect(r.observation, contains('오늘 예보가 없어 기온대 기준 빈 부분은 계산하지 않았어요'));
    });
  });

  group('프로필 한 줄과 프롬프트', () {
    test('있는 항목만, 지시서의 네 항목(키·체형·퍼스널 컬러·선호 스타일)', () async {
      final data = FakeAskData()
        ..userProfile = const UserProfile(heightCm: 175, weightKg: 70, bodyType: '보통 체형', preferredStyles: ['캐주얼', '스트릿']);
      final line = await askTools(data).profileLine();
      expect(line, '키 175cm · 체형 보통 체형 · 선호 스타일 캐주얼·스트릿');
      expect(await askTools(FakeAskData()).profileLine(), isNull);
      final p = buildAskPrompt(request: 'x', steps: const [], today: DateTime(2026, 11, 16), profile: line);
      expect(p, contains('[사용자 프로필] 키 175cm'));
      expect(p, isNot(contains('70')));
      expect(buildAskPrompt(request: 'x', steps: const [], today: DateTime(2026, 11, 16)), isNot(contains('[사용자 프로필]')));
    });

    test('스타일 원칙, 구매 제안·답 형식·내부 사정 규칙이 들어간다', () {
      final p = buildAskPrompt(request: 'x', steps: const [], today: DateTime(2026, 11, 16));
      expect(p, contains(askStylePrinciples));
      expect(p, contains('없는 옷은 "구매 제안:" 줄에만 쓴다'));
      expect(p, contains('브랜드, 가격, 판매처, 링크는 쓰지 않는다'));
      expect(p, contains('첫 줄은 결론 한 문장'));
      expect(p, contains('내부 사정을 쓰지 않는다'));
      expect(p, isNot(contains('두세 문장')));
      expect(p, contains('- get_wardrobe_profile {} — 옷장 전체 요약'));
    });

    test('엔진이 프로필을 프롬프트에 넘긴다', () async {
      final data = FakeAskData()..userProfile = const UserProfile(personalColor: '겨울쿨');
      final prompts = <String>[];
      final engine = AskEngine(
        tools: askTools(data),
        callModel: (p) async {
          prompts.add(p);
          return AskModelReply(_a('finish', {'answer': '끝'}), 'text-primary');
        },
        buildPrompt: buildAskPrompt,
        confirmPlan: (_, __) async => false,
        askUser: (_) async => null,
      );
      await engine.run('x');
      expect(prompts.single, contains('[사용자 프로필] 퍼스널 컬러 겨울쿨'));
    });
  });

  group('사용자용 문장과 모델용 문장', () {
    test('형식 오류 단계는 숨기고, 기록·활동 내역에는 화면용 한 줄만', () async {
      final logs = <String>[];
      final engine = AskEngine(
        tools: askTools(FakeAskData(snap: askSnapshot())),
        callModel: _replies([
          {'thought': '뭔가', 'action': 'delete_item', 'args': {}},
          _a('get_weather', {'from': '2026-11-17', 'to': '2026-11-17'}),
          _a('finish', {'answer': '내일은 비가 와요\n- 우산을 챙기세요'}),
        ]),
        buildPrompt: buildAskPrompt,
        confirmPlan: (_, __) async => false,
        askUser: (_) async => null,
      );
      final o = await engine.run('내일 비 와?');
      expect(o.steps.first.hidden, isTrue);
      expect(o.steps[1].display, '11/17(화) 최고 9° 최저 2° · 비 70%');
      final record = AskRecord.fromOutcome('내일 비 와?', o, const [], DateTime(2026, 11, 16));
      expect([for (final s in record.steps) s.summary], ['11/17(화) 최고 9° 최저 2° · 비 70%']);
      final log = AskActivityLog(write: (e) => logs.add(e.message), relatedId: 'r')..ended(o);
      expect(log, isNotNull);
      expect(logs, ['예보 확인 — 11/17(화) 최고 9° 최저 2° · 비 70%', 'AI 답: 내일은 비가 와요']);
    });

    test('도구마다 화면용 한 줄이 있다', () async {
      final t = askTools(FakeAskData(snap: askSnapshot(), entries: [askEntry(DateTime(2026, 11, 17), '데이트')]));
      expect((await t.getCalendar({'from': '2026-11-16', 'to': '2026-11-22'})).display, '일정: 11/17(화) 데이트(코디 준비 전)');
      expect((await t.getCalendar({'from': '2026-11-23', 'to': '2026-11-23'})).display, '11/23(월) 일정 없음');
      expect((await t.getWeather({'from': '2026-11-16', 'to': '2026-11-22'})).display, '11/16(월)~11/22(일) 예보를 확인했어요');
      expect((await t.getWeather({'from': '2026-11-25', 'to': '2026-11-25'})).display, '예보는 7일까지라 그날 날씨는 아직 몰라요');
      expect((await t.searchWardrobe({'category': '아우터', 'keyword': '퀼팅'})).display, "아우터 '퀼팅' 1벌을 찾았어요");
      final pv = await t.previewOutfit({'date': '2026-11-20', 'tpo': '모임'});
      expect(pv.display, startsWith('11/20(금) [모임] 코디: '));
      expect(pv.display, isNot(contains('저장 안 함')));
    });
  });
}

AskModelCall _replies(List<Map<String, dynamic>> replies) {
  var i = 0;
  return (_) async => AskModelReply(replies[i++], 'text-primary');
}
