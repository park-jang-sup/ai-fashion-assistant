// 텍스트 모델 프로브 입력 ② — 앱의 프롬프트 빌더 출력을 그대로 내보낸다.
// docs/task_text_model_v1.md §3-1: 프로브(tools/text_probe/probe.mjs)는 프롬프트를
// 다시 쓰지 않고, 이 테스트가 만든 input/prompts.json의 문자열을 그대로 보낸다.
//
// 평소 `flutter test`에서는 아무 파일도 쓰지 않는다(건너뜀). 덤프는:
//   TEXT_PROBE_DUMP=1 flutter test test/text_probe_dump_test.dart
// 입력: tools/text_probe/input/items.json(fetch_items.py가 만든 것).
import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:ai_fashion_assistant/services/style_recommendations.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _itemsPath = 'tools/text_probe/input/items.json';
const _outPath = 'tools/text_probe/input/prompts.json';
const _labelingImages = 'tools/eval_harness_selfeval/labeling_material/images';

// 과제 입력 — 결과를 보기 전에 고정(docs/task_text_model_v1.md §3-3).
const _t2Count = 20; // 55장 중 itemId 오름차순 앞 20장
const _t3CatalogCount = 30; // 55벌 중 itemId 오름차순 앞 30벌
// T3 일정: 2026-11-16(월)부터 7일, TPO와 예보를 고정한다. 예보는 실제 조회가
// 아니라 고정값이다 — 비 예보 1일·추운 날 1일을 넣어 날씨 제약 문구를 포함시킨다.
const _t3Start = (2026, 11, 16);
const _t3Tpos = ['출근', '출근', '일상', '데이트', '출근', '모임', '일상'];
const _t3Forecast = [
  (max: 14.0, min: 6.0, rain: 10),
  (max: 13.0, min: 5.0, rain: 70),
  (max: 12.0, min: 4.0, rain: 20),
  (max: 15.0, min: 7.0, rain: 0),
  (max: 11.0, min: 3.0, rain: 30),
  (max: 13.0, min: 6.0, rain: 10),
  (max: 14.0, min: 7.0, rain: 0),
];
// T4 조합(전신 사진 + 조합 3개) — 가상 피팅 프로브의 set4_7벌 슬롯 이름.
const _t4Combos = [
  ['top', 'bottom', 'shoes'],
  ['top', 'bottom', 'outer', 'shoes'],
  ['top', 'bottom', 'outer', 'shoes', 'hat', 'bag', 'watch'],
];

// T5 조합 — 결과를 보기 전에 고정(docs/task_agent_grounding_v1.md §3-4). c3은 c1과 같은
// 옷이지만 옷장을 비워 후보 0개인 경우를 만든다.
const _t5Combos = [
  (id: 'c1', slots: ['top', 'bottom', 'shoes'], emptyWardrobe: false),
  (id: 'c2', slots: ['top', 'bottom', 'outer', 'shoes'], emptyWardrobe: false),
  (id: 'c3', slots: ['top', 'bottom', 'shoes'], emptyWardrobe: true),
];

void main() {
  test('텍스트 프로브 프롬프트 덤프(TEXT_PROBE_DUMP=1일 때만)', () {
    if (Platform.environment['TEXT_PROBE_DUMP'] != '1') {
      markTestSkipped('TEXT_PROBE_DUMP=1 일 때만 파일을 쓴다');
      return;
    }
    final input = jsonDecode(File(_itemsPath).readAsStringSync()) as Map<String, dynamic>;
    final items = (input['items'] as Map<String, dynamic>).cast<String, Map<String, dynamic>>();
    ClothingAttributes attrsOf(String id) =>
        ClothingAttributes.fromJson(items[id]!['attributes'] as Map<String, dynamic>);
    String categoryOf(String id) => items[id]!['category'] as String;
    List<({String category, ClothingAttributes attributes})> combo(List<String> ids) =>
        [for (final id in ids) (category: categoryOf(id), attributes: attrsOf(id))];

    // T1 자기평가 — 8월 쌍 생성과 같은 진입점의 프롬프트(사진·프로필·이력 없음).
    final t1 = [
      for (final c in (input['t1Combos'] as List).cast<Map<String, dynamic>>())
        {
          'pairId': c['pairId'],
          'side': c['side'],
          'itemIds': c['itemIds'],
          'augustScore': c['augustScore'],
          'prompt': GeminiService.attributeAnalysisPromptForTest(
              combo((c['itemIds'] as List).cast<String>())),
        },
    ];

    // T2 속성 추출 — 한국어 강제 한 줄이 들어간 현재 프롬프트.
    final evalIds = (input['evalItemIds'] as List).cast<String>()..sort();
    final t2 = [
      for (final id in evalIds.take(_t2Count))
        {
          'itemId': id,
          'category': categoryOf(id),
          // pairs_blind.json은 .png로 적고 있지만 실제 파일은 .jpg다 — 있는 쪽을 쓴다.
          'imageFile': ['jpg', 'png']
              .map((ext) => '$_labelingImages/$id.$ext')
              .firstWhere((p) => File(p).existsSync()),
          'prompt': GeminiService.attributeExtractionPromptForTest(categoryOf(id)),
        },
    ];

    // T3 주간 플랜 — 앱과 같은 줄 빌더로 고정 입력을 만든다.
    final catalogIds = evalIds.take(_t3CatalogCount).toList();
    final catalog = catalogIds
        .map((id) => AgentPlanner.weeklyCatalogLine(WardrobeItem(
              id: id,
              imageUrl: '',
              category: categoryOf(id),
              createdAt: DateTime(2026),
              attributes: attrsOf(id),
            )))
        .join('\n');
    final start = DateTime(_t3Start.$1, _t3Start.$2, _t3Start.$3);
    final scheduleLines = <String>[];
    final dates = <String>[];
    for (var i = 0; i < _t3Tpos.length; i++) {
      final d = start.add(Duration(days: i));
      final f = _t3Forecast[i];
      scheduleLines.add(AgentPlanner.weeklyScheduleLine(
        index: i,
        date: d,
        tpo: _t3Tpos[i],
        weather: DailyWeather(date: d, maxTempC: f.max, minTempC: f.min, precipitationProbability: f.rain),
      ));
      dates.add('${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
    final t3 = {
      'catalogIds': catalogIds,
      'dates': dates,
      'categories': {for (final id in catalogIds) id: categoryOf(id)},
      'prompt': GeminiService.buildWeeklyPlanPrompt(
        scheduleLines: scheduleLines.join('\n'),
        wardrobeCatalog: catalog,
      ),
    };

    // T4 스트리밍 분석 — 전신 사진이 있는 경로의 프롬프트.
    final fittingSet = (input['fittingSet'] as Map<String, dynamic>).cast<String, String>();
    final t4 = [
      for (final slots in _t4Combos)
        {
          'slots': slots,
          'itemIds': [for (final s in slots) fittingSet[s]],
          'prompt': GeminiService.attributeAnalysisPromptWithPhotoForTest(
              combo([for (final s in slots) fittingSet[s]!])),
        },
    ];

    // T5 옷장 후보가 들어간 분석(docs/task_agent_grounding_v1.md §3-4) — 앱과 같은
    // 로직(matchStyleCandidates)으로 실제 옷장 전체에서 후보를 뽑아 사진용 프롬프트에
    // 넣는다. c3은 옷장을 비운 입력이라 후보 0개(= 변경 전 프롬프트).
    WardrobeItem asItem(Map<String, dynamic> w) => WardrobeItem(
          id: w['id'] as String,
          imageUrl: '',
          category: w['category'] as String,
          subCategory: w['subCategory'] as String?,
          createdAt: DateTime(2026),
          attributes: ClothingAttributes.fromJson(w['attributes'] as Map<String, dynamic>),
        );
    final wardrobe = [
      for (final w in (input['wardrobe'] as List? ?? const []).cast<Map<String, dynamic>>()) asItem(w),
    ];
    WardrobeItem fittingItem(String slot) =>
        asItem({...items[fittingSet[slot]!]!, 'id': fittingSet[slot]});
    final t5 = [
      for (final c in _t5Combos)
        () {
          final selected = [for (final s in c.slots) fittingItem(s)];
          final candidates = matchStyleCandidates(
              selected: selected,
              wardrobe: c.emptyWardrobe ? const [] : wardrobe,
              maxItems: analysisCandidateCount);
          final lines = candidatePromptLines(candidates, selected);
          return {
            'id': c.id,
            'slots': c.slots,
            'emptyWardrobe': c.emptyWardrobe,
            'candidates': [
              for (var i = 0; i < candidates.length; i++)
                {
                  'id': candidates[i].item.id,
                  'line': candidatePromptLine(i, candidates[i].item, selected),
                },
            ],
            'prompt': GeminiService.analysisPromptsForGoldenTest(
              [for (final s in selected) (category: s.category, attributes: s.attributes!)],
              kind: 'photo',
              candidateLines: lines.isEmpty ? null : lines,
            ),
          };
        }(),
    ];

    File(_outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'generatedAt': DateTime.now().toIso8601String(),
      'generationConfig': {
        'attributeExtraction': GeminiService.attributeExtractionGenerationConfig,
        'outfitAnalysis': GeminiService.outfitAnalysisGenerationConfig,
        'weeklyPlan': GeminiService.weeklyPlanGenerationConfig,
      },
      't1': t1,
      't2': t2,
      't3': t3,
      't4': t4,
      't5': t5,
    }));
    expect(t1.length, 30);
    expect(t2.length, _t2Count);
    expect(t4.length, 3);
  });
}
