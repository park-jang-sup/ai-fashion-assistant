// 옷장 추천 후보 — docs/task_agent_grounding_v1.md 부분 B.
//
// 코디 분석 텍스트와 그 아래 "내 스타일에 맞는 추천 옷" 카드, 합성 중 팝업이
// **같은 후보 목록**을 쓰게 하려고, 화면 파일(fitting_room_screen.dart)에 있던
// _matchStyleRecommendations를 이곳으로 옮겼다. 뽑는 규칙(카테고리당 상위 2개,
// 궁합 점수 내림차순, 최대 maxItems)은 한 글자도 바꾸지 않았다 — Gemini/Claude
// 호출 없이 OutfitMatcher로 기기 안에서 계산한다.
//
// 분석 요청은 이 후보를 프롬프트의 [내 옷장 후보]로 넣고, 모델은 그 안에서만
// 골라 [추천후보] 줄로 번호를 낸다. 그 줄은 화면에 보이지 않게 지운다
// (visibleAnalysisText), 고른 번호는 카드 맨 앞 "AI 추천"으로 쓴다.
import 'package:firebase_auth/firebase_auth.dart';

import '../constants/outfit_reason.dart';
import '../models/wardrobe_item.dart';
import 'firestore_service.dart';
import 'outfit_matcher.dart';
import 'weather_fit.dart';
import 'weather_service.dart';

class StyleCandidate {
  final WardrobeItem item;
  final String caption; // 카드·팝업 아래 추천 이유
  const StyleCandidate({required this.item, required this.caption});
}

// 순수 함수 — 옮기기 전 _matchStyleRecommendations와 같은 계산(옷장을 인자로
// 받는다는 것만 다르다). 매칭 후보가 없으면 빈 리스트.
//
// 2026-11-14 변경(docs/task_demo_flow_v1.md §10-1): 후보가 있는 종류마다 1위는 반드시
// 들어간다 — 예전엔 전체 점수순으로 잘라 점수가 낮은 종류(예: 신발)가 통째로 빠질 수
// 있었다. 남는 자리는 예전처럼 종류당 상위 2개 안에서 점수순으로 채우고, 돌려주는
// 순서도 예전처럼 점수순이다(분석 프롬프트의 [내 옷장 후보] 번호가 이 순서다).
List<StyleCandidate> matchStyleCandidates({
  required List<WardrobeItem> selected,
  required List<WardrobeItem> wardrobe,
  int maxItems = 5,
  // 오늘 예보(§10-1). null이면 아래 계산이 예전과 한 글자도 다르지 않다.
  DailyWeather? weather,
}) {
  final ctx = weatherContextFor(weather, wardrobe: wardrobe);
  if (ctx != null) {
    return _matchStyleCandidatesForWeather(selected: selected, wardrobe: wardrobe, maxItems: maxItems, ctx: ctx);
  }
  final selectedWithAttrs = selected.where((i) => i.attributes != null).toList();
  if (selectedWithAttrs.isEmpty) return const [];

  final fittingIds = selected.map((i) => i.id).toSet();
  const allCategories = ['상의', '하의', '아우터', '신발', '액세서리'];

  final scored = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
  final firsts = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
  for (final category in allCategories) {
    final eligibleAnchors = selectedWithAttrs.where((a) => a.category != category).toList();
    if (eligibleAnchors.isEmpty) continue;

    final pool = wardrobe
        .where((i) =>
            i.category == category && i.attributes != null && !fittingIds.contains(i.id))
        .toList();
    if (pool.isEmpty) continue;

    final perCategory = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
    for (final candidate in pool) {
      WardrobeItem? bestAnchor;
      var bestScore = double.negativeInfinity;
      for (final anchor in eligibleAnchors) {
        final score = OutfitMatcher.compatibilityScore(anchor.attributes!, candidate.attributes!);
        if (score > bestScore) {
          bestScore = score;
          bestAnchor = anchor;
        }
      }
      if (bestAnchor != null) {
        perCategory.add((item: candidate, anchor: bestAnchor, score: bestScore));
      }
    }
    perCategory.sort((a, b) => b.score.compareTo(a.score));
    scored.addAll(perCategory.take(2));
    firsts.add(perCategory.first);
  }

  if (scored.isEmpty) return const [];
  int byScore(({WardrobeItem item, WardrobeItem anchor, double score}) a,
          ({WardrobeItem item, WardrobeItem anchor, double score}) b) =>
      b.score.compareTo(a.score);
  // 종류별 1위 먼저(자리가 종류 수보다 적으면 그중 점수 높은 것부터), 남는 자리는 점수순.
  final firstIds = {for (final f in firsts) f.item.id};
  final chosen = [
    ...(firsts..sort(byScore)),
    ...(scored.where((s) => !firstIds.contains(s.item.id)).toList()..sort(byScore)),
  ].take(maxItems).toList()
    ..sort(byScore);
  return chosen
      .map((s) => StyleCandidate(
          item: s.item, caption: buildOutfitReason(anchor: s.anchor, candidate: s.item)))
      .toList();
}

// 날씨를 넣은 후보 고르기(docs/task_demo_flow_v1.md §10-1) — 2026-11-14 실기기에서 "코디보드의
// 옷을 대체할 만한 옷이 아니라 이상한 옷, 계절과 무관하게 무작위처럼" 보였다. 점수가
// compatibilityScore(격식 근접 + 색 궁합)뿐이라 날씨를 보지 않았고, 동점이 많아 그 안의 순서는
// 옷장 조회 순서였다.
//  · 날씨에 맞는 옷 = 일일 추천 규칙(weather_fit.dart)에서 그 기온대에 빼는 대상도
//    감점 대상도 아닌 옷. 빼는 대상(예: 추운 날의 반바지 — 대안이 있을 때)은 후보에서
//    아예 빠진다.
//  · 종류마다 날씨에 맞는 옷 중에서 궁합 점수순으로 2벌, 모자라면 감점 대상(빼지는 않는
//    옷)에서 점수순으로 채운다.
//  · 그 기온대에 통째로 빼는 종류(더움·온화의 아우터 — 최저 10°C 미만이면 예외)는 내지 않는다.
//  · 동점 순서 고정: 궁합 점수 내림차순 → 최근 등록(createdAt) 먼저 → id 오름차순.
//  · §10의 종류별 1위 포함·점수순 반환은 그대로. compatibilityScore는 바꾸지 않는다.
int _byScoreThenFixed(
  ({WardrobeItem item, WardrobeItem anchor, double score}) a,
  ({WardrobeItem item, WardrobeItem anchor, double score}) b,
) {
  final s = b.score.compareTo(a.score);
  if (s != 0) return s;
  final c = b.item.createdAt.compareTo(a.item.createdAt);
  if (c != 0) return c;
  return a.item.id.compareTo(b.item.id);
}

List<StyleCandidate> _matchStyleCandidatesForWeather({
  required List<WardrobeItem> selected,
  required List<WardrobeItem> wardrobe,
  required int maxItems,
  required WeatherContext ctx,
}) {
  final selectedWithAttrs = selected.where((i) => i.attributes != null).toList();
  if (selectedWithAttrs.isEmpty) return const [];

  final fittingIds = selected.map((i) => i.id).toSet();
  final removed = filterWardrobeForBand(wardrobe, ctx).removedIds;
  bool fits(WardrobeItem i) => !isWeatherPenaltyTarget(i, ctx);
  const allCategories = ['상의', '하의', '아우터', '신발', '액세서리'];

  final scored = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
  final firsts = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
  for (final category in allCategories) {
    if (category == '아우터' && !ctx.needsOuter) continue;
    final eligibleAnchors = selectedWithAttrs.where((a) => a.category != category).toList();
    if (eligibleAnchors.isEmpty) continue;

    final pool = wardrobe
        .where((i) =>
            i.category == category &&
            i.attributes != null &&
            !fittingIds.contains(i.id) &&
            !removed.contains(i.id))
        .toList();
    if (pool.isEmpty) continue;

    final perCategory = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
    for (final candidate in pool) {
      WardrobeItem? bestAnchor;
      var bestScore = double.negativeInfinity;
      for (final anchor in eligibleAnchors) {
        final score = OutfitMatcher.compatibilityScore(anchor.attributes!, candidate.attributes!);
        if (score > bestScore) {
          bestScore = score;
          bestAnchor = anchor;
        }
      }
      if (bestAnchor != null) {
        perCategory.add((item: candidate, anchor: bestAnchor, score: bestScore));
      }
    }
    if (perCategory.isEmpty) continue;
    perCategory.sort(_byScoreThenFixed);
    final good = perCategory.where((e) => fits(e.item)).toList();
    final picked = [
      ...good.take(2),
      ...perCategory.where((e) => !fits(e.item)).take(good.length >= 2 ? 0 : 2 - good.length),
    ];
    scored.addAll(picked);
    firsts.add(picked.first);
  }

  if (scored.isEmpty) return const [];
  final firstIds = {for (final f in firsts) f.item.id};
  final chosen = [
    ...(firsts..sort(_byScoreThenFixed)),
    ...(scored.where((s) => !firstIds.contains(s.item.id)).toList()..sort(_byScoreThenFixed)),
  ].take(maxItems).toList()
    ..sort(_byScoreThenFixed);
  return chosen
      .map((s) => StyleCandidate(
          item: s.item, caption: buildOutfitReason(anchor: s.anchor, candidate: s.item)))
      .toList();
}

// 고른 후보와, 날씨를 써서 골랐으면 그날 최고기온(카드 줄 위 안내 — §10-1-3).
class StyleCandidateSet {
  final List<StyleCandidate> candidates;
  final double? weatherMaxTempC; // null이면 날씨 없이 고름
  const StyleCandidateSet(this.candidates, [this.weatherMaxTempC]);
  static const empty = StyleCandidateSet([]);
}

String weatherPickNote(double maxTempC) => '오늘 날씨(최고 ${maxTempC.round()}°C)에 맞는 옷 위주로 골랐어요';

// 분석 시작을 예보 때문에 늦추지 않는 상한(§10-1-2). 캐시가 있으면 바로 끝난다.
const styleWeatherWait = Duration(seconds: 2);

// 오늘 예보 — 새 옷 등록 추천과 같은 방법(지역 설정·가정 예보 포함). 상한 안에 못 얻으면
// null(날씨 없이 고른다). 늦게 끝난 조회도 캐시에 남아 다음 계산에 쓰인다.
Future<DailyWeather?> _todayWeatherWithin(String uid, Duration limit) async {
  try {
    return await () async {
      final profile = await FirestoreService.getUserProfileSilently(uid);
      final snapshot =
          await WeatherService.fetch(latitude: profile?.regionLatitude, longitude: profile?.regionLongitude);
      return snapshot?.forDate(DateTime.now());
    }()
        .timeout(limit);
  } catch (_) {
    return null;
  }
}

// 로그인 사용자의 옷장과 오늘 예보로 matchStyleCandidates를 돌린다(옮기기 전
// _matchStyleRecommendations의 비동기 부분 + 예보). 옷장 조회와 예보 조회는 동시에.
Future<StyleCandidateSet> loadStyleCandidates(
  List<WardrobeItem> selected, {
  int maxItems = 5,
}) async {
  if (!selected.any((i) => i.attributes != null)) return StyleCandidateSet.empty;
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return StyleCandidateSet.empty;
  final weatherFuture = _todayWeatherWithin(uid, styleWeatherWait);
  final wardrobe = await FirestoreService.wardrobeStream(uid).first;
  final today = await weatherFuture;
  return StyleCandidateSet(
    matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: maxItems, weather: today),
    today?.maxTempC,
  );
}

// 분석 요청에 넣는 후보 수(§3-1 — 카드와 같은 8개).
const analysisCandidateCount = 8;

// "추가 가능"(지금 조합에 그 종류가 없음) / "교체 후보"(이미 있음). 액세서리는
// 세부 종류(모자·가방·시계·팔찌) 기준 — subCategory가 없는 액세서리는 "액세서리"
// 하나로 본다.
String _kindKey(WardrobeItem i) => i.category == '액세서리' ? (i.subCategory ?? '액세서리') : i.category;

bool isAddableCandidate(WardrobeItem candidate, List<WardrobeItem> selected) =>
    !selected.any((s) => _kindKey(s) == _kindKey(candidate));

// [내 옷장 후보] 한 줄 — "1. 아우터(추가 가능): 색상 브라운, …".
String candidatePromptLine(int index, WardrobeItem candidate, List<WardrobeItem> selected) {
  final role = isAddableCandidate(candidate, selected) ? '추가 가능' : '교체 후보';
  return '${index + 1}. ${_kindKey(candidate)}($role): ${candidate.attributes!.toPromptLine()}';
}

String candidatePromptLines(List<StyleCandidate> candidates, List<WardrobeItem> selected) => [
      for (var i = 0; i < candidates.length; i++) candidatePromptLine(i, candidates[i].item, selected),
    ].join('\n');

const _recommendTag = '[추천후보]';

// 모델이 낸 [추천후보] 줄에서 0-based 후보 인덱스를 꺼낸다. 줄이 없거나 "없음"이거나
// 형식이 틀리면 빈 리스트. 범위 밖 번호·중복은 버리고, 앞에서부터 최대 2개.
List<int> parseRecommendedCandidates(String raw, int candidateCount) {
  if (candidateCount <= 0) return const [];
  final line = raw.split('\n').map((l) => l.trim()).firstWhere(
        (l) => l.startsWith(_recommendTag),
        orElse: () => '',
      );
  if (line.isEmpty) return const [];
  final body = line.substring(_recommendTag.length).trim();
  if (body.isEmpty || body.startsWith('없음')) return const [];
  final out = <int>[];
  for (final m in RegExp(r'\d+').allMatches(body)) {
    final n = int.parse(m.group(0)!);
    if (n < 1 || n > candidateCount) continue;
    if (!out.contains(n - 1)) out.add(n - 1);
    if (out.length == 2) break;
  }
  return out;
}

// 화면·이력에 보일 텍스트 — [추천후보] 줄을 지운다. 스트리밍 도중 마지막 줄이
// 아직 덜 온 "[추", "[추천후보] 1" 같은 상태도 숨긴다(줄바꿈이 오기 전까지).
String visibleAnalysisText(String raw) {
  final lines = raw.split('\n');
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trimLeft();
    final isLast = i == lines.length - 1;
    if (t.startsWith(_recommendTag)) continue;
    if (isLast && t.isNotEmpty && _recommendTag.startsWith(t)) continue;
    out.add(lines[i]);
  }
  return out.join('\n');
}

// 카드 순서(docs/task_demo_flow_v1.md §10-2) — ① 모델이 고른 후보(고른 순서 그대로)
// → ② 아직 안 나온 종류의 1위를 상의·하의·아우터·신발·액세서리 순으로 → ③ 나머지 후보
// (원래 순서 = 점수순). 모델이 아무것도 고르지 않았거나 줄을 읽지 못하면(picks 빈 리스트)
// ②③만. 종류는 카테고리 기준(액세서리는 하나로 본다).
const cardCategoryOrder = ['상의', '하의', '아우터', '신발', '액세서리'];

List<({StyleCandidate candidate, bool aiPick})> orderForCards(
  List<StyleCandidate> candidates,
  List<int> picks,
) {
  final picked = <int>[];
  for (final i in picks) {
    if (i >= 0 && i < candidates.length && !picked.contains(i)) picked.add(i);
  }
  final used = {...picked};
  final shownCategories = {for (final i in picked) candidates[i].item.category};
  final categoryFirsts = <int>[];
  for (final category in cardCategoryOrder) {
    if (shownCategories.contains(category)) continue;
    for (var i = 0; i < candidates.length; i++) {
      if (!used.contains(i) && candidates[i].item.category == category) {
        categoryFirsts.add(i);
        used.add(i);
        break;
      }
    }
  }
  return [
    for (final i in picked) (candidate: candidates[i], aiPick: true),
    for (final i in categoryFirsts) (candidate: candidates[i], aiPick: false),
    for (var i = 0; i < candidates.length; i++)
      if (!used.contains(i)) (candidate: candidates[i], aiPick: false),
  ];
}

// 코디보드 슬롯 키 — 액세서리는 등록 카테고리가 전부 "액세서리"라 subCategory(모자/
// 가방/시계/팔찌)로, 그 외는 카테고리명이 곧 슬롯 키. 옷장 화면·홈 추천 카드에서
// 코디보드로 보낼 때(main.dart)와 분석 결과의 추천 카드를 누를 때(docs/
// task_demo_flow_v1.md 부분 D)가 같은 규칙을 쓰도록 여기 둔다.
String? boardSlotKeyFor(WardrobeItem item) =>
    item.category == '액세서리' ? item.subCategory : item.category;

// 조합 서명 — 선택 순서와 무관하게 같은 옷이면 같은 값(정렬된 id). 분석·피팅 결과가
// 지금 코디보드 조합의 것인지 가리는 데 쓴다(부분 D).
String comboSignature(Iterable<WardrobeItem?> items) =>
    (items.whereType<WardrobeItem>().map((i) => i.id).toList()..sort()).join(',');
