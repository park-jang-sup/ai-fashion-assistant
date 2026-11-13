// 날씨를 실제 선택에 반영 — docs/task_agent_grounding_v1.md 부분 C.
//
// 일일 추천은 예보를 조회해 "비 예보라 어두운 톤으로 준비했어요" 같은 문구만
// 만들고, 조합을 고르는 OutfitMatcher.findForTpo에는 날씨를 넘기지 않았다.
// 이 파일은 (1) 그날 예보에서 특이 조건(비·더위·추위)을 뽑고, (2) 그 조건에서
// 피하는 게 좋은 옷인지 판정하고(findForTpo가 정렬 감점에 쓴다), (3) 날씨
// 없이·날씨 넣어 돌린 매칭과 최종 채택 조합을 비교해 "실제로 한 일"만 말하는
// 문구를 만든다. 전부 순수 함수다.
//
// 조건 기준은 주간 플랜 프롬프트의 날씨 제약(agent_planner.dart
// _weatherConstraintNote)과 같다: 비 = 강수확률이 WeatherService 임계 이상,
// 더위 = 최고 28°C 이상, 추위 = 최저 5°C 이하(더위가 우선 — 같은 else-if).
//
// 태그 키워드는 추측하지 않고 2026-11-14 Firestore wardrobe·demo_wardrobe 태그
// 분포(옷 364벌, 태그 159종)를 읽기 전용으로 조사해 실제로 쓰이는 표현만
// 골랐다(실행 기록 참고). 부분 문자열이 아니라 태그 전체가 같을 때만 맞춘다.
import '../models/wardrobe_item.dart';
import 'color_taxonomy.dart';
import 'weather_service.dart';

enum WeatherFlag { rain, hot, cold }

// 비 — 젖으면 상하는 니트·스웨이드 계열(분포: 스웨이드 33, 니트 11, 골지 4).
const weatherRainAvoidTags = {'니트', '골지', '스웨이드'};
// 더운 날 — 겨울·두꺼운 소재 계열.
const weatherHotAvoidTags = {
  '겨울', '가을/겨울', '가을겨울', '울혼방', '양털안감', '퀼팅안감', '코듀로이', '터틀넥',
};
// 추운 날 — 여름·얇은 소재 계열.
const weatherColdAvoidTags = {
  '여름', '반팔', '반팔셔츠', '반팔티', '반팔티셔츠', '반소매', '반팔가디건', '하프티셔츠',
  '반바지', '숏팬츠', '데님쇼츠', '버뮤다팬츠', '하프팬츠', '메쉬', '린넨', '린넨혼방',
  '샌들', '여름아우터',
};

List<WeatherFlag> weatherFlagsFor(DailyWeather? w) {
  if (w == null) return const [];
  return [
    if (w.precipitationProbability >= WeatherService.rainProbabilityThreshold) WeatherFlag.rain,
    if (w.maxTempC >= 28) WeatherFlag.hot else if (w.minTempC <= 5) WeatherFlag.cold,
  ];
}

// 이 옷을 피하는 이유(문구용) — 감점 대상이 아니면 null.
class WeatherAvoidReason {
  final WeatherFlag flag;
  final String phrase; // "밝은 하의", "스웨이드 신발", "두꺼운 아우터", "얇은 상의"
  const WeatherAvoidReason(this.flag, this.phrase);
}

String _kind(WardrobeItem i) => i.category == '액세서리' ? (i.subCategory ?? '액세서리') : i.category;

WeatherAvoidReason? weatherAvoidReason(WardrobeItem item, List<WeatherFlag> flags) {
  final attrs = item.attributes;
  if (attrs == null || flags.isEmpty) return null;
  final tags = attrs.tags.map((t) => t.trim()).toSet();
  for (final flag in flags) {
    switch (flag) {
      case WeatherFlag.rain:
        if ((item.category == '하의' || item.category == '신발') &&
            ColorTaxonomy.resolve(attrs.color).brightness == ColorBrightness.light) {
          return WeatherAvoidReason(flag, '밝은 ${_kind(item)}');
        }
        final hit = tags.where(weatherRainAvoidTags.contains);
        if (hit.isNotEmpty) return WeatherAvoidReason(flag, '${hit.first} ${_kind(item)}');
      case WeatherFlag.hot:
        if (tags.any(weatherHotAvoidTags.contains)) return WeatherAvoidReason(flag, '두꺼운 ${_kind(item)}');
      case WeatherFlag.cold:
        if (tags.any(weatherColdAvoidTags.contains)) return WeatherAvoidReason(flag, '얇은 ${_kind(item)}');
    }
  }
  return null;
}

bool isWeatherPenaltyTarget(WardrobeItem item, List<WeatherFlag> flags) =>
    weatherAvoidReason(item, flags) != null;

String _flagLabel(WeatherFlag f) => switch (f) {
      WeatherFlag.rain => '비 예보',
      WeatherFlag.hot => '더운 날씨 예보',
      WeatherFlag.cold => '추운 날씨 예보',
    };

String _avoidedTail(WeatherFlag f) => switch (f) {
      WeatherFlag.rain => '대신 다른 옷으로 골랐어요',
      WeatherFlag.hot => '대신 가벼운 옷으로 골랐어요',
      WeatherFlag.cold => '대신 따뜻한 옷으로 골랐어요',
    };

bool _sameSet(List<WardrobeItem> a, List<WardrobeItem> b) =>
    a.map((i) => i.id).toSet().containsAll(b.map((i) => i.id)) && a.length == b.length;

// 날씨를 넣은 매칭의 1순위가 날씨 없이 돌린 1순위와 다른가(활동 내역의
// "날씨 반영: 조합 변경 있음/없음").
bool weatherChangedTopCombo(List<WardrobeItem> baselineTop, List<WardrobeItem> weatherTop) =>
    !_sameSet(baselineTop, weatherTop);

// 카드 문구 — 실제로 한 일만 말한다(§4-3).
// - 피한 옷 = 날씨 없이 돌린 1순위 조합에 있던 감점 대상 중, 날씨를 넣은 1순위
//   조합에도 없고 최종 채택 조합에도 없는 옷. 자기평가가 다른 이유로 2순위를
//   채택한 것을 날씨 덕으로 돌리지 않으려고 이렇게 좁게 정의한다.
// - 남은 옷 = 최종 채택 조합에 들어 있는 감점 대상.
// 특이 조건이 없으면 null(문구 없음). isAssumed면 끝에 "(테스트용 가정 예보)".
String? buildWeatherNote({
  required List<WeatherFlag> flags,
  required List<WardrobeItem> baselineTop,
  required List<WardrobeItem> weatherTop,
  required List<WardrobeItem> finalItems,
  bool isAssumed = false,
}) {
  if (flags.isEmpty) return null;
  final weatherIds = weatherTop.map((i) => i.id).toSet();
  final finalIds = finalItems.map((i) => i.id).toSet();
  final avoided = [
    for (final i in baselineTop)
      if (!weatherIds.contains(i.id) && !finalIds.contains(i.id))
        if (weatherAvoidReason(i, flags) case final r?) r,
  ];
  final remaining = finalItems.where((i) => isWeatherPenaltyTarget(i, flags)).toList();
  final label = flags.map(_flagLabel).join('·');
  final String note;
  if (avoided.isNotEmpty) {
    final r = avoided.first;
    note = r.flag == WeatherFlag.rain && r.phrase.startsWith('밝은 ')
        ? '${_flagLabel(r.flag)}라 ${r.phrase} 대신 어두운 톤으로 골랐어요'
        : '${_flagLabel(r.flag)}라 ${r.phrase} ${_avoidedTail(r.flag)}';
  } else if (remaining.isEmpty) {
    note = '$label에도 무리 없는 조합이에요';
  } else {
    note = '$label가 있지만 옷장에 더 맞는 옷이 없어 그대로 추천해요';
  }
  return isAssumed ? '$note (테스트용 가정 예보)' : note;
}
