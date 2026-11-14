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
import 'dart:typed_data';

import '../constants/tpo_tags.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/user_profile.dart';
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
// category만 준 search_wardrobe의 요약(프로브 T6 run3) — 계절·두께 태그. 한겨울용은 weather_fit의
// heavyOuterTags 그대로.
const askSeasonTags = {
  '봄', '여름', '가을', '겨울', '봄가을', '간절기', '가을/겨울', '가을겨울', '사계절', '여름아우터', '양털안감', '퀼팅안감',
};
// get_wardrobe_profile(v2 §2-B-2) — 옷 한 벌의 계절 구분(weather_fit의 태그 묶음을 그대로 쓴다).
const askSeasonBuckets = ['여름', '간절기', '가을·겨울', '한겨울용'];
const askFormalities = ['캐주얼', '세미포멀', '포멀'];
const askProfileMinFit = 3;

String askSeasonOf(WardrobeItem i) {
  if (isHeavyOuter(i)) return '한겨울용';
  if (isSummerItem(i)) return '여름';
  final tags = i.attributes?.tags.map((t) => t.trim()) ?? const <String>[];
  if (tags.any((t) => weatherHotAvoidTags.contains(t) || t == '가을')) return '가을·겨울';
  return '간절기';
}

// 지금 기온대에 맞는가 — 기온대 감점 대상이 아니고, 추움(선선은 상의 밖)에서 여름 계열이 아니다.
bool askFitsBand(WardrobeItem i, WeatherContext ctx) {
  if (bandAvoidReason(i, ctx) != null) return false;
  final summerOut = ctx.band == TempBand.cold || (ctx.band == TempBand.cool && i.category != '상의');
  return !(summerOut && isSummerItem(i));
}

const askSummaryTagMin = 2; // 종류·소재 태그는 2벌 이상인 것만
const askSummaryTagMax = 12;
const askWinterListMax = 8;

// 사용자 본인의 데이터 — 앱은 FirestoreAskDataSource, 테스트는 가짜.
abstract class AskDataSource {
  Future<List<OutfitCalendarEntry>> calendar(DateTime from, DateTime to);
  Future<List<RecommendationEntry>> recommendations(DateTime from, DateTime to);
  Future<WeatherSnapshot?> weather();
  Future<List<WardrobeItem>> wardrobe();
  Future<Set<String>> recentItemIds();
  // 사용자 프로필(키·체형·퍼스널 컬러·선호 스타일) — 없으면 null.
  Future<UserProfile?> profile();
  // 쓰기 — 예정 일정 등록 + 기존 준비 경로로 코디 준비. prepare가 false면 등록만.
  Future<AskPlanWrite> addPlan(DateTime date, String tpo, {required bool prepare});
}

class AskPlanWrite {
  final bool prepared; // 코디를 준비했는가(추천 저장)
  final RecommendationEntry? recommendation;
  const AskPlanWrite({required this.prepared, this.recommendation});
}

// 도구 결과 — 관찰 글(모델에 붙임), 화면용 한 줄(화면·대화 내역·활동 내역, v2 §2-B-1),
// 화면용 옷(마지막 답 카드의 사진).
class AskToolResult {
  final String observation;
  final String? display;
  final List<WardrobeItem> items;
  // preview_outfit이 여러 조합을 낸 경우 전부(첫 조합이 items).
  final List<List<WardrobeItem>> combos;
  final bool ok;
  // add_plan이 실제로 쓴 경우만 — 확인 카드·캘린더 이동용.
  final DateTime? plannedDate;
  // try_on 결과 사진(v2 §2-E).
  final AskFittingShot? fitting;
  const AskToolResult(this.observation,
      {this.display,
      this.items = const [],
      this.combos = const [],
      this.ok = true,
      this.plannedDate,
      this.fitting});
}

// 가상 피팅 결과 사진 — 새로 만든 것은 bytes, 캐시에서 온 것은 url. cacheKey로 다시 볼 수 있다.
class AskFittingShot {
  final Uint8List? bytes;
  final String? url;
  final String? cacheKey;
  const AskFittingShot({this.bytes, this.url, this.cacheKey});
}

class AskFittingOutcome {
  final AskFittingShot? shot;
  final String? error; // 사용자 안내 문구(FittingJobController.fittingError)
  final List<String> missingCategories;
  const AskFittingOutcome({this.shot, this.error, this.missingCategories = const []});
}

// 앱의 가상 피팅 경로(FittingJobController.generateFitting) — AppShell이 넘긴다. 테스트·프로브는 가짜.
class AskFittingPort {
  final bool Function() hasUserPhoto; // 지금 선택된 전신 사진이 있는가
  final bool Function() busy; // 다른 피팅이 진행 중인가
  // 그 조합을 코디보드에 올리고 피팅을 실행한다.
  final Future<AskFittingOutcome> Function(List<WardrobeItem> items) run;
  const AskFittingPort({required this.hasUserPhoto, required this.busy, required this.run});
}

const askTryOnWait = Duration(seconds: 120);

// preview_outfit 인자(v2 §2-C).
const askPreviewMaxCount = 5;
const askAdjustWarmer = '더 따뜻하게';
const askAdjustLighter = '더 가볍게';
const askHistoryDays = 60; // 착장 기록을 보는 기간(v2 §2-F)

// 옷 번호 목록 인자 — 형식이 틀린 값은 버린다(검증은 등록부가 먼저 한다).
List<int> askNumberList(Object? v) =>
    v is List ? [for (final x in v) parseAskItemNumber(x)].whereType<int>().toList() : const [];

// 기온대를 한 단계 옮긴다 — 더 따뜻하게 = 더 추운 날의 기준으로.
TempBand askShiftBand(TempBand b, {required bool warmer}) {
  const order = [TempBand.hot, TempBand.mild, TempBand.cool, TempBand.cold];
  final i = order.indexOf(b) + (warmer ? 1 : -1);
  return order[i.clamp(0, order.length - 1)];
}

// 그 기온대를 대표하는 최고기온(tempBandFor의 경계 25·18·10 사이) — 기온대 규칙을 그대로 쓰려고 넣는다.
double askBandTemp(TempBand b) => switch (b) {
      TempBand.hot => 27,
      TempBand.mild => 21,
      TempBand.cool => 13,
      TempBand.cold => 5,
    };

// 옷 번호 — 처음 옷장을 읽을 때 등록 순(같으면 id 순)으로 1부터 매기고, 그 뒤에 생긴 옷은 뒤에
// 붙인다. 같은 옷장이면 늘 같은 번호(프로브가 재현할 수 있게).
class AskItemBook {
  final _byId = <String, int>{};
  final _byNumber = <int, WardrobeItem>{};

  void seed(List<WardrobeItem> wardrobe) {
    final fresh = [for (final i in wardrobe) if (!_byId.containsKey(i.id)) i]
      ..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    for (final i in fresh) {
      numberOf(i);
    }
    for (final i in wardrobe) {
      _byNumber[_byId[i.id]!] = i; // 속성이 바뀌었으면 최신으로
    }
  }

  int numberOf(WardrobeItem i) => _byId.putIfAbsent(i.id, () {
        final n = _byId.length + 1;
        _byNumber[n] = i;
        return n;
      });

  WardrobeItem? item(int number) => _byNumber[number];
  bool has(int number) => _byNumber.containsKey(number);
}

// 옷 번호 인자 — 12, "12", "#12" 모두 받는다. 형식이 틀리면 null.
int? parseAskItemNumber(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v.trim().replaceFirst('#', ''));
  return null;
}

// 화면용 한 줄이 없는 실패(인자 오류 등)를 사용자 말로.
const askDisplayFailed = '확인하지 못했어요';
// 막힌 호출(상한·같은 인자 반복)을 사용자 말로.
const askDisplayBlocked = '이미 확인한 내용으로 이어갈게요';

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

// 화면용 — "11/17(화)", "블랙 카라티".
String askShortDate(DateTime d) => '${d.month}/${d.day}(${_weekdays[d.weekday - 1]})';
String askShortItem(WardrobeItem i) {
  final a = i.attributes;
  if (a == null) return i.category;
  return a.tags.isEmpty ? '${a.color} ${i.category}' : '${a.color} ${a.tags.first}';
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

  // 옷 번호(v2 §2-C) — 대화 안에서만 쓰는 짧은 번호와 실제 옷의 대응. AskTools 하나가 대화 하나다.
  final book = AskItemBook();

  Future<List<WardrobeItem>> _loadWardrobe() async {
    final w = await data.wardrobe();
    book.seed(w);
    return w;
  }

  String _line(WardrobeItem i) => '#${book.numberOf(i)} ${_itemLine(i)}';

  // 번호를 붙인 옷 한 줄(프롬프트의 [현재 코디]용).
  String describe(WardrobeItem i) => _line(i);

  // get_calendar(from, to) — 날짜별 일정(상황, 예정/기록)과 그 날짜에 준비된 추천 요약.
  Future<AskToolResult> getCalendar(Map<String, dynamic> args) async {
    final from = parseAskDate(args['from']);
    final to = parseAskDate(args['to']);
    final err = _rangeError(from, to);
    if (err != null) return AskToolResult(err, ok: false);
    try {
      final entries = await data.calendar(from!, to!);
      final recs = (await data.recommendations(from, to)).where((r) => !r.dismissed && r.targetDate != null);
      final wardrobe = {for (final i in await _loadWardrobe()) i.id: i};
      final span = from == to ? askShortDate(from) : '${askShortDate(from)}~${askShortDate(to)}';
      if (entries.isEmpty) {
        return AskToolResult('${askDateKey(from)}~${askDateKey(to)} 일정 없음', display: '$span 일정 없음');
      }
      final lines = <String>[];
      final shown = <String>[];
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
          recText = '준비된 추천: ${recItems.map(_line).join(', ')}'
              '${rec.colorScore != null ? ' · ${rec.colorScore}점' : ''}'
              '${rec.weatherNote != null ? ' · ${rec.weatherNote}' : ''}';
        }
        lines.add('${askDateLabel(e.date)} [${e.tpoTag}] $state — $recText');
        shown.add('${askShortDate(e.date)} ${e.tpoTag}'
            '${e.isPlanned ? (rec == null ? '(코디 준비 전)' : '(코디 준비됨)') : '(기록)'}');
      }
      return AskToolResult(_clip(lines.join('\n')), display: '일정: ${shown.join(', ')}', items: items);
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
    var known = 0;
    String? single;
    for (var d = from!; !d.isAfter(to!); d = d.add(const Duration(days: 1))) {
      final w = snapshot.forDate(d);
      if (w == null) {
        lines.add('${askDateLabel(d)}: 예보 범위 밖(오늘 포함 $askForecastDays일까지)');
        continue;
      }
      known++;
      final ctx = weatherContextFor(w)!;
      lines.add('${askDateLabel(d)}: 최고 ${w.maxTempC.round()}°C 최저 ${w.minTempC.round()}°C '
          '강수 ${w.precipitationProbability}% · ${_bandLabel(ctx.band)}${ctx.rain ? ' · 비' : ''}');
      single = '${askShortDate(d)} 최고 ${w.maxTempC.round()}° 최저 ${w.minTempC.round()}° · '
          '${ctx.rain ? '비 ${w.precipitationProbability}%' : _bandLabel(ctx.band)}';
    }
    if (snapshot.isAssumed) lines.add('(테스트용 가정 예보)');
    final String display;
    if (known == 0) {
      display = '예보는 $askForecastDays일까지라 그날 날씨는 아직 몰라요';
    } else if (from == to) {
      display = single!;
    } else {
      display = '${askShortDate(from)}~${askShortDate(to)} 예보를 확인했어요';
    }
    return AskToolResult(_clip(lines.join('\n')), display: display);
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
      wardrobe = (await _loadWardrobe()).where((i) => i.attributes != null).toList();
    } catch (e) {
      return AskToolResult('옷장을 불러오지 못했어요: $e', ok: false);
    }
    if (wardrobe.isEmpty) return const AskToolResult('옷장이 비어 있어요', ok: false);
    if (category == null && keyword == null) {
      // 옷 종류(askCategories)만 센다 — "전신"(전신 사진) 같은 옷이 아닌 문서는 총수에 넣지 않는다.
      final counts = <String, int>{};
      for (final i in wardrobe.where((i) => isAskCategory(i.category))) {
        counts[i.category] = (counts[i.category] ?? 0) + 1;
      }
      final total = counts.values.fold(0, (a, b) => a + b);
      if (total == 0) return const AskToolResult('옷장이 비어 있어요', ok: false);
      return AskToolResult(
          '옷장 $total벌 — '
          '${[for (final c in askCategories) if (counts[c] != null) '$c ${counts[c]}'].join(', ')}',
          display: '옷장 $total벌을 확인했어요');
    }
    final kw = (keyword as String?)?.trim();
    bool matches(WardrobeItem i) {
      if (!isAskCategory(i.category)) return false; // "전신"(전신 사진) 같은 옷이 아닌 문서는 빼고 찾는다
      if (category != null && i.category != category) return false;
      if (kw == null) return true;
      final a = i.attributes!;
      // 한 글자 검색어는 태그·색과 완전히 같을 때만("비"가 "네이비"에 걸리지 않게), 두 글자 이상은 부분 일치.
      if (kw.length == 1) return [a.color, ...a.tags].any((t) => t.trim() == kw);
      return [i.category, i.subCategory ?? '', a.color, a.style, a.formality, ...a.tags].any((t) => t.contains(kw));
    }
    // 최근 등록 먼저, 같으면 id 순 — 같은 입력이면 늘 같은 순서(프로브가 같은 규칙으로 재현한다).
    final hits = wardrobe.where(matches).toList()
      ..sort((a, b) {
        final c = b.createdAt.compareTo(a.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final what = [if (category != null) category, if (kw != null) "'$kw'"].join(' ');
    if (hits.isEmpty) {
      return AskToolResult('일치하는 옷 없음(${category ?? '전체'}${kw != null ? ', "$kw"' : ''})',
          display: '$what 옷은 없어요');
    }
    final shown = hits.take(8).toList();
    final list = '일치 ${hits.length}벌${hits.length > 8 ? '(앞 8벌)' : ''}:\n'
        '${[for (var i = 0; i < shown.length; i++) '- ${_line(shown[i])}'].join('\n')}';
    // category만 준 조회는 앞 8벌 밖을 다시 찾지 않게 그 종류 전체의 요약을 함께 준다.
    final summary = kw == null ? '\n${_categorySummary(category as String, hits)}' : '';
    return AskToolResult(_clip(list + summary), display: '$what ${hits.length}벌을 찾았어요', items: shown);
  }

  // 태그별 벌수는 많은 순, 같으면 글자 순(프로브가 같은 규칙으로 재현한다).
  static String _counted(Map<String, int> counts, {int min = 1, int? max}) {
    final e = counts.entries.where((e) => e.value >= min).toList()
      ..sort((a, b) => a.value != b.value ? b.value - a.value : a.key.compareTo(b.key));
    return [for (final x in max == null ? e : e.take(max)) '${x.key} ${x.value}'].join(', ');
  }

  static String _categorySummary(String category, List<WardrobeItem> items) {
    final season = <String, int>{};
    final kind = <String, int>{};
    for (final i in items) {
      for (final t in {for (final t in i.attributes!.tags) t.trim()}) {
        if (t.isEmpty || t == category) continue;
        final m = askSeasonTags.contains(t) || heavyOuterTags.contains(t) ? season : kind;
        m[t] = (m[t] ?? 0) + 1;
      }
    }
    final winter = [
      for (final i in items)
        if (i.attributes!.tags.any((t) => heavyOuterTags.contains(t.trim()))) i,
    ];
    final heavy = heavyOuterTags.join('·');
    final kinds = _counted(kind, min: askSummaryTagMin, max: askSummaryTagMax);
    return [
      '$category ${items.length}벌 요약',
      '계절·두께 태그: ${season.isEmpty ? '없음' : _counted(season)}',
      '종류·소재 태그($askSummaryTagMin벌 이상): ${kinds.isEmpty ? '없음' : kinds}',
      if (winter.isEmpty)
        '한겨울용 태그($heavy) 옷: 없음'
      else
        '한겨울용 태그($heavy) 옷 ${winter.length}벌${winter.length > askWinterListMax ? '(앞 $askWinterListMax벌)' : ''}:\n'
            '${[for (final i in winter.take(askWinterListMax)) '- ${i.attributes!.color} ${i.attributes!.tags.join('·')}(${i.attributes!.formality})'].join('\n')}',
    ].join('\n');
  }

  // preview_outfit(date, tpo, count?, style?, keep?, exclude?, adjust?, unworn_first?) — 일일 추천과 같은
  // matchForWeather. 새 인자(v2 §2-C)는 조합 로직·점수를 건드리지 않고 넘기는 옷 목록을 거르는 방식으로만
  // 구현한다(adjust는 그 기온대를 대표하는 기온을 넣어 기존 기온대 규칙을 그대로 쓴다). 저장 없음.
  Future<AskToolResult> previewOutfit(Map<String, dynamic> args) async {
    final date = parseAskDate(args['date']);
    final tpo = args['tpo'];
    if (date == null) return const AskToolResult('인자 오류: date는 YYYY-MM-DD 형식이어야 해요', ok: false);
    if (!isAskTpo(tpo)) {
      return AskToolResult('인자 오류: tpo는 ${TpoTags.all.map((t) => t.label).join('·')} 중 하나예요', ok: false);
    }
    final count = (args['count'] is int ? args['count'] as int : 1).clamp(1, askPreviewMaxCount);
    final List<WardrobeItem> all;
    try {
      all = (await _loadWardrobe()).where((i) => i.attributes != null && isAskCategory(i.category)).toList();
    } catch (e) {
      return AskToolResult('옷장을 불러오지 못했어요: $e', ok: false);
    }
    if (all.length < 2) return const AskToolResult('옷장에 옷이 부족해 조합을 만들 수 없어요', ok: false);
    final notes = <String>[];

    // 거르기 1 — exclude: 빼고 고를 옷.
    final excluded = {for (final n in askNumberList(args['exclude'])) book.item(n)?.id}.whereType<String>().toSet();
    var pool = [for (final i in all) if (!excluded.contains(i.id)) i];
    // 거르기 2 — keep: 그 종류는 그 옷으로 고정.
    final kept = [for (final n in askNumberList(args['keep'])) book.item(n)].whereType<WardrobeItem>().toList();
    final keptCats = {for (final k in kept) k.category};
    pool = [for (final i in pool) if (!keptCats.contains(i.category)) i, ...kept];
    // 거르기 3 — style: 상의·하의·아우터 각각 태그에 그 글자가 든 옷이 있으면 그 옷들로 좁힌다.
    final style = args['style'] is String ? (args['style'] as String).trim() : '';
    if (style.isNotEmpty) {
      final narrowed = <String>[];
      for (final c in const ['상의', '하의', '아우터']) {
        if (keptCats.contains(c)) continue;
        final hit = [for (final i in pool) if (i.category == c && i.attributes!.tags.any((t) => t.contains(style))) i];
        if (hit.isEmpty) continue;
        pool = [for (final i in pool) if (i.category != c) i, ...hit];
        narrowed.add('$c ${hit.length}벌');
      }
      notes.add(narrowed.isEmpty ? "스타일 '$style': 태그가 맞는 옷이 없어 좁히지 않았어요" : "스타일 '$style'로 좁힘: ${narrowed.join(', ')}");
    }
    // 거르기 4 — unworn_first: 종류마다 최근 60일 착장 기록에 없는 옷으로(그런 옷이 있는 종류만).
    if (args['unworn_first'] == true) {
      final worn = await _wornItemIds();
      final narrowed = <String>[];
      for (final c in askCategories) {
        if (keptCats.contains(c)) continue;
        final unworn = [for (final i in pool) if (i.category == c && !worn.contains(i.id)) i];
        final inCat = pool.where((i) => i.category == c).length;
        if (unworn.isEmpty || unworn.length == inCat) continue;
        pool = [for (final i in pool) if (i.category != c) i, ...unworn];
        narrowed.add('$c ${unworn.length}벌');
      }
      notes.add(narrowed.isEmpty ? '최근 60일에 입지 않은 옷으로 좁힐 종류가 없었어요' : '최근 60일에 입지 않은 옷으로 좁힘: ${narrowed.join(', ')}');
    }

    // 날씨 — 예보 범위 밖이면 오늘 예보의 기온대를 대신 쓴다. adjust는 기온대를 한 단계 옮긴다.
    final snapshot = await _safeWeather();
    var day = snapshot?.forDate(date);
    var outOfRange = false;
    if (day == null && snapshot != null) {
      final todayW = snapshot.forDate(today);
      if (todayW != null) {
        day = DailyWeather(
            date: date, maxTempC: todayW.maxTempC, minTempC: todayW.minTempC, precipitationProbability: 0);
        outOfRange = true;
        notes.add('예보 범위 밖이라 오늘 기온대 기준');
      }
    }
    final adjust = args['adjust'];
    if (day != null && (adjust == askAdjustWarmer || adjust == askAdjustLighter)) {
      final from = tempBandFor(day.maxTempC);
      final to = askShiftBand(from, warmer: adjust == askAdjustWarmer);
      if (to == from) {
        notes.add('$adjust: 이미 ${_bandLabel(from)} 기준이라 더 옮기지 않았어요');
      } else {
        final delta = askBandTemp(to) - day.maxTempC;
        day = DailyWeather(
            date: day.date,
            maxTempC: day.maxTempC + delta,
            minTempC: day.minTempC + delta,
            precipitationProbability: day.precipitationProbability);
        notes.add('$adjust: ${_bandLabel(from)} → ${_bandLabel(to)} 기준으로 골랐어요');
      }
    } else if (adjust != null && day == null) {
      notes.add('예보가 없어 $adjust는 적용하지 못했어요');
    }

    final formality = TpoTags.byLabel(tpo as String).formalityHint;
    final recent = await _safeRecent();
    final combos = <List<WardrobeItem>>[];
    final lines = <String>[];
    var weatherText = '';
    var fallback = false;
    var used = <String>{}; // 앞 조합의 상의·아우터(다음 조합에서 뺀다)
    for (var n = 0; n < count; n++) {
      final w = [for (final i in pool) if (!used.contains(i.id) || keptCats.contains(i.category)) i];
      if (w.length < 2) break;
      final m = AgentPlanner.matchForWeather(wardrobe: w, formalityHint: formality, recentItemIds: recent, day: day);
      if (m.match.candidates.isEmpty) {
        if (n == 0) return AskToolResult('조합을 만들지 못했어요 — ${m.match.shortfall ?? '옷장이 부족해요'}', ok: false);
        break;
      }
      var top = List.of(m.match.candidates.first.items);
      // 지정한 옷은 기온대 규칙으로 빼지 않는다 — 걸러졌으면 그 종류 자리에 다시 넣는다.
      for (final k in kept) {
        if (top.any((i) => i.id == k.id)) continue;
        final at = top.indexWhere((i) => i.category == k.category);
        if (at >= 0) {
          top[at] = k;
        } else {
          top.add(k);
        }
      }
      final sig = (top.map((i) => i.id).toList()..sort()).join(',');
      if (combos.any((c) => (c.map((i) => i.id).toList()..sort()).join(',') == sig)) break;
      combos.add(top);
      if (n == 0) {
        fallback = m.match.isFallback;
        if (day != null) {
          weatherText = buildWeatherNote(
            ctx: weatherContextFor(day),
            baselineTop: m.baseline!.candidates.first.items,
            weatherTop: top,
            finalItems: top,
            wardrobe: w,
            removedIds: (m.fellBack || m.formalityOverride) ? const {} : m.filter!.removedIds,
            isAssumed: snapshot!.isAssumed,
            formalityHint: formality,
            coldOuterRuleApplied: !m.fellBack && !m.formalityOverride && m.filter!.coldOuterRuleApplied,
          ) ??
              '';
        } else {
          weatherText = snapshot == null ? '예보를 불러오지 못해 날씨 없이 골랐어요' : '예보 범위 밖이라 날씨 없이 골랐어요';
        }
      }
      used = {...used, for (final i in top) if (i.category == '상의' || i.category == '아우터') i.id};
      lines.add(count == 1 ? top.map(_line).join(', ') : '조합 ${n + 1}: ${top.map(_line).join(', ')}');
    }
    if (outOfRange) weatherText = '$weatherText(오늘 기온대 기준)';
    final head = '${askDateLabel(date)} [$tpo] 미리 보기(저장 안 함)'
        '${count > 1 ? ' — 요청 $count개 중 ${combos.length}개' : ''}:';
    return AskToolResult(
      _clip([
        if (count == 1) '$head ${lines.first}' else ...[head, ...lines],
        '날씨: $weatherText',
        '격식 차선: ${fallback ? '예 — 일정 격식에 딱 맞는 조합이 없어요' : '아니요'}',
        ...notes,
      ].join('\n')),
      display: combos.length == 1
          ? '${askShortDate(date)} [$tpo] 코디: ${combos.first.map(askShortItem).join(', ')}'
          : '${askShortDate(date)} [$tpo] 코디 ${combos.length}가지',
      items: combos.first,
      combos: combos,
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
            display: '${askShortDate(date)}에는 이미 ${planned.tpoTag} 일정이 있어 넣지 않았어요', ok: false);
      }
      // 예보 범위(오늘 포함 7일) 안이면 바로 준비, 밖이면 등록만.
      final inForecast = date.difference(today).inDays < askForecastDays;
      final w = await data.addPlan(date, tpo, prepare: inForecast);
      if (!inForecast) {
        return AskToolResult('${askDateLabel(date)} [$tpo] 일정을 등록했어요. 코디는 일정이 가까워지면 예보를 보고 준비해요',
            display: '${askShortDate(date)} $tpo 일정을 등록했어요', plannedDate: date);
      }
      final rec = w.recommendation;
      if (!w.prepared || rec == null) {
        return AskToolResult('${askDateLabel(date)} [$tpo] 일정을 등록했어요. 코디는 준비하지 못했어요 — 옷장에 맞는 조합이 없거나 평가에 실패했어요',
            display: '${askShortDate(date)} $tpo 일정을 등록했어요', plannedDate: date);
      }
      final wardrobe = {for (final i in await _loadWardrobe()) i.id: i};
      final recItems = rec.itemIds.map((id) => wardrobe[id]).whereType<WardrobeItem>().toList();
      return AskToolResult(
        _clip('${askDateLabel(date)} [$tpo] 일정을 등록하고 코디를 준비했어요: ${recItems.map(_line).join(', ')}'
            '${rec.colorScore != null ? ' · ${rec.colorScore}점' : ''}'
            '${rec.weatherNote != null ? '\n날씨: ${rec.weatherNote}' : ''}'),
        display: '${askShortDate(date)} $tpo 일정을 등록하고 코디를 준비했어요',
        items: recItems,
        plannedDate: date,
      );
    } catch (e) {
      return AskToolResult('일정을 등록하지 못했어요: $e', ok: false);
    }
  }

  // get_wardrobe_profile {} — 옷장 전체 요약(v2 §2-B-2). "전신"은 세지 않는다.
  Future<AskToolResult> getWardrobeProfile(Map<String, dynamic> args) async {
    final List<WardrobeItem> wardrobe;
    try {
      wardrobe = (await _loadWardrobe()).where((i) => i.attributes != null && isAskCategory(i.category)).toList();
    } catch (e) {
      return AskToolResult('옷장을 불러오지 못했어요: $e', ok: false);
    }
    if (wardrobe.isEmpty) return const AskToolResult('옷장이 비어 있어요', display: '옷장이 비어 있어요', ok: false);
    final byCat = {for (final c in askCategories) c: [for (final i in wardrobe) if (i.category == c) i]};
    final lines = <String>[
      '옷장 ${wardrobe.length}벌 — ${[for (final c in askCategories) if (byCat[c]!.isNotEmpty) '$c ${byCat[c]!.length}'].join(', ')}',
    ];
    for (final c in askCategories) {
      final items = byCat[c]!;
      if (items.isEmpty) continue;
      final season = <String, int>{for (final s in askSeasonBuckets) s: 0};
      final formal = <String, int>{for (final f in askFormalities) f: 0};
      for (final i in items) {
        season[askSeasonOf(i)] = season[askSeasonOf(i)]! + 1;
        final f = i.attributes!.formality;
        formal[f] = (formal[f] ?? 0) + 1;
      }
      lines.add('$c: 계절 ${season.entries.map((e) => '${e.key} ${e.value}').join('·')} / '
          '격식 ${formal.entries.map((e) => '${e.key} ${e.value}').join('·')}');
    }
    final colors = <String, int>{};
    final styles = <String, int>{};
    for (final i in wardrobe) {
      final a = i.attributes!;
      colors[a.color] = (colors[a.color] ?? 0) + 1;
      styles[a.style] = (styles[a.style] ?? 0) + 1;
    }
    lines.add('많은 색: ${_counted(colors, max: 6)}');
    lines.add('많은 스타일: ${_counted(styles, max: 5)}');
    final heavy = [for (final i in byCat['아우터']!) if (isHeavyOuter(i)) i];
    lines.add(heavy.isEmpty
        ? '한겨울용 아우터: 없음'
        : '한겨울용 아우터 ${heavy.length}벌: ${heavy.take(askWinterListMax).map(_line).join(', ')}');
    // 빈 부분(계산) — 오늘 기온대에 맞는 옷이 3벌 미만인 종류, 격식별로 0벌인 종류(액세서리 제외).
    final day = (await _safeWeather())?.forDate(today);
    final ctx = day == null ? null : weatherContextFor(day, wardrobe: wardrobe);
    final gaps = <String>[];
    if (ctx != null) {
      final short = [
        for (final c in askCategories)
          if (c != '액세서리' && byCat[c]!.where((i) => askFitsBand(i, ctx)).length < askProfileMinFit)
            '$c ${byCat[c]!.where((i) => askFitsBand(i, ctx)).length}벌',
      ];
      gaps.add('오늘 기온대(${_bandLabel(ctx.band)})에 맞는 옷이 $askProfileMinFit벌 미만: ${short.isEmpty ? '없음' : short.join(', ')}');
    } else {
      gaps.add('오늘 예보가 없어 기온대 기준 빈 부분은 계산하지 않았어요');
    }
    final noFormal = [
      for (final c in askCategories)
        if (c != '액세서리')
          for (final f in askFormalities)
            if (!byCat[c]!.any((i) => i.attributes!.formality == f)) '$c $f',
    ];
    gaps.add('격식별로 0벌: ${noFormal.isEmpty ? '없음' : noFormal.join(', ')}');
    lines.add('빈 부분 — ${gaps.join(' / ')}');
    return AskToolResult(_clip(lines.join('\n')), display: '옷장 ${wardrobe.length}벌을 요약했어요');
  }

  // 프롬프트용 프로필 한 줄(있는 항목만) — 없으면 null.
  Future<String?> profileLine() async {
    UserProfile? p;
    try {
      p = await data.profile();
    } catch (_) {
      return null;
    }
    if (p == null) return null;
    final parts = [
      if (p.heightCm != null) '키 ${p.heightCm}cm',
      if (p.bodyType != null && p.bodyType!.isNotEmpty) '체형 ${p.bodyType}',
      if (p.personalColor != null && p.personalColor!.isNotEmpty) '퍼스널 컬러 ${p.personalColor}',
      if (p.preferredStyles.isNotEmpty) '선호 스타일 ${p.preferredStyles.join('·')}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // 최근 60일 착장 기록에 나온 옷 id.
  Future<Set<String>> _wornItemIds() async {
    try {
      final entries = await data.calendar(today.subtract(const Duration(days: askHistoryDays)), today);
      return {for (final e in entries) if (!e.isPlanned) ...e.itemIds};
    } catch (_) {
      return const {};
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
