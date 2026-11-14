// AI에게 부탁하기 — 도구 계층(docs/task_agent_ask_v1.md §2-2·§2-3).
//
// 모델은 매 단계 JSON 하나로 "다음에 쓸 도구"를 말하고(§2-1), 앱이 여기 함수로 그 도구를
// 직접 실행해 결과(관찰)를 다음 요청의 글에 붙인다. 서버의 도구 호출 차단
// (functions/src/request_shape.ts)은 그대로 둔다. 모델 출력은 아래 함수의 인자로만
// 쓰이고, 인자는 실행 전에 검증한다(날짜 YYYY-MM-DD, 상황 태그 9개, 카테고리 5개).
//
// 모두 로그인한 사용자 본인의 데이터만 다룬다(AskDataSource). 읽기 도구는 저장하지 않고,
// 쓰기는 add_plan 하나뿐이며 엔진이 사용자 확인을 받은 뒤에만 부른다. 도구가 실패해도
// (예보 조회 실패, 옷장이 비어 있음 등) 예외를 올리지 않고 실패 사실을 관찰로 돌려준다.
import '../constants/tpo_tags.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/wardrobe_item.dart';
import 'agent_planner.dart';
import 'weather_fit.dart';
import 'weather_service.dart';

// 관찰 한 건의 글자 상한(§2-1).
const askObservationMaxChars = 1500;
// get_calendar·get_weather 조회 기간 상한(§2-2).
const askMaxRangeDays = 14;
// add_plan 날짜 범위 — 오늘부터 60일 안(§2-3).
const askPlanMaxDaysAhead = 60;
// 예보 범위 — 오늘 포함 7일(WeatherService, forecast_days 7).
const askForecastDays = 7;
const askCategories = ['상의', '하의', '아우터', '신발', '액세서리'];

// 사용자 본인의 데이터 — 앱은 FirestoreAskDataSource, 테스트는 가짜.
abstract class AskDataSource {
  Future<List<OutfitCalendarEntry>> calendar(DateTime from, DateTime to);
  Future<List<RecommendationEntry>> recommendations(DateTime from, DateTime to);
  Future<WeatherSnapshot?> weather();
  Future<List<WardrobeItem>> wardrobe();
  Future<Set<String>> recentItemIds();
  // 쓰기 — 예정 일정 등록 + 기존 준비 경로로 코디 준비. prepare가 false면 등록만.
  Future<AskPlanWrite> addPlan(DateTime date, String tpo, {required bool prepare});
}

class AskPlanWrite {
  final bool prepared; // 코디를 준비했는가(추천 저장)
  final RecommendationEntry? recommendation;
  const AskPlanWrite({required this.prepared, this.recommendation});
}

// 도구 결과 — 관찰 글(모델에 붙임)과 화면용 옷(마지막 답 카드의 사진).
class AskToolResult {
  final String observation;
  final List<WardrobeItem> items;
  final bool ok;
  // add_plan이 실제로 쓴 경우만 — 확인 카드·캘린더 이동용.
  final DateTime? plannedDate;
  const AskToolResult(this.observation, {this.items = const [], this.ok = true, this.plannedDate});
}

// ── 인자 검증(순수) ────────────────────────────────────────────────
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime? parseAskDate(Object? v) {
  if (v is! String || !_datePattern.hasMatch(v)) return null;
  final d = DateTime.tryParse(v);
  if (d == null) return null;
  // 2026-02-30 같은 값은 DateTime이 넘겨 버리므로 되돌려 같은지 본다.
  if (askDateKey(d) != v) return null;
  return DateTime(d.year, d.month, d.day);
}

String askDateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];
String askDateLabel(DateTime d) => '${askDateKey(d)}(${_weekdays[d.weekday - 1]})';

bool isAskTpo(Object? v) => v is String && TpoTags.all.any((t) => t.label == v);
bool isAskCategory(Object? v) => v is String && askCategories.contains(v);

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

String _clip(String s) =>
    s.length <= askObservationMaxChars ? s : '${s.substring(0, askObservationMaxChars - 12)}… (이하 생략)';

String _itemLine(WardrobeItem i) {
  final a = i.attributes;
  final kind = i.category == '액세서리' ? (i.subCategory ?? '액세서리') : i.category;
  if (a == null) return '$kind(속성 없음)';
  return '$kind ${a.color} ${a.tags.take(3).join('·')}(${a.formality})';
}

String _bandLabel(TempBand b) => switch (b) {
      TempBand.hot => '더움',
      TempBand.mild => '온화',
      TempBand.cool => '선선',
      TempBand.cold => '추움',
    };

// 기간 인자 검증 — 오류면 관찰 글, 맞으면 null.
String? _rangeError(DateTime? from, DateTime? to) {
  if (from == null || to == null) return '인자 오류: from·to는 YYYY-MM-DD 형식이어야 해요';
  if (to.isBefore(from)) return '인자 오류: to가 from보다 앞이에요';
  if (to.difference(from).inDays + 1 > askMaxRangeDays) return '인자 오류: 기간은 최대 $askMaxRangeDays일이에요';
  return null;
}

// ── 도구 ────────────────────────────────────────────────────────────
class AskTools {
  final AskDataSource data;
  final DateTime Function() now;
  AskTools(this.data, {DateTime Function()? now}) : now = now ?? DateTime.now;

  DateTime get today => _midnight(now());

  // get_calendar(from, to) — 날짜별 일정(상황, 예정/기록)과 그 날짜에 준비된 추천 요약.
  Future<AskToolResult> getCalendar(Map<String, dynamic> args) async {
    final from = parseAskDate(args['from']);
    final to = parseAskDate(args['to']);
    final err = _rangeError(from, to);
    if (err != null) return AskToolResult(err, ok: false);
    try {
      final entries = await data.calendar(from!, to!);
      final recs = (await data.recommendations(from, to)).where((r) => !r.dismissed && r.targetDate != null);
      final wardrobe = {for (final i in await data.wardrobe()) i.id: i};
      if (entries.isEmpty) return AskToolResult('${askDateKey(from)}~${askDateKey(to)} 일정 없음');
      final lines = <String>[];
      final items = <WardrobeItem>[];
      for (final e in entries..sort((a, b) => a.date.compareTo(b.date))) {
        final state = e.isPlanned ? '예정' : '기록';
        final rec = recs
            .where((r) => _midnight(r.targetDate!) == _midnight(e.date) && r.targetTpoTag == e.tpoTag)
            .firstOrNull;
        String recText;
        if (!e.isPlanned) {
          recText = '착장 기록됨';
        } else if (rec == null) {
          recText = '준비된 추천 없음';
        } else {
          final recItems = rec.itemIds.map((id) => wardrobe[id]).whereType<WardrobeItem>().toList();
          items.addAll(recItems);
          recText = '준비된 추천: ${recItems.map(_itemLine).join(', ')}'
              '${rec.colorScore != null ? ' · ${rec.colorScore}점' : ''}'
              '${rec.weatherNote != null ? ' · ${rec.weatherNote}' : ''}';
        }
        lines.add('${askDateLabel(e.date)} [${e.tpoTag}] $state — $recText');
      }
      return AskToolResult(_clip(lines.join('\n')), items: items);
    } catch (e) {
      return AskToolResult('일정을 불러오지 못했어요: $e', ok: false);
    }
  }

  // get_weather(from, to) — 날짜별 최고·최저·강수확률, 기온대, 비 여부. 7일 밖은 예보 범위 밖.
  Future<AskToolResult> getWeather(Map<String, dynamic> args) async {
    final from = parseAskDate(args['from']);
    final to = parseAskDate(args['to']);
    final err = _rangeError(from, to);
    if (err != null) return AskToolResult(err, ok: false);
    final snapshot = await _safeWeather();
    if (snapshot == null) return const AskToolResult('예보를 불러오지 못했어요', ok: false);
    final lines = <String>[];
    for (var d = from!; !d.isAfter(to!); d = d.add(const Duration(days: 1))) {
      final w = snapshot.forDate(d);
      if (w == null) {
        lines.add('${askDateLabel(d)}: 예보 범위 밖(오늘 포함 $askForecastDays일까지)');
        continue;
      }
      final ctx = weatherContextFor(w)!;
      lines.add('${askDateLabel(d)}: 최고 ${w.maxTempC.round()}°C 최저 ${w.minTempC.round()}°C '
          '강수 ${w.precipitationProbability}% · ${_bandLabel(ctx.band)}${ctx.rain ? ' · 비' : ''}');
    }
    if (snapshot.isAssumed) lines.add('(테스트용 가정 예보)');
    return AskToolResult(_clip(lines.join('\n')));
  }

  // search_wardrobe(category?, keyword?) — 인자가 없으면 종류별 벌수, 있으면 일치 벌수와 최대 8벌.
  Future<AskToolResult> searchWardrobe(Map<String, dynamic> args) async {
    final category = args['category'];
    final keyword = args['keyword'];
    if (category != null && !isAskCategory(category)) {
      return AskToolResult('인자 오류: category는 ${askCategories.join('·')} 중 하나예요', ok: false);
    }
    if (keyword != null && (keyword is! String || keyword.trim().isEmpty)) {
      return const AskToolResult('인자 오류: keyword는 비어 있지 않은 글자여야 해요', ok: false);
    }
    final List<WardrobeItem> wardrobe;
    try {
      wardrobe = (await data.wardrobe()).where((i) => i.attributes != null).toList();
    } catch (e) {
      return AskToolResult('옷장을 불러오지 못했어요: $e', ok: false);
    }
    if (wardrobe.isEmpty) return const AskToolResult('옷장이 비어 있어요', ok: false);
    if (category == null && keyword == null) {
      final counts = <String, int>{};
      for (final i in wardrobe) {
        counts[i.category] = (counts[i.category] ?? 0) + 1;
      }
      return AskToolResult('옷장 ${wardrobe.length}벌 — '
          '${[for (final c in askCategories) if (counts[c] != null) '$c ${counts[c]}'].join(', ')}');
    }
    final kw = (keyword as String?)?.trim();
    bool matches(WardrobeItem i) {
      if (category != null && i.category != category) return false;
      if (kw == null) return true;
      final a = i.attributes!;
      return [i.category, i.subCategory ?? '', a.color, a.style, a.formality, ...a.tags].any((t) => t.contains(kw));
    }
    final hits = wardrobe.where(matches).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (hits.isEmpty) return AskToolResult('일치하는 옷 없음(${category ?? '전체'}${kw != null ? ', "$kw"' : ''})');
    final shown = hits.take(8).toList();
    return AskToolResult(
      _clip('일치 ${hits.length}벌${hits.length > 8 ? '(앞 8벌)' : ''}:\n'
          '${[for (var i = 0; i < shown.length; i++) '${i + 1}. ${_itemLine(shown[i])}'].join('\n')}'),
      items: shown,
    );
  }

  // preview_outfit(date, tpo) — 일일 추천과 같은 matchForWeather 1순위. 모델 호출 없음, 저장 없음.
  Future<AskToolResult> previewOutfit(Map<String, dynamic> args) async {
    final date = parseAskDate(args['date']);
    final tpo = args['tpo'];
    if (date == null) return const AskToolResult('인자 오류: date는 YYYY-MM-DD 형식이어야 해요', ok: false);
    if (!isAskTpo(tpo)) {
      return AskToolResult('인자 오류: tpo는 ${TpoTags.all.map((t) => t.label).join('·')} 중 하나예요', ok: false);
    }
    final List<WardrobeItem> wardrobe;
    try {
      wardrobe = (await data.wardrobe()).where((i) => i.attributes != null).toList();
    } catch (e) {
      return AskToolResult('옷장을 불러오지 못했어요: $e', ok: false);
    }
    if (wardrobe.length < 2) return const AskToolResult('옷장에 옷이 부족해 조합을 만들 수 없어요', ok: false);
    final snapshot = await _safeWeather();
    final day = snapshot?.forDate(date);
    final formality = TpoTags.byLabel(tpo as String).formalityHint;
    final recent = await _safeRecent();
    final m = AgentPlanner.matchForWeather(
        wardrobe: wardrobe, formalityHint: formality, recentItemIds: recent, day: day);
    if (m.match.candidates.isEmpty) {
      return AskToolResult('조합을 만들지 못했어요 — ${m.match.shortfall ?? '옷장이 부족해요'}', ok: false);
    }
    final top = m.match.candidates.first.items;
    final note = day == null
        ? null
        : buildWeatherNote(
            ctx: weatherContextFor(day),
            baselineTop: m.baseline!.candidates.first.items,
            weatherTop: top,
            finalItems: top,
            wardrobe: wardrobe,
            removedIds: (m.fellBack || m.formalityOverride) ? const {} : m.filter!.removedIds,
            isAssumed: snapshot!.isAssumed,
            formalityHint: formality,
            coldOuterRuleApplied: !m.fellBack && !m.formalityOverride && m.filter!.coldOuterRuleApplied,
          );
    final weatherText = day == null
        ? (snapshot == null ? '예보를 불러오지 못해 날씨 없이 골랐어요' : '예보 범위 밖이라 날씨 없이 골랐어요')
        : note!;
    return AskToolResult(
      _clip('${askDateLabel(date)} [$tpo] 미리 보기(저장 안 함): ${top.map(_itemLine).join(', ')}\n'
          '날씨: $weatherText\n격식 차선: ${m.match.isFallback ? '예 — 일정 격식에 딱 맞는 조합이 없어요' : '아니요'}'),
      items: top,
    );
  }

  // add_plan 인자·날짜 검증(쓰기 전, 확인 카드 전에 부른다) — 오류면 관찰 글, 맞으면 null.
  String? validatePlan(Map<String, dynamic> args) {
    final date = parseAskDate(args['date']);
    if (date == null) return '인자 오류: date는 YYYY-MM-DD 형식이어야 해요';
    if (!isAskTpo(args['tpo'])) return '인자 오류: tpo는 ${TpoTags.all.map((t) => t.label).join('·')} 중 하나예요';
    if (date.isBefore(today)) return '지난 날짜(${askDateLabel(date)})에는 일정을 넣을 수 없어요';
    if (date.difference(today).inDays > askPlanMaxDaysAhead) {
      return '오늘부터 $askPlanMaxDaysAhead일 안의 날짜만 넣을 수 있어요(${askDateLabel(date)})';
    }
    return null;
  }

  // add_plan(date, tpo) — 쓰기. 엔진이 사용자 확인을 받은 뒤에만 부른다(§2-3).
  Future<AskToolResult> addPlan(Map<String, dynamic> args) async {
    final err = validatePlan(args);
    if (err != null) return AskToolResult(err, ok: false);
    final date = parseAskDate(args['date'])!;
    final tpo = args['tpo'] as String;
    try {
      final sameDay = await data.calendar(date, date);
      final planned = sameDay.where((e) => e.isPlanned).firstOrNull;
      if (planned != null) {
        return AskToolResult('${askDateLabel(date)}에는 이미 [${planned.tpoTag}] 예정 일정이 있어 새로 넣지 않았어요',
            ok: false);
      }
      // 예보 범위(오늘 포함 7일) 안이면 바로 준비, 밖이면 등록만.
      final inForecast = date.difference(today).inDays < askForecastDays;
      final w = await data.addPlan(date, tpo, prepare: inForecast);
      if (!inForecast) {
        return AskToolResult('${askDateLabel(date)} [$tpo] 일정을 등록했어요. 코디는 일정이 가까워지면 예보를 보고 준비해요',
            plannedDate: date);
      }
      final rec = w.recommendation;
      if (!w.prepared || rec == null) {
        return AskToolResult('${askDateLabel(date)} [$tpo] 일정을 등록했어요. 코디는 준비하지 못했어요 — 옷장에 맞는 조합이 없거나 평가에 실패했어요',
            plannedDate: date);
      }
      final wardrobe = {for (final i in await data.wardrobe()) i.id: i};
      final recItems = rec.itemIds.map((id) => wardrobe[id]).whereType<WardrobeItem>().toList();
      return AskToolResult(
        _clip('${askDateLabel(date)} [$tpo] 일정을 등록하고 코디를 준비했어요: ${recItems.map(_itemLine).join(', ')}'
            '${rec.colorScore != null ? ' · ${rec.colorScore}점' : ''}'
            '${rec.weatherNote != null ? '\n날씨: ${rec.weatherNote}' : ''}'),
        items: recItems,
        plannedDate: date,
      );
    } catch (e) {
      return AskToolResult('일정을 등록하지 못했어요: $e', ok: false);
    }
  }

  Future<WeatherSnapshot?> _safeWeather() async {
    try {
      return await data.weather();
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> _safeRecent() async {
    try {
      return await data.recentItemIds();
    } catch (_) {
      return const {};
    }
  }
}
