// 날씨를 실제 선택에 반영 — docs/task_agent_grounding_v1.md 부분 C, 기온대 구성은
// docs/task_demo_flow_v1.md 부분 A.
//
// 일일 추천은 예보를 조회해 문구만 만들고 조합을 고르는 OutfitMatcher.findForTpo에는
// 날씨를 넘기지 않았다(grounding_v1에서 감점으로 넣음). 2026-11-14 실기기 확인에서
// 감점(0.3)만으로는 부족했고(추운 날 반팔·여름 상의, 31°C에 블레이저), 아우터는 날씨와
// 무관하게 항상 들어갔다. 그래서 이 파일은
//  (1) 그날 예보에서 비 여부와 기온대(더움/온화/선선/추움)를 뽑고,
//  (2) 기온대에 명백히 어긋나는 옷을 매칭 대상에서 뺀 옷장 목록을 만들고(빼는 일은
//      findForTpo 바깥 — findForTpo의 조합 로직은 그대로),
//  (3) 덜 어울리는 정도의 옷은 findForTpo가 정렬 감점(0.3)에 쓰게 판정하고,
//  (4) 최종 채택 조합 전체를 보고 "실제로 한 일"만 말하는 문구를 만든다.
// 전부 순수 함수다.
//
// 비 기준은 주간 플랜 프롬프트의 날씨 제약과 같다(강수확률이 WeatherService 임계
// 이상). 기온은 다르다 — 주간 플랜 프롬프트는 여전히 더위 28°C / 추위 5°C를 쓴다
// (agent_planner.dart _weatherConstraintNote, 이번 범위 밖).
//
// 태그 키워드는 추측하지 않고 Firestore wardrobe·demo_wardrobe 태그 분포를 읽기
// 전용으로 조사해 실제로 쓰이는 표현만 골랐다(2026-11-14 두 차례, 실행 기록 참고).
// 부분 문자열이 아니라 태그 전체가 같을 때만 맞춘다.
import '../models/wardrobe_item.dart';
import 'color_taxonomy.dart';
import 'outfit_matcher.dart';
import 'weather_service.dart';

enum WeatherFlag { rain }

// 기온대 — 그날 예보의 최고기온으로 정한다(§2-1).
enum TempBand { hot, mild, cool, cold }

TempBand tempBandFor(double maxTempC) {
  if (maxTempC >= 25) return TempBand.hot;
  if (maxTempC >= 18) return TempBand.mild;
  if (maxTempC >= 10) return TempBand.cool;
  return TempBand.cold;
}

// 아우터를 넣는가 — 선선·추움은 넣고, 더움·온화도 최저 10°C 미만(일교차)이면 넣는다.
bool needsOuterFor(TempBand band, double minTempC) =>
    band == TempBand.cool || band == TempBand.cold || minTempC < 10;

class WeatherContext {
  final bool rain;
  final TempBand band;
  final bool needsOuter;
  final double maxTempC;
  final double minTempC;
  // 매칭에 넘긴 옷장에 한겨울용 아우터가 한 벌이라도 있는지 — 추움에서 한겨울용이 아닌
  // 아우터를 감점할지 정한다(§2-5-4). 옷장 없이 만든 문맥(홈 조언 등)은 false.
  final bool wardrobeHasHeavyOuter;
  // 다양성 하한(§2-5-2) 때문에 빼려다 빼지 못하고 남긴 옷 — 기온대와 무관하게 기존
  // 감점(0.3)을 준다(§2-6-1). 매칭에 넘긴 옷장에서 같은 판정을 다시 해 구한다.
  final Set<String> floorKeptIds;
  const WeatherContext({
    required this.rain,
    required this.band,
    required this.needsOuter,
    required this.maxTempC,
    required this.minTempC,
    this.wardrobeHasHeavyOuter = false,
    this.floorKeptIds = const {},
  });

  List<WeatherFlag> get flags => rain ? const [WeatherFlag.rain] : const [];
}

WeatherContext? weatherContextFor(DailyWeather? w, {List<WardrobeItem> wardrobe = const []}) {
  if (w == null) return null;
  final band = tempBandFor(w.maxTempC);
  final base = WeatherContext(
    rain: w.precipitationProbability >= WeatherService.rainProbabilityThreshold,
    band: band,
    needsOuter: needsOuterFor(band, w.minTempC),
    maxTempC: w.maxTempC,
    minTempC: w.minTempC,
  );
  if (wardrobe.isEmpty) return base;
  // 거른 옷장을 넘겨도 하한 때문에 남긴 카테고리는 그대로라 같은 옷이 다시 잡히고,
  // 실제로 뺀 카테고리에는 어긋난 옷이 이미 없어 아무것도 잡히지 않는다.
  return WeatherContext(
    rain: base.rain,
    band: base.band,
    needsOuter: base.needsOuter,
    maxTempC: base.maxTempC,
    minTempC: base.minTempC,
    wardrobeHasHeavyOuter: wardrobe.any(isHeavyOuter),
    floorKeptIds: filterWardrobeForBand(wardrobe, base).floorKeptIds,
  );
}

// 비 — 젖으면 상하는 니트·스웨이드 계열(분포: 스웨이드 33, 니트 11, 골지 4).
const weatherRainAvoidTags = {'니트', '골지', '스웨이드'};
// 두꺼운 소재 — 더움·온화에서 감점. `니트`는 넣지 않는다: 니트 태그 옷 11벌 중 9벌이
// 반팔·여름 태그를 함께 단 여름 니트다(2026-11-14 조사).
const weatherHotAvoidTags = {
  '겨울', '가을/겨울', '가을겨울', '울혼방', '양털안감', '퀼팅안감', '코듀로이', '터틀넥',
};
// 여름 계열 — 추움에서, 선선은 상의를 뺀 나머지에서 매칭 대상에서 뺀다(대안이 있을 때만).
// 선선의 여름 계열 상의는 빼지 않고 감점만 한다(§2-5-1).
const weatherColdAvoidTags = {
  '여름', '반팔', '반팔셔츠', '반팔티', '반팔티셔츠', '반소매', '반팔가디건', '하프티셔츠',
  '반바지', '숏팬츠', '데님쇼츠', '버뮤다팬츠', '하프팬츠', '메쉬', '린넨', '린넨혼방',
  '샌들', '여름아우터',
};
// 상의 소매 길이. 반팔 계열은 상의 84벌 중 79벌에 붙어 있다. `긴팔` 태그는 한 벌도
// 없고, 반팔 계열이 없는 5벌은 맨투맨 3벌과 니트 2벌(봄가을·가을겨울)이다 — 소매를
// 직접 말하는 것은 `맨투맨`뿐이라 긴팔은 이것만 두고, 니트 2벌은 "모름"으로 둔다.
const shortSleeveTags = {'반팔', '반소매', '반팔셔츠', '반팔티', '반팔티셔츠', '하프티셔츠'};
const longSleeveTags = {'맨투맨'};
// 긴팔 판정 보강(§2-5-5) — 반팔 계열 태그가 없고 가을·겨울 계절 태그가 있으면 긴팔로
// 본다. "봄가을"·"가을"은 넣지 않는다(지시서 목록 그대로).
const longSleeveSeasonTags = {'가을겨울', '가을/겨울', '겨울'};
// 하의·신발의 형태(§2-7 A) — 계절·소재 태그와 따로 다룬다. 2026-11-14 사용자 옷장·
// 데모 옷장 하의 24벌 중 반바지 계열 8벌이 전부 이 목록에 잡힌다(반바지 5, 숏팬츠 2,
// 데님쇼츠·버뮤다팬츠·하프팬츠 1).
const shortsTags = {'반바지', '숏팬츠', '데님쇼츠', '버뮤다팬츠', '하프팬츠'};
const sandalTags = {'샌들'};
// 한겨울용 아우터 — 선선에서 감점(아우터 68벌 중 겨울 6, 가을/겨울 3, 양털안감 3, 퀼팅안감 3).
const heavyOuterTags = {'겨울', '가을/겨울', '가을겨울', '양털안감', '퀼팅안감'};
// 얇은 아우터 — 추움에서 감점(바람막이 21, 윈드브레이커 3, 여름아우터 3, 반팔가디건 3).
const thinOuterTags = {'바람막이', '윈드브레이커', '여름아우터', '반팔가디건'};

Set<String> _tags(WardrobeItem i) => (i.attributes?.tags ?? const <String>[]).map((t) => t.trim()).toSet();

enum Sleeve { short, long, unknown }

Sleeve sleeveOf(WardrobeItem item) {
  final tags = _tags(item);
  if (tags.any(shortSleeveTags.contains)) return Sleeve.short;
  if (tags.any(longSleeveTags.contains) || tags.any(longSleeveSeasonTags.contains)) return Sleeve.long;
  return Sleeve.unknown;
}

bool isSummerItem(WardrobeItem item) => _tags(item).any(weatherColdAvoidTags.contains);
bool isShorts(WardrobeItem item) => item.category == '하의' && _tags(item).any(shortsTags.contains);
bool isSandal(WardrobeItem item) => item.category == '신발' && _tags(item).any(sandalTags.contains);
bool isHeavyOuter(WardrobeItem item) => item.category == '아우터' && _tags(item).any(heavyOuterTags.contains);
bool isThinOuter(WardrobeItem item) => item.category == '아우터' && _tags(item).any(thinOuterTags.contains);

// ── (2) 기온대에 명백히 어긋나는 옷을 뺀 옷장 ─────────────────────────
class BandFilterResult {
  final List<WardrobeItem> items;
  final Set<String> removedIds;
  // 기온대에 어긋나지만 다양성 하한 때문에 남긴 옷(§2-6-1 감점 대상).
  final Set<String> floorKeptIds;
  // 추움에서 "한겨울용이 아닌 아우터 제외"(§2-8 결정 2)를 실제로 적용했는지 — 채택된
  // 아우터 격식이 일정과 다르면 문구에 "격식보다 보온을 우선했어요"를 붙인다.
  final bool coldOuterRuleApplied;
  const BandFilterResult(this.items, this.removedIds,
      [this.floorKeptIds = const {}, this.coldOuterRuleApplied = false]);
}

// 아우터를 빼는 경우(더움·온화이고 일교차 없음)는 전부 뺀다. 나머지는 카테고리별로,
// 빼고도 그 카테고리에 옷이 bandFilterMinRemaining(3)벌 이상 남을 때만 뺀다 — 다양성
// 하한(§2-5-2). 1벌이면 데모 옷장(긴팔 상의 1벌)에서 추운 날 상의가 그 한 벌로 고정됐다.
// 소매 길이를 모르는 상의는 빼지 않는다. 속성 없는 옷은 그대로 둔다(findForTpo가
// 어차피 쓰지 않는다).
const bandFilterMinRemaining = 3;

BandFilterResult filterWardrobeForBand(
  List<WardrobeItem> wardrobe,
  WeatherContext ctx, {
  // 일정 격식(일일 추천). null이면 격식 개념이 없는 경로(새 옷 등록 — §2-8 결정 1)라
  // 아우터 계절 구분의 "격식 한 단계 이내" 조건을 뺀다.
  String? formalityHint,
}) {
  final cool = ctx.band == TempBand.cool;
  final cold = ctx.band == TempBand.cold;
  bool fits(WardrobeItem i) =>
      formalityHint == null || OutfitMatcher.isWithinOneFormalityStep(formalityHint, i.attributes?.formality);

  final removed = <String>{};
  final floorKept = <String>{};
  var coldOuterRuleApplied = false;
  final byCategory = <String, List<WardrobeItem>>{};
  for (final i in wardrobe) {
    if (i.attributes == null) continue;
    // 더움·온화(일교차 없음): 아우터 전부.
    if (i.category == '아우터' && !ctx.needsOuter) {
      removed.add(i.id);
      continue;
    }
    byCategory.putIfAbsent(i.category, () => []).add(i);
  }
  List<WardrobeItem> left(String category) =>
      [for (final i in byCategory[category] ?? const <WardrobeItem>[]) if (!removed.contains(i.id)) i];

  // 형태(§2-7 A) — 선선·추움에서 반바지 계열·샌들은 대안이 1벌 이상이면 뺀다.
  // 다양성 하한(3벌)은 아래 계절·소재 규칙에만 쓴다.
  if (cool || cold) {
    for (final (category, isForm) in [('하의', isShorts), ('신발', isSandal)]) {
      final items = left(category);
      if (items.any((i) => !isForm(i))) removed.addAll(items.where(isForm).map((i) => i.id));
    }
  }

  // 아우터 계절 구분(§2-8 결정 2) — 추움은 격식 한 단계 이내의 한겨울용이 있으면 그
  // 밖의 아우터를, 선선은 격식 한 단계 이내의 한겨울용이 아닌 것이 있으면 한겨울용을 뺀다.
  if (cold || cool) {
    final outers = left('아우터');
    if (cold && outers.any((i) => isHeavyOuter(i) && fits(i))) {
      final drop = outers.where((i) => !isHeavyOuter(i));
      if (drop.isNotEmpty) coldOuterRuleApplied = true;
      removed.addAll(drop.map((i) => i.id));
    }
    if (cool && outers.any((i) => !isHeavyOuter(i) && fits(i))) {
      removed.addAll(outers.where(isHeavyOuter).map((i) => i.id));
    }
  }

  // 계절·소재(다양성 하한 3벌) — 남긴 옷은 floorKept(§2-6 감점 대상).
  bool mismatch(WardrobeItem i) => switch (ctx.band) {
        TempBand.hot => i.category == '상의' && sleeveOf(i) == Sleeve.long,
        TempBand.mild => i.category == '상의' && sleeveOf(i) == Sleeve.short,
        TempBand.cool => i.category != '상의' && isSummerItem(i),
        TempBand.cold => isSummerItem(i),
      };
  for (final category in byCategory.keys) {
    final items = left(category);
    final bad = items.where(mismatch).toList();
    if (bad.isEmpty) continue;
    if (items.length - bad.length >= bandFilterMinRemaining) {
      removed.addAll(bad.map((i) => i.id));
    } else {
      floorKept.addAll(bad.map((i) => i.id));
    }
  }
  return BandFilterResult(
    [for (final i in wardrobe) if (!removed.contains(i.id)) i],
    removed,
    floorKept,
    coldOuterRuleApplied,
  );
}

// ── (3) 정렬 감점 대상 ──────────────────────────────────────────────
class WeatherAvoidReason {
  final WeatherFlag? flag; // 비 때문이면 rain, 기온대 때문이면 null
  final String phrase; // "밝은 하의", "스웨이드 신발", "두꺼운 상의", "얇은 아우터"
  const WeatherAvoidReason(this.flag, this.phrase);
}

String _kind(WardrobeItem i) => i.category == '액세서리' ? (i.subCategory ?? '액세서리') : i.category;

// 비 때문에 피하는 이유 — 비 규칙(밝은 하의·신발, 니트·골지·스웨이드)은 그대로다.
WeatherAvoidReason? rainAvoidReason(WardrobeItem item) {
  final attrs = item.attributes;
  if (attrs == null) return null;
  if ((item.category == '하의' || item.category == '신발') &&
      ColorTaxonomy.resolve(attrs.color).brightness == ColorBrightness.light) {
    return WeatherAvoidReason(WeatherFlag.rain, '밝은 ${_kind(item)}');
  }
  final hit = _tags(item).where(weatherRainAvoidTags.contains);
  if (hit.isNotEmpty) return WeatherAvoidReason(WeatherFlag.rain, '${hit.first} ${_kind(item)}');
  return null;
}

// 기온대 때문에 감점하는 이유(§2-2 감점 표 + §2-5 보완).
WeatherAvoidReason? bandAvoidReason(WardrobeItem item, WeatherContext ctx) {
  if (item.attributes == null) return null;
  switch (ctx.band) {
    case TempBand.hot || TempBand.mild:
      if (_tags(item).any(weatherHotAvoidTags.contains)) return WeatherAvoidReason(null, '두꺼운 ${_kind(item)}');
      // 형태(§2-7 A) — 더움은 반바지 우선(긴 하의 감점), 온화는 긴바지 우선(반바지 감점).
      if (item.category == '하의' && ctx.band == TempBand.hot && !isShorts(item)) {
        return const WeatherAvoidReason(null, '긴 하의');
      }
      if (ctx.band == TempBand.mild && isShorts(item)) return const WeatherAvoidReason(null, '반바지');
      return null;
    case TempBand.cool:
      if (isHeavyOuter(item)) return const WeatherAvoidReason(null, '한겨울용 아우터');
      // 선선의 여름 계열 상의는 빼지 않고 감점만(§2-5-1).
      if (item.category == '상의' && isSummerItem(item)) return const WeatherAvoidReason(null, '여름용 상의');
      return null;
    case TempBand.cold:
      if (isThinOuter(item)) return const WeatherAvoidReason(null, '얇은 아우터');
      // 옷장에 한겨울용 아우터가 있으면 그렇지 않은 아우터도 감점(§2-5-4).
      if (ctx.wardrobeHasHeavyOuter && item.category == '아우터' && !isHeavyOuter(item)) {
        return const WeatherAvoidReason(null, '한겨울용이 아닌 아우터');
      }
      return null;
  }
}

// 한 벌에 날씨 감점은 한 번 — 여러 이유가 겹쳐도 findForTpo는 이 bool로 0.3을 한 번 뺀다.
bool isWeatherPenaltyTarget(WardrobeItem item, WeatherContext ctx) =>
    (ctx.rain && rainAvoidReason(item) != null) ||
    bandAvoidReason(item, ctx) != null ||
    ctx.floorKeptIds.contains(item.id);

bool _sameSet(List<WardrobeItem> a, List<WardrobeItem> b) =>
    a.map((i) => i.id).toSet().containsAll(b.map((i) => i.id)) && a.length == b.length;

// 날씨를 넣은 매칭의 1순위가 날씨 없이 돌린 1순위와 다른가(활동 내역의
// "날씨 반영: 조합 변경 있음/없음").
bool weatherChangedTopCombo(List<WardrobeItem> baselineTop, List<WardrobeItem> weatherTop) =>
    !_sameSet(baselineTop, weatherTop);

// ── (4) 문구 — 최종 채택 조합 전체를 기준으로, 확인된 사실만 ──────────
String _subject(String word) {
  if (word.isEmpty) return word;
  final code = word.codeUnitAt(word.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return '$word가';
  return (code - 0xAC00) % 28 != 0 ? '$word이' : '$word가';
}

String _tempLabel(WeatherContext ctx) {
  final max = '최고 ${ctx.maxTempC.round()}°C';
  // 더움·온화인데 일교차로 아우터를 넣는 날은 최저기온이 이유라 함께 쓴다.
  final showMin = ctx.needsOuter && (ctx.band == TempBand.hot || ctx.band == TempBand.mild);
  return showMin ? '$max·최저 ${ctx.minTempC.round()}°C' : max;
}

String _sleeveWord(Sleeve s) => s == Sleeve.short ? '반팔' : '긴팔';

// 아우터 수식어는 태그로 확인될 때만.
String _outerWord(WardrobeItem outer) => isHeavyOuter(outer)
    ? '두꺼운 아우터'
    : isThinOuter(outer)
        ? '가벼운 아우터'
        : '아우터';

// 기온대 문구. wardrobe는 거르기 전 옷장 전체("옷장에 …이 없어"는 정말 한 벌도 없을
// 때만 쓴다), filterFellBack은 거른 목록으로 후보가 안 나와 전체로 다시 돌렸는지.
String _bandNote({
  required WeatherContext ctx,
  required List<WardrobeItem> finalItems,
  required List<WardrobeItem> wardrobe,
}) {
  final label = _tempLabel(ctx);
  final top = finalItems.where((i) => i.category == '상의').firstOrNull;
  final outer = finalItems.where((i) => i.category == '아우터').firstOrNull;
  final want = ctx.band == TempBand.hot ? Sleeve.short : Sleeve.long;
  final got = top == null ? Sleeve.unknown : sleeveOf(top);
  // 선선은 아우터가 조합에 들어가면 반팔을 허용한다(§2-5-1).
  final sleeveOk = got == want ||
      got == Sleeve.unknown ||
      (ctx.band == TempBand.cool && got == Sleeve.short && outer != null);
  final outerOk = (outer != null) == ctx.needsOuter;
  final summerOthers = (ctx.band == TempBand.cool || ctx.band == TempBand.cold)
      ? finalItems.where((i) => i.category != '상의' && i.category != '아우터' && isSummerItem(i)).toList()
      : const <WardrobeItem>[];

  if (sleeveOk && outerOk && summerOthers.isEmpty) {
    final sleeve = got == Sleeve.unknown ? null : _sleeveWord(got);
    if (outer == null) {
      return ctx.band == TempBand.hot
          ? '$label라 ${sleeve != null ? '$sleeve에 ' : ''}아우터 없이 가볍게 골랐어요'
          : '$label라 ${sleeve != null ? '$sleeve로 ' : ''}아우터 없이 골랐어요';
    }
    return '$label라 ${sleeve != null ? '$sleeve에 ' : ''}${_outerWord(outer)}를 더했어요';
  }

  final parts = <String>[];
  if (!sleeveOk) {
    // 원하는 소매의 상의가 옷장에 몇 벌인지로 이유를 가른다(§2-5-6): 0벌이면 "없어",
    // 다양성 하한(3벌) 미만이라 거르지 않았으면 "거의 없어", 그 이상이면 거른 뒤에도
    // 일정(격식)에 맞는 조합이 안 나와 전체로 다시 고른 경우다.
    final wanted = wardrobe.where((i) => i.category == '상의' && i.attributes != null && sleeveOf(i) == want).length;
    final w = _sleeveWord(want);
    final reason = wanted == 0
        ? '옷장에 $w 상의가 없어'
        : wanted < bandFilterMinRemaining
            ? '옷장에 $w이 거의 없어'
            : '일정에 맞는 $w 조합이 나오지 않아';
    final tail = outer != null && ctx.needsOuter
        ? '${_sleeveWord(got)}에 ${_outerWord(outer)}를 더했어요'
        : '${_sleeveWord(got)}로 골랐어요';
    parts.add('$reason $tail');
  }
  if (!outerOk) {
    if (outer == null) {
      final hasOuter = wardrobe.any((i) => i.category == '아우터' && i.attributes != null);
      parts.add(hasOuter ? '일정에 맞는 아우터 조합이 나오지 않아 아우터 없이 골랐어요' : '옷장에 아우터가 없어요');
    } else {
      parts.add('일정에 맞는 조합이 나오지 않아 아우터가 들어갔어요');
    }
  }
  for (final item in summerOthers) {
    final kind = _kind(item);
    // 반바지·샌들(형태)은 대안이 1벌만 있어도 빠지므로 형태 기준으로 말한다(§2-7 A).
    final form = isShorts(item) ? '반바지' : (isSandal(item) ? '샌들' : null);
    if (form != null) {
      final hasAlt = wardrobe.any((i) =>
          i.category == item.category && i.attributes != null && !(isShorts(i) || isSandal(i)));
      parts.add(hasAlt
          ? '일정에 맞는 조합이 나오지 않아 ${_subject(form)} 들어갔어요'
          : '옷장에 ${_subject(form)} 아닌 ${_subject(kind)} 없어 ${_subject(form)} 들어갔어요');
      continue;
    }
    final hasAlt = wardrobe.any((i) => i.category == item.category && i.attributes != null && !isSummerItem(i));
    parts.add(hasAlt
        ? '일정에 맞는 조합이 나오지 않아 여름용 ${_subject(kind)} 들어갔어요'
        : '옷장에 여름용이 아닌 ${_subject(kind)} 없어요');
  }
  return '$label인데 ${parts.join(', ')}';
}

// 비 문구 — 피한 옷 = 날씨 없이 돌린 1순위에 있던 비 감점 대상 중, 날씨를 넣은
// 1순위에도 최종 채택에도 없는 옷. 기온대 때문에 매칭 대상에서 빠진 옷(removedIds —
// 예: 더운 날 빠진 아우터)은 비 때문에 피한 옷으로 세지 않는다.
String _rainNote({
  required List<WardrobeItem> baselineTop,
  required List<WardrobeItem> weatherTop,
  required List<WardrobeItem> finalItems,
  required Set<String> removedIds,
}) {
  final weatherIds = weatherTop.map((i) => i.id).toSet();
  final finalIds = finalItems.map((i) => i.id).toSet();
  final avoided = [
    for (final i in baselineTop)
      if (!weatherIds.contains(i.id) && !finalIds.contains(i.id) && !removedIds.contains(i.id))
        if (rainAvoidReason(i) case final r?) r,
  ];
  if (avoided.isNotEmpty) {
    final r = avoided.first;
    return r.phrase.startsWith('밝은 ')
        ? '비 예보라 ${r.phrase} 대신 어두운 톤으로 골랐어요'
        : '비 예보라 ${r.phrase} 대신 다른 옷으로 골랐어요';
  }
  final remaining = [for (final i in finalItems) if (rainAvoidReason(i) case final r?) r];
  if (remaining.isEmpty) return '비 예보에도 무리 없는 조합이에요';
  return '비 예보지만 ${_subject(remaining.first.phrase)} 그대로 들어갔어요';
}

// 카드 문구. 예보가 없으면 null. isAssumed면 끝에 "(테스트용 가정 예보)".
String? buildWeatherNote({
  required WeatherContext? ctx,
  required List<WardrobeItem> baselineTop,
  required List<WardrobeItem> weatherTop,
  required List<WardrobeItem> finalItems,
  required List<WardrobeItem> wardrobe,
  Set<String> removedIds = const {},
  bool isAssumed = false,
  // 일정 격식과 추움 아우터 규칙 적용 여부(§2-8 결정 2) — 둘 다 있고 채택된 아우터의
  // 격식이 일정과 다르면 끝에 "격식보다 보온을 우선했어요".
  String? formalityHint,
  bool coldOuterRuleApplied = false,
}) {
  if (ctx == null) return null;
  final band = _bandNote(ctx: ctx, finalItems: finalItems, wardrobe: wardrobe);
  var note = ctx.rain
      ? '$band · ${_rainNote(baselineTop: baselineTop, weatherTop: weatherTop, finalItems: finalItems, removedIds: removedIds)}'
      : band;
  final outer = finalItems.where((i) => i.category == '아우터').firstOrNull;
  if (coldOuterRuleApplied &&
      formalityHint != null &&
      outer != null &&
      outer.attributes?.formality != formalityHint) {
    note = '$note · 격식보다 보온을 우선했어요';
  }
  return isAssumed ? '$note (테스트용 가정 예보)' : note;
}

// 홈 날씨 한 줄 조언(§2-4) — 추천과 같은 기온대 함수를 쓴다. 비가 오면 비 조언이 먼저.
// rainProbability(오늘 하루 최대 강수확률)를 주면 비 문구에 숫자를 보여 준다 — 홈은 같은 줄에
// 지금 날씨("맑음 16°")를 함께 보여 주므로, 하루 중 언젠가의 확률이라는 걸 숫자로 드러낸다.
String weatherAdviceFor(WeatherContext ctx, {int? rainProbability}) {
  if (ctx.rain) {
    return rainProbability != null ? '강수확률 $rainProbability%, 우산을 챙기세요' : '비 예보가 있어요, 우산을 챙기세요';
  }
  return switch (ctx.band) {
    TempBand.hot => ctx.needsOuter ? '반팔에 아침저녁용 가벼운 아우터를 챙기세요' : '반팔이면 충분해요',
    TempBand.mild => ctx.needsOuter ? '긴팔에 아침저녁용 가벼운 아우터를 챙기세요' : '긴팔 한 장이면 충분해요',
    TempBand.cool => '긴팔에 가벼운 아우터를 걸치세요',
    TempBand.cold => '두꺼운 아우터가 필요한 추운 날씨예요',
  };
}
