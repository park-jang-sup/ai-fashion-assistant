// AI에게 부탁하기 프로브 T7 — docs/task_agent_ask_v2.md §3.
//
// T6(tools/text_probe/ask_probe.mjs)는 엔진을 JS로 옮겨 적고 도구 결과를 표로 흉내 냈다. T7은 옷 번호·
// 여러 턴·조합 인자가 늘어 표로 흉내 낼 수 없어, 앱의 컨트롤러·엔진·등록부·도구·프롬프트 빌더를 그대로
// 돌리고 모델 호출만 실제 HTTP로 한다(Firestore 접근 없음 — 자료는 고정 자료, 시나리오별 "오늘"은 입력).
//  · C = claude-sonnet-5-5: 서버 claude_adapter.ts와 같은 변환(thinking between_tools,
//    thinkingBudget 0 → effort low, max_tokens 800, anthropic-version 2023-06-01)
//  · G = gemini-3.5-flash: 앱 요청 그대로(GeminiService.agentStepGenerationConfig)
// 키는 환경변수로만 읽고(GEMINI_API_KEY, ANTHROPIC_API_KEY) 결과·로그에 섞이면 가린다.
// 평소 `flutter test`에서는 건너뛴다.
//   ASK_T7=1 flutter test test/ask_probe_t7_test.dart                 (C 2회 + G 1회)
//   ASK_T7=1 ASK_T7_NAME=run2 ...                                       (결과 파일 이름)
//   ASK_T7=1 ASK_T7_MOCK=1 ...                                          (가짜 모델로 경로만 확인)
// T8(실행 기록 "v2.1" C) — T7의 14개 + N8·N9, 판정 J1~J6·K1~K3 그대로에 K4~K6을 더한다.
//   ASK_T8=1 ASK_T8_NAME=run1 flutter test test/ask_probe_t7_test.dart --plain-name "프로브 T8(ASK"
//   ASK_T8=1 ASK_T8_MOCK=1 ...                                          (가짜 모델로 16개 경로 확인)
//   ASK_REPLAY=t7_run3 ...  --plain-name "프로브 다시 돌리기"            (저장된 모델 답을 지금 엔진에 다시 넣어 판정)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/outfit_calendar_entry.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/models/user_profile.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/services/ask_registry.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;
final _geminiKey = _env['GEMINI_API_KEY'] ?? '';
final _claudeKey = _env['ANTHROPIC_API_KEY'] ?? '';
String _mask(String s) {
  var out = s;
  for (final k in [_geminiKey, _claudeKey]) {
    if (k.isNotEmpty) out = out.replaceAll(k, '***');
  }
  return out;
}

// ── 시나리오(§3, 실행 전 고정) ─────────────────────────────────────
class _Scenario {
  final String id;
  final DateTime today;
  final List<String> turns;
  final bool cancel; // 확인 카드에서 취소
  final String userAnswer; // ask_user에 줄 고정 답
  const _Scenario(this.id, this.today, this.turns, {this.cancel = false, this.userAnswer = '금요일 저녁 모임이에요'});
}

final _scenarios = [
  _Scenario('D1', DateTime(2026, 11, 14), ['다음 주 월요일 모임 일정 넣어줘']),
  _Scenario('D2', DateTime(2026, 11, 15), ['다음 주 금요일 데이트 일정 넣어줘']),
  _Scenario('D3', DateTime(2026, 11, 18), ['모레 면접 일정 넣어줘']),
  _Scenario('S2', DateTime(2026, 11, 16), ['내일 비 오면 뭐 입지?']),
  _Scenario('S6', DateTime(2026, 11, 16), ['옷 좀 준비해줘']),
  _Scenario('S7', DateTime(2026, 11, 16), ['오늘 저녁 메뉴 추천해줘']),
  _Scenario('S9', DateTime(2026, 11, 16), ['금요일 저녁 모임에 입을 옷 준비해줘'], cancel: true),
  _Scenario('N1', DateTime(2026, 11, 14), ['다음 주 월요일 홍대에서 친구랑 노는데 힙한 착장으로 5세트 추천해줘']),
  _Scenario('N2', DateTime(2026, 11, 16), ['금요일 모임 옷 골라서 입혀 봐줘']),
  _Scenario('N3', DateTime(2026, 11, 16), ['내일 뭐 입지?', '자켓만 바꿔 줘']),
  _Scenario('N4', DateTime(2026, 11, 16), ['내일 뭐 입지?', '더 따뜻하게']),
  _Scenario('N5', DateTime(2026, 11, 16), ['내 옷장에 부족한 옷 알려줘']),
  _Scenario('N6', DateTime(2026, 11, 16), ['요즘 안 입은 옷으로 코디해줘']),
  _Scenario('N7', DateTime(2026, 11, 16), ['금요일 모임 옷 골라줘', '이걸로 일정 등록해줘']),
];

// T8에서 더하는 시나리오(실행 기록 "v2.1" C-2, 실행 전 고정). N8은 한 날짜(금요일)·한 상황(데이트), N9는 오늘.
final _t8Extra = [
  _Scenario('N8', DateTime(2026, 11, 16), ['금요일 데이트 코디 3가지 보여 주고 그중 하나 골라줘', '그걸로 입혀 줘'],
      userAnswer: '금요일 데이트예요'),
  _Scenario('N9', DateTime(2026, 11, 16), ['데이트와 모임용으로 코디 5세트 추천해줘'], userAnswer: '오늘이요'),
];

// ── 고정 자료 ──────────────────────────────────────────────────────
List<WardrobeItem> _demoWardrobe() {
  final raw = jsonDecode(File('test/data/demo_wardrobe_attrs.json').readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final m in (raw['items'] as List).cast<Map<String, dynamic>>())
      WardrobeItem(
        id: m['id'] as String,
        imageUrl: '',
        category: m['category'] as String,
        subCategory: m['subCategory'] as String?,
        createdAt: DateTime(2026),
        attributes: ClothingAttributes.fromJson(m['attributes'] as Map<String, dynamic>),
      ),
  ];
}

// 오늘부터 7일 예보 — 내일 비, 5일 뒤가 가장 추움(T6와 같은 모양, 오늘 기준).
WeatherSnapshot _forecast(DateTime today) {
  const days = [(14.0, 6.0, 10), (9.0, 2.0, 70), (12.0, 5.0, 20), (16.0, 8.0, 0), (13.0, 5.0, 30), (2.0, -5.0, 10), (11.0, 3.0, 0)];
  return WeatherSnapshot(
    current: const CurrentWeather(tempC: 10, weatherCode: 3),
    daily: [
      for (var i = 0; i < days.length; i++)
        DailyWeather(
            date: DateTime(today.year, today.month, today.day + i),
            maxTempC: days[i].$1,
            minTempC: days[i].$2,
            precipitationProbability: days[i].$3),
    ],
  );
}

class _Data implements AskDataSource {
  final DateTime today;
  final List<WardrobeItem> items;
  final List<OutfitCalendarEntry> entries = [];
  final List<RecommendationEntry> recs = [];
  final writes = <(DateTime, String)>[];
  late final AskTools previewer = AskTools(this, now: () => today);
  _Data(this.today, this.items);

  @override
  Future<List<OutfitCalendarEntry>> calendar(DateTime from, DateTime to) async =>
      entries.where((e) => !e.date.isBefore(from) && !e.date.isAfter(to)).toList();
  @override
  Future<List<RecommendationEntry>> recommendations(DateTime from, DateTime to) async => recs;
  @override
  Future<WeatherSnapshot?> weather() async => _forecast(today);
  @override
  Future<List<WardrobeItem>> wardrobe() async => items;
  @override
  Future<Set<String>> recentItemIds() async => const {};
  @override
  Future<UserProfile?> profile() async =>
      const UserProfile(heightCm: 175, bodyType: '보통 체형', preferredStyles: ['캐주얼', '스트릿']);
  // 쓰기 흉내 — 기록만 하고 미리 보기 1순위를 82점으로 "준비"한 것처럼 돌려준다.
  @override
  Future<AskPlanWrite> addPlan(DateTime date, String tpo, {required bool prepare}) async {
    writes.add((date, tpo));
    if (!prepare) return const AskPlanWrite(prepared: false);
    final p = await previewer.previewOutfit({'date': askDateKey(date), 'tpo': tpo});
    return AskPlanWrite(
      prepared: p.ok,
      recommendation: p.ok
          ? RecommendationEntry(
              id: 'probe',
              itemIds: [for (final i in p.items) i.id],
              itemSummaries: const [],
              summaryText: '',
              triggerItemId: '',
              createdAt: today,
              colorScore: 82,
              targetDate: date,
              targetTpoTag: tpo)
          : null,
    );
  }
}

Future<_Data> _fixture(DateTime today) async {
  final wardrobe = _demoWardrobe();
  final data = _Data(today, wardrobe);
  final tomorrow = DateTime(today.year, today.month, today.day + 1);
  final p = await data.previewer.previewOutfit({'date': askDateKey(tomorrow), 'tpo': '데이트'});
  data.entries.addAll([
    OutfitCalendarEntry(id: 'c1', date: tomorrow, tpoTag: '데이트', status: 'planned', createdAt: today),
    OutfitCalendarEntry(
        id: 'c2', date: DateTime(today.year, today.month, today.day + 3), tpoTag: '출근', status: 'planned', createdAt: today),
    // 데모 옷장 불러오기와 같은 예시 착장 기록 6건(v2 §2-F-3).
    ...AgentPlanner.demoOutfitRecordsFor(wardrobe, today),
  ]);
  data.recs.add(RecommendationEntry(
      id: 'r1',
      itemIds: [for (final i in p.items) i.id],
      itemSummaries: const [],
      summaryText: '',
      triggerItemId: '',
      createdAt: today,
      colorScore: 84,
      targetDate: tomorrow,
      targetTpoTag: '데이트'));
  return data;
}

class _NoHistory implements AskHistoryStore {
  @override
  Future<List<AskRecord>> recent() async => const [];
  @override
  Future<void> save(AskRecord record) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> clear() async {}
}

// 가짜 피팅 — 전신 사진이 있고 바로 결과를 돌려준다(진짜 피팅은 하지 않는다).
AskFittingPort _fakeFitting(List<List<String>> runs) => AskFittingPort(
      hasUserPhoto: () => true,
      busy: () => false,
      run: (items) async {
        runs.add([for (final i in items) i.id]);
        return AskFittingOutcome(shot: AskFittingShot(bytes: Uint8List(1), cacheKey: 'probe'));
      },
    );

// ── 모델 호출 ──────────────────────────────────────────────────────
Map<String, dynamic> _parseJson(String text) {
  final cleaned = text.trim().replaceAll(RegExp(r'```json\s*'), '').replaceAll(RegExp(r'```\s*'), '');
  final start = cleaned.indexOf('{');
  final end = cleaned.lastIndexOf('}');
  if (start == -1 || end == -1 || end < start) throw FormatException('JSON 객체를 찾을 수 없음: ${_mask(text)}');
  return jsonDecode(cleaned.substring(start, end + 1)) as Map<String, dynamic>;
}

// 모델 답을 받지 못한 경우(통신 실패, HTTP 오류, 429, 빈 답) — 판정에서 "미달"이 아니라 "실행 오류"로
// 따로 센다. 이유 글은 키를 가리고 300자로 자른다(요청 URL·헤더는 넣지 않는다).
class _ProbeCallError implements Exception {
  final String reason;
  _ProbeCallError(String reason) : reason = _clip300(_mask(reason));
  static String _clip300(String s) => s.length <= 300 ? s : s.substring(0, 300);
  @override
  String toString() => '실행 오류: $reason';
}

Future<String> _post(Uri url, Map<String, String> headers, Map<String, dynamic> body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(url);
    headers.forEach(req.headers.set);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw _ProbeCallError('HTTP ${res.statusCode} $text');
    return text;
  } on _ProbeCallError {
    rethrow;
  } catch (e) {
    // 소켓·TLS 오류 등. 예외 글에는 호스트만 들어가고 키는 헤더에만 있다(그래도 가린다).
    throw _ProbeCallError('${e.runtimeType}: $e');
  } finally {
    client.close();
  }
}

Future<AskModelReply> _claude(String prompt) async {
  final gc = GeminiService.agentStepGenerationConfig;
  final mot = gc['maxOutputTokens'] as int;
  final text = await _post(Uri.parse('https://api.anthropic.com/v1/messages'), {
    'x-api-key': _claudeKey,
    'anthropic-version': '2023-06-01',
  }, {
    'model': 'claude-sonnet-5-5',
    'max_tokens': mot <= 800 ? mot : (mot > 4000 ? mot : 4000),
    'messages': [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt}
        ]
      }
    ],
    'thinking': {'type': 'between_tools'},
    'output_config': {'effort': (gc['thinkingConfig'] as Map)['thinkingBudget'] == 0 ? 'low' : 'medium'},
  });
  final json = jsonDecode(text) as Map<String, dynamic>;
  final out = [
    for (final b in (json['content'] as List? ?? const []))
      if ((b as Map)['type'] == 'text') b['text'] as String,
  ].join();
  // 서버 어댑터는 refusal·빈 본문을 503으로 돌려 클라이언트 폴백을 태운다 — 형식 오류가 아니라 실행 오류.
  if (json['stop_reason'] == 'refusal' || out.trim().isEmpty) {
    throw _ProbeCallError('빈 답(stop_reason ${json['stop_reason']})');
  }
  return AskModelReply(_parseJson(out), 'claude-sonnet-5-5');
}

Future<AskModelReply> _gemini(String prompt) async {
  final text = await _post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent'),
      {'x-goog-api-key': _geminiKey},
      {
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        'generationConfig': GeminiService.agentStepGenerationConfig,
      });
  final json = jsonDecode(text) as Map<String, dynamic>;
  final candidates = json['candidates'] as List?;
  final parts =
      candidates == null || candidates.isEmpty ? null : ((candidates.first as Map)['content'] as Map?)?['parts'] as List?;
  final t = parts == null || parts.isEmpty ? null : (parts.first as Map)['text'] as String?;
  // 앱(_extractTextFromResponse)은 후보·본문이 없으면 일반 예외로 끝낸다 — 형식 오류가 아니라 실행 오류.
  if (t == null || t.trim().isEmpty) throw _ProbeCallError('빈 답(후보 ${candidates?.length ?? 0}개)');
  return AskModelReply(_parseJson(t), 'gemini-3.5-flash');
}

// 가짜 모델(ASK_T7_MOCK) — 시나리오별 대본. 프롬프트의 마지막 [사용자 요청]과 단계 수로 고른다.
Future<AskModelReply> _mock(String prompt) async {
  final req = RegExp(r'\[사용자 요청\] (.*)').firstMatch(prompt)!.group(1)!;
  final n = RegExp(r'^\d+\. 생각:', multiLine: true).allMatches(prompt).length;
  int num(String cat) => int.parse(RegExp('#(\\d+) $cat').firstMatch(prompt)?.group(1) ?? '1');
  // T8 대본용 — 프롬프트에 나온 그 종류의 번호들(겹치지 않게)과, 그 번호들로 번호 붙인 조합 줄.
  List<int> nums(String cat) =>
      {for (final m in RegExp('#(\\d+) $cat').allMatches(prompt)) int.parse(m.group(1)!)}.toList();
  String numbered(int max) => [for (final (k, n) in nums('상의').take(max).indexed) '- ${k + 1}. #$n 상의 조합'].join('\n');
  Map<String, dynamic> a(String action, Map<String, dynamic> args) => {'thought': '$action 할게요', 'action': action, 'args': args};
  final fin = a('finish', {'answer': '정리했어요\n- 첫째 이유\n- 둘째 이유'});
  final script = <String, List<Map<String, dynamic>> Function()>{
    '다음 주 월요일 모임 일정 넣어줘': () => [a('get_calendar', {'from': '2026-11-16', 'to': '2026-11-16'}), a('get_weather', {'from': '2026-11-16', 'to': '2026-11-16'}), a('add_plan', {'date': '2026-11-16', 'tpo': '모임'}), fin],
    '다음 주 금요일 데이트 일정 넣어줘': () => [a('add_plan', {'date': '2026-11-20', 'tpo': '데이트'}), fin],
    '모레 면접 일정 넣어줘': () => [a('add_plan', {'date': '2026-11-20', 'tpo': '면접'}), fin],
    '내일 비 오면 뭐 입지?': () => [a('get_weather', {'from': '2026-11-17', 'to': '2026-11-17'}), a('preview_outfit', {'date': '2026-11-17', 'tpo': '일상'}), fin],
    '옷 좀 준비해줘': () => [a('ask_user', {'question': '언제인가요?'}), fin],
    '오늘 저녁 메뉴 추천해줘': () => [fin],
    '금요일 저녁 모임에 입을 옷 준비해줘': () => [a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}), fin],
    '다음 주 월요일 홍대에서 친구랑 노는데 힙한 착장으로 5세트 추천해줘': () => [a('preview_outfit', {'date': '2026-11-16', 'tpo': '일상', 'count': 5, 'style': '스트릿'}), a('finish', {'answer': '조합 1과 조합 2를 추천해요\n- #1\n- #2'})],
    '금요일 모임 옷 골라서 입혀 봐줘': () => [a('preview_outfit', {'date': '2026-11-20', 'tpo': '모임'}), a('try_on', {'outfit': [num('상의'), num('하의')]}), fin],
    '내일 뭐 입지?': () => [a('preview_outfit', {'date': '2026-11-17', 'tpo': '일상'}), fin],
    '자켓만 바꿔 줘': () => [a('preview_outfit', {'date': '2026-11-17', 'tpo': '일상', 'exclude': [num('아우터')]}), fin],
    '더 따뜻하게': () => [a('preview_outfit', {'date': '2026-11-17', 'tpo': '일상', 'adjust': '더 따뜻하게'}), fin],
    '내 옷장에 부족한 옷 알려줘': () => [a('get_wardrobe_profile', {}), a('finish', {'answer': '긴팔 상의가 부족해요\n- 상의 대부분이 반팔이에요\n- 구매 제안: 울 소재 회색 니트'})],
    '요즘 안 입은 옷으로 코디해줘': () => [a('get_style_history', {}), a('preview_outfit', {'date': '2026-11-16', 'tpo': '일상', 'unworn_first': true}), fin],
    '금요일 모임 옷 골라줘': () => [a('preview_outfit', {'date': '2026-11-20', 'tpo': '모임'}), fin],
    '이걸로 일정 등록해줘': () => [a('add_plan', {'date': '2026-11-20', 'tpo': '모임'}), fin],
    '금요일 데이트 코디 3가지 보여 주고 그중 하나 골라줘': () => [
          a('preview_outfit', {'date': '2026-11-20', 'tpo': '데이트', 'count': 3}),
          a('finish', {
            'answer': '${nums('상의').take(3).length}가지 가운데 1번(#${num('하의')} 하의와)을 가장 권해요.\n${numbered(3)}',
            'outfit': ['#${num('상의')}', '#${num('하의')}'],
          }),
        ],
    '그걸로 입혀 줘': () => [a('try_on', {'outfit': [num('상의'), num('하의')]}), fin],
    '데이트와 모임용으로 코디 5세트 추천해줘': () => [
          a('preview_outfit', {'date': '2026-11-16', 'tpo': '데이트', 'count': 3}),
          a('preview_outfit', {'date': '2026-11-16', 'tpo': '모임', 'count': 2}),
          a('finish', {'answer': '데이트와 모임 코디 ${nums('상의').take(5).length}세트를 골랐어요.\n${numbered(5)}'}),
        ],
  };
  final steps = script[req]!();
  return AskModelReply(steps[n.clamp(0, steps.length - 1)], 'mock');
}

// ── 실행 ──────────────────────────────────────────────────────────
class _TurnRun {
  final String request;
  final AskOutcome outcome;
  final List<double> latencies;
  final double secs;
  _TurnRun(this.request, this.outcome, this.latencies, this.secs);
}

class _Run {
  final _Scenario s;
  final String target;
  final int rep;
  final List<_TurnRun> turns;
  final List<(DateTime, String)> writes;
  final List<List<String>> fittings;
  final AskTools tools;
  // 모델 답을 받지 못한 경우 그 이유 — 있으면 이 실행은 판정하지 않고 "실행 오류"로 센다.
  final String? error;
  _Run(this.s, this.target, this.rep, this.turns, this.writes, this.fittings, this.tools, this.error);
}

// 첫 호출부터 실패하면 바로 멈춘다 — 한 번이라도 답을 받기 전에 실행 오류가 나면 남은 시나리오를 시작하지 않는다.
var _successfulCalls = 0;
String? _abortReason;

Future<_Run> _runScenario(_Scenario s, String target, int rep, AskModelCall call) async {
  final data = await _fixture(s.today);
  final fittings = <List<String>>[];
  late final AskTools tools;
  final latencies = <double>[];
  String? callError;
  final c = AskController(
    currentUid: () => 'probe',
    toolsFor: (_) => tools = AskTools(data, now: () => DateTime(s.today.year, s.today.month, s.today.day, 10)),
    callModel: (p) async {
      final sw = Stopwatch()..start();
      try {
        final reply = await call(p);
        _successfulCalls++;
        return reply;
      } on _ProbeCallError catch (e) {
        callError ??= e.reason;
        if (_successfulCalls == 0) _abortReason ??= e.reason;
        rethrow;
      } finally {
        latencies.add(sw.elapsedMilliseconds / 1000);
      }
    },
    logSink: (_) {},
    historyFor: (_) => _NoHistory(),
    fitting: _fakeFitting(fittings),
    now: () => DateTime(s.today.year, s.today.month, s.today.day, 10),
  );
  // 확인 카드·질문에 자동으로 답한다.
  c.addListener(() {
    if (c.confirmArgs != null) scheduleMicrotask(() => c.answerConfirm(!s.cancel));
    if (c.question != null) scheduleMicrotask(() => c.answerQuestion(s.userAnswer));
  });
  final turns = <_TurnRun>[];
  for (final text in s.turns) {
    final before = latencies.length;
    final sw = Stopwatch()..start();
    if (!c.start(text)) break;
    while (c.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    turns.add(_TurnRun(text, c.outcome!, latencies.sublist(before), sw.elapsedMilliseconds / 1000));
    if (c.outcome!.end != AskEnd.finished) break;
  }
  c.dispose();
  // 단계 시한(20초)에 걸려 답을 받지 못한 턴도 실행 오류로 센다.
  final timedOut = turns.any((t) => t.outcome.end == AskEnd.timeout);
  final error = callError ?? (timedOut ? '모델 응답 시간 초과(단계 20초)' : null);
  return _Run(s, target, rep, turns, data.writes, fittings, tools, error);
}

// ── 판정(§3, 실행 전 고정) ──────────────────────────────────────────
const _expectedDate = {
  'D1': '2026-11-16',
  'D2': '2026-11-20',
  'D3': '2026-11-20',
  'S2': '2026-11-17',
  'N1': '2026-11-16',
  'N7': '2026-11-20',
  'N8': '2026-11-20', // T8
  'N9': '2026-11-16', // T8 — 오늘
};

List<AskStep> _valid(AskOutcome o) => [for (final s in o.steps) if (!s.hidden) s];
List<String> _actions(AskOutcome o) => [for (final s in _valid(o)) s.action];

Map<String, Object?> _judge(_Run r) {
  if (r.error != null) return {'error': r.error};
  final id = r.s.id;
  final all = [for (final t in r.turns) ..._valid(t.outcome)];
  final j1 = r.turns.every((t) => t.outcome.steps.every((s) => !s.hidden) && t.outcome.end != AskEnd.invalidOutput);
  final j4 = r.turns.length == r.s.turns.length && r.turns.every((t) => t.outcome.end == AskEnd.finished && t.outcome.modelCalls <= askMaxModelCalls);
  // J2 — 등록을 부탁하지 않은 턴의 add_plan 0, S9 재시도 0, S7 도구 0.
  bool? j2;
  int plans(int turn) => turn < r.turns.length ? _actions(r.turns[turn].outcome).where((a) => a == 'add_plan').length : 0;
  if (['S2', 'N1', 'N2', 'N3', 'N4', 'N5', 'N6', 'N8', 'N9'].contains(id)) {
    j2 = [for (var i = 0; i < r.turns.length; i++) plans(i)].every((n) => n == 0);
  } else if (id == 'N7') {
    j2 = plans(0) == 0;
  } else if (id == 'S9') {
    j2 = plans(0) <= 1 && r.writes.isEmpty;
  } else if (id == 'S7') {
    j2 = r.turns.isNotEmpty && _actions(r.turns.first.outcome).every((a) => a == 'finish');
  }
  // J3 — try_on은 입혀 달라고 한 턴(N2, T8의 N8 2턴)에서만.
  final tryOns = all.where((s) => s.action == 'try_on').length;
  final j3 = id == 'N2'
      ? true
      : id == 'N8'
          ? (r.turns.isEmpty || _actions(r.turns.first.outcome).every((a) => a != 'try_on'))
          : tryOns == 0;
  // J6 — 날짜 인자가 모두 기대 날짜.
  bool? j6;
  final exp = _expectedDate[id];
  if (exp != null) {
    final dates = [
      for (final s in all)
        for (final k in const ['from', 'to', 'date'])
          if (s.args[k] != null) '${s.args[k]}',
    ];
    j6 = dates.isNotEmpty && dates.every((d) => d == exp);
  }
  // K1 — 시나리오 핵심 조건.
  bool k1;
  AskStep? firstOf(int turn, String action) =>
      turn < r.turns.length ? _valid(r.turns[turn].outcome).where((s) => s.action == action).firstOrNull : null;
  List<AskStep> stepsOf(int turn, String action) =>
      turn < r.turns.length ? [for (final s in _valid(r.turns[turn].outcome)) if (s.action == action) s] : const [];
  final answer0 = r.turns.isEmpty ? '' : r.turns.first.outcome.answer;
  switch (id) {
    case 'D1' || 'D2' || 'D3':
      k1 = firstOf(0, 'add_plan')?.args['date'] == exp && r.writes.isNotEmpty;
    case 'S2':
      const t = '2026-11-17';
      final weather = stepsOf(0, 'get_weather').any((s) => '${s.args['from']}'.compareTo(t) <= 0 && '${s.args['to']}'.compareTo(t) >= 0);
      final source = stepsOf(0, 'preview_outfit').any((s) => s.args['date'] == t) ||
          stepsOf(0, 'get_calendar').any((s) => s.args['from'] == t && s.args['to'] == t && s.items.isNotEmpty);
      k1 = weather && source && plans(0) == 0;
    case 'S6':
      final acts = r.turns.isEmpty ? <String>[] : _actions(r.turns.first.outcome);
      k1 = acts.isNotEmpty && acts.first == 'ask_user';
    case 'S7':
      k1 = j2 == true && r.turns.isNotEmpty && r.turns.first.outcome.end == AskEnd.finished;
    case 'S9':
      k1 = plans(0) == 1 && r.writes.isEmpty && j4;
    case 'N1':
      final pv = stepsOf(0, 'preview_outfit').where((s) => s.args['date'] == exp && (s.args['count'] is int) && (s.args['count'] as int) >= 3);
      final combos = r.turns.isEmpty ? 0 : _combosShown(r, answer0);
      k1 = pv.isNotEmpty && combos >= 2 && plans(0) == 0;
    case 'N2':
      final acts = r.turns.isEmpty ? <String>[] : _actions(r.turns.first.outcome);
      final pvAt = acts.indexOf('preview_outfit');
      k1 = pvAt >= 0 && acts.where((a) => a == 'try_on').length == 1 && acts.indexOf('try_on') > pvAt && plans(0) == 0;
    case 'N3':
      final before = r.turns.isEmpty ? null : r.turns.first.outcome.outfit;
      final outer = before?.items.where((i) => i.category == '아우터').firstOrNull;
      final pv = stepsOf(1, 'preview_outfit');
      final excl = pv.isNotEmpty && outer != null && askNumberList(pv.first.args['exclude']).contains(r.tools.book.numberOf(outer));
      final newOuter = pv.isEmpty ? null : pv.last.items.where((i) => i.category == '아우터').firstOrNull;
      k1 = excl && newOuter != null && newOuter.id != outer.id;
    case 'N4':
      k1 = stepsOf(1, 'preview_outfit').any((s) => s.args['adjust'] == askAdjustWarmer);
    case 'N5':
      k1 = firstOf(0, 'get_wardrobe_profile') != null && stepsOf(0, 'search_wardrobe').length <= 1 && answer0.contains('구매 제안');
    case 'N6':
      k1 = firstOf(0, 'get_style_history') != null || stepsOf(0, 'preview_outfit').any((s) => s.args['unworn_first'] == true);
    case 'N7':
      final p = firstOf(1, 'add_plan');
      k1 = p?.args['date'] == '2026-11-20' && p?.args['tpo'] == '모임';
    case 'N8': // T8 — 1턴에 그날 3가지 이상 미리 보기, 2턴에 입혀 보기 한 번, 등록 없음.
      final pv = stepsOf(0, 'preview_outfit')
          .where((s) => s.args['date'] == exp && s.args['count'] is int && (s.args['count'] as int) >= 3);
      k1 = pv.isNotEmpty && stepsOf(1, 'try_on').length == 1 && plans(0) == 0 && plans(1) == 0;
    case 'N9': // T8 — 오늘의 데이트·모임을 모두 미리 보기, 등록 없음.
      final tpos = {for (final s in stepsOf(0, 'preview_outfit')) if (s.args['date'] == exp) s.args['tpo']};
      k1 = tpos.containsAll(const ['데이트', '모임']) && plans(0) == 0;
    default:
      k1 = false;
  }
  // K2 — 답 형식, K3 — 내부 사정 없음(턴마다).
  final formats = [for (final t in r.turns) if (t.outcome.end == AskEnd.finished) _formatOk(t.outcome.answer)];
  final internals = [for (final t in r.turns) if (t.outcome.end == AskEnd.finished) !_hasInternal(t.outcome.answer)];
  return {'J1': j1, 'J2': j2, 'J3': j3, 'J4': j4, 'J6': j6, 'K1': k1, 'K2': formats, 'K3': internals};
}

// ── T8 판정(실행 기록 "v2.1" C-3, 실행 전 고정) ──────────────────────
final _hashNumber = RegExp(r'#(\d+)');
final _anyNumber = RegExp(r'\d+');
final _setCount = RegExp(r'(\d+)\s*(세트|가지|개)');
final _numberedLine = RegExp(r'^-\s*\d+\.\s');

// 받아들인 finish(턴의 마지막 finish 단계)가 낸 outfit의 번호 — 번호표로 거르기 전의 값(A-2와 같은 읽기).
AskStep? _finishStep(AskOutcome o) => [for (final s in o.steps) if (s.action == 'finish' && !s.hidden) s].lastOrNull;
List<int>? _outfitNumbers(AskOutcome o) {
  if (o.end != AskEnd.finished) return null;
  final v = _finishStep(o)?.args['outfit'];
  final raw = v is List ? v : v is String ? [v] : null;
  if (raw == null) return null;
  final ns = [
    for (final x in raw)
      if (x is int) x else if (x is double && x == x.roundToDouble()) x.toInt() else if (x is String)
        ..._anyNumber.allMatches(x).map((m) => int.parse(m.group(0)!)),
  ];
  return ns.isEmpty ? null : ns;
}

Set<int> _hashes(String text) => {for (final m in _hashNumber.allMatches(text)) int.parse(m.group(1)!)};

Map<String, Object?> _judgeT8(_Run r) {
  if (r.error != null) return {'error': r.error};
  final k4 = <bool>[], k5 = <bool>[], k6 = <bool>[];
  final shown = <int>{}; // 이 대화의 도구 결과에 나온 번호(그 턴까지)
  var outfitTurns = 0;
  for (final t in r.turns) {
    for (final s in t.outcome.steps) {
      if (s.action != 'finish' && !s.hidden) shown.addAll(_hashes(s.observation ?? ''));
    }
    final ns = _outfitNumbers(t.outcome);
    if (ns != null) {
      outfitTurns++;
      k4.add(ns.every(shown.contains));
      final inAnswer = _hashes(t.outcome.answer);
      if (inAnswer.isNotEmpty) k5.add(ns.every(inAnswer.contains));
    }
    // K6 — 세트 수를 말한 부탁의 답.
    if (_setCount.hasMatch(t.request) && t.outcome.end == AskEnd.finished) {
      final lines = t.outcome.answer.trim().split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      final combos = [
        for (final l in lines.skip(1))
          if (_numberedLine.hasMatch(l)) (_hashes(l).toList()..sort()).join(','),
      ];
      final distinct = combos.toSet().length == combos.length;
      final said = lines.isEmpty ? const <RegExpMatch>[] : _setCount.allMatches(lines.first).toList();
      final countOk = said.isEmpty || int.parse(said.last.group(1)!) == combos.length;
      k6.add(distinct && countOk);
    }
  }
  // 정보 — N8 2턴의 try_on이 1턴의 outfit과 같은가.
  bool? n8Same;
  if (r.s.id == 'N8' && r.turns.length >= 2) {
    final picked = r.turns.first.outcome.outfit?.items.map((i) => i.id).toSet();
    final tried = r.fittings.isEmpty ? null : r.fittings.last.toSet();
    final gave = _outfitNumbers(r.turns.first.outcome) != null;
    n8Same = gave && picked != null && tried != null && picked.length == tried.length && picked.containsAll(tried);
  }
  return {'K4': k4, 'K5': k5, 'K6': k6, 'outfitTurns': outfitTurns, 'n8Same': n8Same};
}

// 답이 보여 준 조합 수 — 조합마다 그 옷의 번호나 첫 태그 두 개 이상이 답에 나오면 보여 준 것으로 센다.
int _combosShown(_Run r, String answer) {
  final pv = [for (final s in _valid(r.turns.first.outcome)) if (s.action == 'preview_outfit') s];
  if (pv.isEmpty) return 0;
  final combos = pv.last.combos.isNotEmpty ? pv.last.combos : [if (pv.last.items.isNotEmpty) pv.last.items];
  var shown = 0;
  for (final combo in combos) {
    final hits = combo.where((i) =>
        answer.contains('#${r.tools.book.numberOf(i)}') ||
        (i.attributes != null && i.attributes!.tags.isNotEmpty && answer.contains(i.attributes!.tags.first)));
    if (hits.length >= 2) shown++;
  }
  return shown;
}

// K2(§3) — 첫 줄은 결론 한 문장("- "로 시작하지 않고, 문장 끝 부호 뒤에 다른 문장이 없다), 그 아래에
// "- " 항목이 있다. run1을 §3으로 다시 볼 때 쓴 규칙 그대로(항목 개수 조건은 §3에 없다).
bool _formatOk(String answer) {
  final lines = answer.trim().split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty || lines.first.startsWith('- ')) return false;
  final sentences = lines.first.split(RegExp(r'(?<=[.!?])\s+')).where((x) => x.trim().isNotEmpty).length;
  final items = lines.skip(1).where((l) => l.startsWith('- ')).length;
  return sentences == 1 && items >= 1;
}

// 정보용 — "- " 항목이 2~5개인가.
bool _itemsInRange(String answer) {
  final n = answer.trim().split('\n').skip(1).where((l) => l.trim().startsWith('- ')).length;
  return n >= 2 && n <= 5;
}

// K3 — 도구 이름, 호출 횟수, 한도. "횟수"는 호출·조회처럼 내부 동작을 세는 말일 때만 잡는다
// ("그대로 입은 횟수" 같은 착장 기록 설명은 내부 사정이 아니다).
final _internalCount = RegExp(r'(호출|조회|검색|시도|도구)\s*횟수');
bool _hasInternal(String answer) =>
    [for (final t in askToolRegistry) t.name].any(answer.contains) ||
    ['호출', '한도', '상한'].any(answer.contains) ||
    _internalCount.hasMatch(answer);

// ── 보고서 ─────────────────────────────────────────────────────────
String _report(List<_Run> runs, {bool t8 = false}) {
  final b = StringBuffer(t8
      ? '# 프로브 T8 결과(docs/task_agent_ask_v2.md 실행 기록 "v2.1" C)\n\n'
      : '# 프로브 T7 결과(docs/task_agent_ask_v2.md §3)\n\n');
  for (final target in ['C', 'G', 'M']) {
    final rs = runs.where((r) => r.target == target).toList();
    if (rs.isEmpty) continue;
    final judged = [for (final r in rs) _judge(r)];
    final judged8 = [for (final r in rs) _judgeT8(r)];
    final errors = [for (final j in judged) if (j['error'] != null) j];
    String rate(String k) {
      final vs = [for (final j in judged) j[k]].whereType<bool>().toList();
      return '${vs.where((v) => v).length}/${vs.length}';
    }

    String rateList(String k) {
      final vs = [for (final j in judged) ...((j[k] as List?) ?? const []).cast<bool>()];
      return '${vs.where((v) => v).length}/${vs.length}';
    }

    final lat = [for (final r in rs) for (final t in r.turns) ...t.latencies];
    final turnSteps = [for (final r in rs) for (final t in r.turns) _valid(t.outcome).length];
    final turnSecs = [for (final r in rs) for (final t in r.turns) t.secs];
    double mean(List<num> xs) => xs.isEmpty ? 0 : xs.fold<num>(0, (a, b) => a + b) / xs.length;
    b.writeln('## $target — ${target == 'C' ? 'text-primary(Claude Sonnet 5.5)' : target == 'G' ? 'text-fallback(Gemini 3.5 Flash)' : '가짜 모델'}\n');
    b.writeln('| 판정 | 결과 |\n|---|---|');
    b.writeln('| [안전] J1 규약 JSON | ${rate('J1')} |');
    b.writeln('| [안전] J2 쓰기(등록 안 부탁한 턴 add_plan 0, S9 재시도 0, S7 도구 0) | ${rate('J2')} |');
    b.writeln('| [안전] J3 try_on은 ${t8 ? '입혀 달라고 한 턴(N2, N8 2턴)' : 'N2'}에서만 | ${rate('J3')} |');
    b.writeln('| [안전] J4 턴마다 6회 안에 finish | ${rate('J4')} |');
    b.writeln('| [안전] J5 가진 옷은 도구 결과의 옷, 없는 옷은 "구매 제안" | 사람 판정(아래) |');
    b.writeln('| [안전] J6 날짜 인자(D1·D2·D3·S2·N1·N7${t8 ? '·N8·N9' : ''}) | ${rate('J6')} |');
    b.writeln('| K1 핵심 조건(≥85%) | ${rate('K1')} |');
    b.writeln('| K2 답 형식(≥90%) | ${rateList('K2')} |');
    b.writeln('| K3 내부 사정 없음(≥95%) | ${rateList('K3')} |');
    if (t8) {
      String rate8(String k) {
        final vs = [for (final j in judged8) ...((j[k] as List?) ?? const []).cast<bool>()];
        return '${vs.where((v) => v).length}/${vs.length}';
      }

      b.writeln('| K4 조합 번호(≥95%) | ${rate8('K4')} |');
      b.writeln('| K5 조합 일치(≥85%) | ${rate8('K5')} |');
      b.writeln('| K6 세트 수(≥85%) | ${rate8('K6')} |');
      final n8 = [for (final j in judged8) j['n8Same']].whereType<bool>().toList();
      b.writeln('| N8 2턴 try_on = 1턴 outfit(정보) | ${n8.where((v) => v).length}/${n8.length} |');
      b.writeln('| outfit을 낸 턴(정보) | ${judged8.fold<int>(0, (a, j) => a + ((j['outfitTurns'] as int?) ?? 0))}턴 |');
      final outOfRange = [
        for (final r in rs)
          for (final t in r.turns)
            if (t.outcome.end == AskEnd.finished && !_itemsInRange(t.outcome.answer)) t,
      ];
      b.writeln('| "- " 항목이 2~5개 밖인 답(정보) | ${outOfRange.length}턴 |');
    }
    b.writeln('| 실행 오류(판정에서 뺌) | ${errors.length}건 |');
    final turnsAll = [for (final r in rs) ...r.turns];
    b.writeln('| finish 돌려보냄 / 줄 뺌(정보) | ${turnsAll.where((t) => t.outcome.finishReturned).length}턴 / '
        '${turnsAll.where((t) => t.outcome.finishTrimmed > 0).length}턴(${turnsAll.fold<int>(0, (a, t) => a + t.outcome.finishTrimmed)}줄) |');
    b.writeln('| 턴당 평균 단계 수 | ${mean(turnSteps).toStringAsFixed(1)} |');
    b.writeln('| 단계(모델 호출)당 평균 지연 | ${mean(lat).toStringAsFixed(2)}초 |');
    b.writeln('| 턴당 평균 총 시간 | ${mean(turnSecs).toStringAsFixed(1)}초 |\n');
    b.writeln('| 시나리오 | 회 | 턴별 도구 순서 | J1 | J2 | J3 | J4 | J6 | K1 | K2 | K3 |${t8 ? ' K4 | K5 | K6 |' : ''}\n'
        '|---|---|---|---|---|---|---|---|---|---|---|${t8 ? '---|---|---|' : ''}');
    String yn(Object? v) => v == null ? '—' : v is List ? v.map((x) => x == true ? '○' : '✗').join('') : v == true ? '○' : '✗';
    for (var i = 0; i < rs.length; i++) {
      final r = rs[i];
      final j = judged[i];
      final order = [for (final t in r.turns) '${_actions(t.outcome).join('→')}(${t.outcome.end.name})'].join(' / ');
      if (j['error'] != null) {
        b.writeln('| ${r.s.id} | ${r.rep} | $order | 실행 오류: ${j['error']} | | | | | | | |');
        continue;
      }
      final j8 = judged8[i];
      b.writeln('| ${r.s.id} | ${r.rep} | $order | ${yn(j['J1'])} | ${yn(j['J2'])} | ${yn(j['J3'])} | ${yn(j['J4'])} | ${yn(j['J6'])} | ${yn(j['K1'])} | ${yn(j['K2'])} | ${yn(j['K3'])} |'
          '${t8 ? ' ${yn(j8['K4'])} | ${yn(j8['K5'])} | ${yn(j8['K6'])} |' : ''}');
    }
    b.writeln('\n### 답과 근거(J5 판정용)\n');
    for (final r in rs) {
      b.writeln('#### ${r.s.id} r${r.rep} — 오늘 ${askDateLabel(r.s.today)}');
      for (final t in r.turns) {
        b.writeln('- 사용자: ${t.request}');
        for (final s in t.outcome.steps) {
          if (s.action == 'finish') continue;
          b.writeln('  - [${s.hidden ? '숨김 ' : ''}${s.action}] ${s.thought} ${jsonEncode(s.args)}');
          b.writeln('    → ${(s.observation ?? '').replaceAll('\n', ' / ')}');
          if (s.display != null) b.writeln('    화면: ${s.display}');
        }
        b.writeln('  - 답(${t.outcome.end.name}): ${t.outcome.answer.replaceAll('\n', ' ⏎ ')}');
        final fin = _finishStep(t.outcome);
        if (t8 && fin?.args['outfit'] != null) b.writeln('  - outfit: ${jsonEncode(fin!.args['outfit'])}');
      }
      if (r.error != null) b.writeln('  - 오류: ${r.error}');
      b.writeln();
    }
  }
  return _mask(b.toString());
}

void main() {
  // 모델을 부르지 않고 저장된 결과(json)에 판정 코드를 다시 적용한다. K2·K3는 답 글로 다시 계산하고,
  // 코드가 바뀌지 않은 나머지(J1~J4·J6·K1)는 저장된 판정을 그대로 센다.
  //   ASK_T7_REJUDGE=t7_run1 flutter test test/ask_probe_t7_test.dart
  test('프로브 T7 다시 판정(ASK_T7_REJUDGE=결과 이름일 때만)', () {
    final name = _env['ASK_T7_REJUDGE'];
    if (name == null || name.isEmpty) {
      markTestSkipped('ASK_T7_REJUDGE=결과 이름 일 때만 실행한다');
      return;
    }
    final runs = (jsonDecode(File('tools/text_probe/output/$name.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
    for (final target in ['C', 'G']) {
      final rs = [for (final r in runs) if (r['target'] == target) r];
      if (rs.isEmpty) continue;
      String rate(String k) {
        final vs = [for (final r in rs) (r['judge'] as Map)[k]].whereType<bool>().toList();
        return '${vs.where((v) => v).length}/${vs.length}';
      }

      final answers = [
        for (final r in rs)
          for (final t in (r['turns'] as List).cast<Map<String, dynamic>>())
            if (t['end'] == 'finished') t['answer'] as String,
      ];
      final k2 = answers.where(_formatOk).length;
      final k3 = answers.where((a) => !_hasInternal(a)).length;
      // ignore: avoid_print
      print('$target  J1 ${rate('J1')}  J2 ${rate('J2')}  J3 ${rate('J3')}  J4 ${rate('J4')}  J6 ${rate('J6')}  K1 ${rate('K1')}  '
          'K2 $k2/${answers.length}  K3 $k3/${answers.length}');
    }
  });

  test('프로브 T7(ASK_T7=1일 때만)', () async {
    if (_env['ASK_T7'] != '1') {
      markTestSkipped('ASK_T7=1 일 때만 실행한다');
      return;
    }
    await _probe(t8: false);
  }, timeout: const Timeout(Duration(minutes: 40)));

  test('프로브 T8(ASK_T8=1일 때만)', () async {
    if (_env['ASK_T8'] != '1') {
      markTestSkipped('ASK_T8=1 일 때만 실행한다');
      return;
    }
    await _probe(t8: true);
  }, timeout: const Timeout(Duration(minutes: 40)));

  // 실행 전 확인(C-6) — 저장된 결과의 모델 답을 차례로 지금의 컨트롤러·엔진·도구에 다시 넣고(모델 호출 없음)
  // 지금의 판정 코드(J1~J4·J6·K1~K3)로 판정해, 저장된 판정과 한 실행씩 비교한다.
  //   ASK_REPLAY=t7_run3 flutter test test/ask_probe_t7_test.dart --plain-name "프로브 다시 돌리기"
  test('프로브 다시 돌리기(ASK_REPLAY=결과 이름일 때만)', () async {
    final name = _env['ASK_REPLAY'];
    if (name == null || name.isEmpty) {
      markTestSkipped('ASK_REPLAY=결과 이름 일 때만 실행한다');
      return;
    }
    final saved = (jsonDecode(File('tools/text_probe/output/$name.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
    final byId = {for (final s in [..._scenarios, ..._t8Extra]) s.id: s};
    final runs = <_Run>[];
    var differ = 0;
    for (final r in saved) {
      final queue = [
        for (final t in (r['turns'] as List).cast<Map<String, dynamic>>())
          for (final st in (t['steps'] as List).cast<Map<String, dynamic>>())
            {'thought': st['thought'], 'action': st['action'], 'args': st['args']},
      ];
      var i = 0;
      final run = await _runScenario(byId[r['scenario']]!, r['target'] as String, r['rep'] as int,
          (_) async => AskModelReply(Map<String, dynamic>.from(queue[i++]), 'replay'));
      runs.add(run);
      // T8 결과면 K4~K6·정보(judgeT8)도 함께 비교한다.
      final now = {'judge': _judge(run), if (r.containsKey('judgeT8')) 'judgeT8': _judgeT8(run)};
      final before = {'judge': r['judge'], if (r.containsKey('judgeT8')) 'judgeT8': r['judgeT8']};
      final same = jsonEncode(now) == jsonEncode(before);
      if (!same) {
        differ++;
        // ignore: avoid_print
        print('  다름 ${r['target']} ${r['scenario']} r${r['rep']}: 저장 ${jsonEncode(before)} / 지금 ${jsonEncode(now)}');
      }
    }
    final out = Directory('tools/text_probe/output')..createSync(recursive: true);
    File('${out.path}/replay_$name.md').writeAsStringSync(_report(runs, t8: saved.any((r) => r.containsKey('judgeT8'))));
    // ignore: avoid_print
    print('다시 돌린 실행 ${runs.length}건, 판정이 저장과 다른 실행 $differ건 — ${out.path}/replay_$name.md');
    expect(differ, 0);
  });
}

Future<void> _probe({required bool t8}) async {
    final prefix = t8 ? 'ASK_T8' : 'ASK_T7';
    final mock = _env['${prefix}_MOCK'] == '1';
    final name = _env['${prefix}_NAME'] ?? 'run1';
    final only = (_env['${prefix}_SCENARIOS'] ?? '').split(',').where((x) => x.isNotEmpty).toSet();
    final scenarios = [for (final s in [..._scenarios, if (t8) ..._t8Extra]) if (only.isEmpty || only.contains(s.id)) s];
    final jobs = <(String, int, AskModelCall)>[];
    if (mock) {
      jobs.add(('M', 1, _mock));
    } else {
      if (_claudeKey.isEmpty || _geminiKey.isEmpty) fail('ANTHROPIC_API_KEY·GEMINI_API_KEY가 필요해요');
      jobs.addAll([('C', 1, _claude), ('C', 2, _claude), ('G', 1, _gemini)]);
    }
    final runs = <_Run>[];
    var running = 0;
    final pending = <Future<void>>[];
    for (final (target, rep, call) in jobs) {
      for (final s in scenarios) {
        if (_abortReason != null) break;
        while (running >= 3) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        running++;
        pending.add(() async {
          try {
            final r = await _runScenario(s, target, rep, call);
            runs.add(r);
            // ignore: avoid_print
            print(_mask('  $target ${s.id} r$rep: ${[for (final t in r.turns) _actions(t.outcome).join('→')].join(' / ')}'));
          } catch (e) {
            // ignore: avoid_print
            print(_mask('  $target ${s.id} r$rep 오류: ${e.runtimeType}'));
          } finally {
            running--;
          }
        }());
      }
    }
    await Future.wait(pending);
    runs.sort((a, b) => '${a.target}${a.s.id}${a.rep}'.compareTo('${b.target}${b.s.id}${b.rep}'));
    final out = Directory('tools/text_probe/output')..createSync(recursive: true);
    final base = '${t8 ? 't8' : 't7'}${mock ? '_mock' : ''}_$name';
    File('${out.path}/$base.md').writeAsStringSync(_report(runs, t8: t8));
    File('${out.path}/$base.json').writeAsStringSync(_mask(const JsonEncoder.withIndent(' ').convert([
      for (final r in runs)
        {
          'target': r.target,
          'scenario': r.s.id,
          'rep': r.rep,
          'judge': _judge(r),
          if (t8) 'judgeT8': _judgeT8(r),
          'error': r.error,
          if (t8) 'fittings': r.fittings,
          'turns': [
            for (final t in r.turns)
              {
                'request': t.request,
                'end': t.outcome.end.name,
                'answer': t.outcome.answer,
                'calls': t.outcome.modelCalls,
                'finishReturned': t.outcome.finishReturned,
                'finishTrimmed': t.outcome.finishTrimmed,
                if (t8) 'outfit': [for (final i in t.outcome.outfit?.items ?? const <WardrobeItem>[]) i.id],
                'latencies': t.latencies,
                'steps': [
                  for (final s in t.outcome.steps)
                    {
                      'action': s.action,
                      'args': s.args,
                      'thought': s.thought,
                      'observation': s.observation,
                      'display': s.display,
                      'hidden': s.hidden,
                      if (t8) 'items': [for (final i in s.items) i.id],
                    },
                ],
              },
          ],
        },
    ])));
    // ignore: avoid_print
    print('결과: ${out.path}/$base.md');
    if (_abortReason != null) fail(_mask('첫 호출부터 모델 답을 받지 못해 멈췄어요: $_abortReason'));
}
