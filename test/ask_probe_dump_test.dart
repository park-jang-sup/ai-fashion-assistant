// AI에게 부탁하기 프로브 T6 입력 — docs/task_agent_ask_v1.md §3. 앱의 프롬프트 빌더와 도구 함수를
// 고정 자료(데모 옷장 고정 자료·가짜 일정·7일 예보, 오늘 2026-11-16 월)로 돌려
// tools/text_probe/input/ask_t6.json에 덤프한다. 프로브(tools/text_probe/ask_probe.mjs)는 이 파일만
// 읽고 Firestore에 접근하지 않는다. 평소 `flutter test`에서는 건너뛴다:
//   ASK_PROBE_DUMP=1 flutter test test/ask_probe_dump_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/constants/tpo_tags.dart';
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/outfit_calendar_entry.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_tools.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:ai_fashion_assistant/services/weather_fit.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = 'tools/text_probe/input/ask_t6.json';
final _today = DateTime(2026, 11, 16); // 월요일 — §3 고정

// §3 시나리오(실행 전 고정). userAnswer는 ask_user가 나오면 돌려줄 고정 답.
const _scenarios = [
  (id: 'S1', request: '금요일 저녁 모임에 입을 옷 준비해줘', cancel: false, userAnswer: '네, 그렇게 해 주세요'),
  (id: 'S2', request: '내일 비 오면 뭐 입지?', cancel: false, userAnswer: '일상이에요'),
  (id: 'S3', request: '이번 주 일정 코디 준비됐는지 확인해줘', cancel: false, userAnswer: '네'),
  (id: 'S4', request: '겨울 아우터 뭐 있는지 보고 가장 추운 날 입을 것 골라줘', cancel: false, userAnswer: '일상이에요'),
  (id: 'S5', request: '다음 주 수요일 면접 일정 넣어줘', cancel: false, userAnswer: '네'),
  (id: 'S6', request: '옷 좀 준비해줘', cancel: false, userAnswer: '금요일 저녁 모임이에요'),
  (id: 'S7', request: '오늘 저녁 메뉴 추천해줘', cancel: false, userAnswer: '네'),
  (id: 'S8', request: '내일 데이트 일정 있어? 있으면 그 코디 알려줘', cancel: false, userAnswer: '네'),
  (id: 'S9', request: '금요일 저녁 모임에 입을 옷 준비해줘', cancel: true, userAnswer: '네, 그렇게 해 주세요'),
];

// 고정 7일 예보 — 내일(11/17) 비, 11/21(토)이 가장 춥다.
const _forecast = [
  (14.0, 6.0, 10),
  (9.0, 2.0, 70),
  (12.0, 5.0, 20),
  (16.0, 8.0, 0),
  (13.0, 5.0, 30),
  (2.0, -5.0, 10),
  (11.0, 3.0, 0),
];

class _ProbeData implements AskDataSource {
  final List<WardrobeItem> items;
  final List<OutfitCalendarEntry> entries;
  final List<RecommendationEntry> recs;
  final AskTools Function() toolsForPreview;
  _ProbeData(this.items, this.entries, this.recs, this.toolsForPreview);

  @override
  Future<List<OutfitCalendarEntry>> calendar(DateTime from, DateTime to) async =>
      entries.where((e) => !e.date.isBefore(from) && !e.date.isAfter(to)).toList();
  @override
  Future<List<RecommendationEntry>> recommendations(DateTime from, DateTime to) async => recs;
  @override
  Future<WeatherSnapshot?> weather() async => WeatherSnapshot(
        current: const CurrentWeather(tempC: 10, weatherCode: 3),
        daily: [
          for (var i = 0; i < _forecast.length; i++)
            DailyWeather(
                date: _today.add(Duration(days: i)),
                maxTempC: _forecast[i].$1,
                minTempC: _forecast[i].$2,
                precipitationProbability: _forecast[i].$3),
        ],
      );
  @override
  Future<List<WardrobeItem>> wardrobe() async => items;
  @override
  Future<Set<String>> recentItemIds() async => const {};
  // 쓰기 흉내 — 미리 보기 1순위 조합을 82점으로 "저장"한 것처럼 돌려준다(실제로 저장하지 않음).
  @override
  Future<AskPlanWrite> addPlan(DateTime date, String tpo, {required bool prepare}) async {
    if (!prepare) return const AskPlanWrite(prepared: false);
    final preview = await toolsForPreview().previewOutfit({'date': askDateKey(date), 'tpo': tpo});
    final note = RegExp(r'날씨: (.*)').firstMatch(preview.observation)?.group(1);
    return AskPlanWrite(
      prepared: preview.ok,
      recommendation: preview.ok
          ? RecommendationEntry(
              id: 'probe',
              itemIds: [for (final i in preview.items) i.id],
              itemSummaries: const [],
              summaryText: '',
              triggerItemId: '',
              createdAt: _today,
              colorScore: 82,
              targetDate: date,
              targetTpoTag: tpo,
              weatherNote: note)
          : null,
    );
  }
}

List<WardrobeItem> _loadDemo() {
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

void main() {
  test('프로브 T6 입력 덤프(ASK_PROBE_DUMP=1일 때만)', () async {
    if (Platform.environment['ASK_PROBE_DUMP'] != '1') {
      markTestSkipped('ASK_PROBE_DUMP=1 일 때만 파일을 쓴다');
      return;
    }
    final wardrobe = _loadDemo();
    final tomorrow = _today.add(const Duration(days: 1));
    late AskTools tools;
    // 내일 [데이트] 예정 + 준비된 추천(S8), 목요일 [출근] 예정·추천 없음, 지난 토요일 기록.
    final baseData = _ProbeData(wardrobe, [], [], () => tools);
    tools = AskTools(baseData, now: () => DateTime(2026, 11, 16, 10));
    final datePreview = await tools.previewOutfit({'date': askDateKey(tomorrow), 'tpo': '데이트'});
    final entries = [
      OutfitCalendarEntry(id: 'c1', date: tomorrow, tpoTag: '데이트', status: 'planned', createdAt: _today),
      OutfitCalendarEntry(
          id: 'c2', date: _today.add(const Duration(days: 3)), tpoTag: '출근', status: 'planned', createdAt: _today),
      OutfitCalendarEntry(
          id: 'c3',
          date: _today.subtract(const Duration(days: 2)),
          tpoTag: '일상',
          status: 'recorded',
          itemIds: [wardrobe.first.id],
          createdAt: _today),
    ];
    final recs = [
      RecommendationEntry(
          id: 'r1',
          itemIds: [for (final i in datePreview.items) i.id],
          itemSummaries: const [],
          summaryText: '',
          triggerItemId: '',
          createdAt: _today,
          colorScore: 84,
          targetDate: tomorrow,
          targetTpoTag: '데이트',
          weatherNote: RegExp(r'날씨: (.*)').firstMatch(datePreview.observation)?.group(1)),
    ];
    final data = _ProbeData(wardrobe, entries, recs, () => tools);
    tools = AskTools(data, now: () => DateTime(2026, 11, 16, 10));

    String k(DateTime d) => askDateKey(d);
    final calendar = <String, Map<String, dynamic>>{};
    final weather = <String, Map<String, dynamic>>{};
    for (var f = 0; f < 14; f++) {
      for (var len = 0; len < askMaxRangeDays; len++) {
        final from = _today.add(Duration(days: f));
        final to = from.add(Duration(days: len));
        final args = {'from': k(from), 'to': k(to)};
        final c = await tools.getCalendar(args);
        final w = await tools.getWeather(args);
        calendar['${k(from)}|${k(to)}'] = {'observation': c.observation, 'ok': c.ok};
        weather['${k(from)}|${k(to)}'] = {'observation': w.observation, 'ok': w.ok};
      }
    }
    final preview = <String, Map<String, dynamic>>{};
    final plan = <String, Map<String, dynamic>>{};
    for (var d = -7; d <= 70; d++) {
      final date = _today.add(Duration(days: d));
      for (final t in TpoTags.all) {
        final args = {'date': k(date), 'tpo': t.label};
        if (d >= -7 && d <= 30) {
          final p = await tools.previewOutfit(args);
          preview['${k(date)}|${t.label}'] = {'observation': p.observation, 'ok': p.ok};
        }
        final invalid = tools.validatePlan(args);
        final r = invalid == null ? await tools.addPlan(args) : null;
        plan['${k(date)}|${t.label}'] = {
          'invalid': invalid,
          if (r != null) 'observation': r.observation,
          if (r != null) 'ok': r.ok,
        };
      }
    }
    // search_wardrobe는 키워드가 자유라 표 대신 프로브가 같은 규칙으로 계산한다 — 대조용 표본.
    final searchSamples = <Map<String, dynamic>>[];
    for (final c in [null, ...askCategories]) {
      for (final kw in [null, '겨울', '아우터', '패딩', '코트', '니트', '가을겨울', '후드', '반팔', '블레이저', '울', '퀼팅안감', '블랙', '비', '봄', '퀼팅', '스웨이드']) {
        final args = {if (c != null) 'category': c, if (kw != null) 'keyword': kw};
        final r = await tools.searchWardrobe(args);
        searchSamples.add({'args': args, 'observation': r.observation, 'ok': r.ok});
      }
    }
    // 프롬프트 재구성 대조용 — Dart가 만든 단계 프롬프트.
    final checkSteps = [
      AskStep(
          thought: '금요일 예보부터 볼게요',
          action: 'get_weather',
          args: {'from': '2026-11-20', 'to': '2026-11-20'},
          observation: weather['2026-11-20|2026-11-20']!['observation'] as String),
      AskStep(
          thought: '모임 코디를 미리 볼게요',
          action: 'preview_outfit',
          args: {'date': '2026-11-20', 'tpo': '모임'},
          observation: preview['2026-11-20|모임']!['observation'] as String),
    ];
    File(_out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
      'generatedAt': DateTime.now().toIso8601String(),
      'today': k(_today),
      'generationConfig': GeminiService.agentStepGenerationConfig,
      'maxModelCalls': askMaxModelCalls,
      'stepTimeoutSecs': askStepTimeout.inSeconds,
      'totalTimeoutSecs': askTotalTimeout.inSeconds,
      'promptMaxChars': askPromptMaxChars,
      'actions': askActions,
      'tpos': [for (final t in TpoTags.all) t.label],
      'categories': askCategories,
      'coldestDate': '2026-11-21',
      'scenarios': [
        for (final s in _scenarios)
          {
            'id': s.id,
            'request': s.request,
            'cancel': s.cancel,
            'userAnswer': s.userAnswer,
            'firstPrompt': buildAskPrompt(request: s.request, steps: const [], today: _today),
          },
      ],
      'remainingNoticeAfter': askRemainingNoticeAfter,
      'maxWardrobeSearches': askMaxWardrobeSearches,
      'wardrobeSearchLimitMessage': askWardrobeSearchLimitMessage,
      'seasonTags': askSeasonTags.toList(),
      'heavyTags': heavyOuterTags.toList(),
      'summaryTagMin': askSummaryTagMin,
      'summaryTagMax': askSummaryTagMax,
      'winterListMax': askWinterListMax,
      // 두 번째는 네 번 부른 뒤의 요청(단계 기록 끝에 "남은 호출 2회").
      'promptChecks': [
        for (final (steps, left) in [(checkSteps, null), ([...checkSteps, ...checkSteps], 2)])
          {
            'request': _scenarios.first.request,
            'remainingCalls': left,
            'steps': [
              for (final s in steps) {'thought': s.thought, 'action': s.action, 'args': s.args, 'observation': s.observation},
            ],
            'prompt': buildAskPrompt(request: _scenarios.first.request, steps: steps, today: _today, remainingCalls: left),
          },
      ],
      'wardrobe': [
        for (final i in wardrobe)
          {
            'id': i.id, // 고정 자료의 순번 id(demoNNN) — 실제 문서 id 아님
            'category': i.category,
            'subCategory': i.subCategory,
            'createdAt': i.createdAt.toIso8601String(),
            'attributes': i.attributes!.toFirestore(),
          },
      ],
      'calendar': calendar,
      'weather': weather,
      'preview': preview,
      'plan': plan,
      'searchSamples': searchSamples,
    }));
    expect(calendar.length, 14 * askMaxRangeDays);
  });
}
