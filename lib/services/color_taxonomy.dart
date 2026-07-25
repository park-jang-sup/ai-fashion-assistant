// 색상 라벨(자유 텍스트) → {family, brightness, temperature, isNeutral} 정규화.
// OutfitMatcher의 궁합 규칙 보강(2026-07)에서 도입 — 색상 라벨이 Gemini가
// 매번 새로 생성하는 자유 텍스트라 규칙보다 "라벨 정규화"가 먼저 필요했다.
//
// 3단 매칭: ① 정확한 라벨 매칭 → ② 공백 제거 후 부분 문자열 매칭(수식어
// 흡수, 긴 키워드 우선) → ③ 실패 시 중립 폴백(family=null, isNeutral=false,
// brightness=medium, temperature=neutral) — 아무 규칙도 안 걸리고, 원본
// 문자열이 완전히 같을 때만 OutfitMatcher의 기존 "동색 보너스"가 적용된다.

enum ColorBrightness { light, medium, dark }

enum ColorTemperature { warm, cool, neutral }

class ResolvedColor {
  final String? family; // null = 매핑 실패(폴백)
  final ColorBrightness brightness;
  final ColorTemperature temperature;
  final bool isNeutral;

  const ResolvedColor({
    required this.family,
    required this.brightness,
    required this.temperature,
    required this.isNeutral,
  });

  static const fallback = ResolvedColor(
    family: null,
    brightness: ColorBrightness.medium,
    temperature: ColorTemperature.neutral,
    isNeutral: false,
  );
}

class ColorTaxonomy {
  // family: null이면 무채색(neutral). family 자체는 이번 커밋에서 아직
  // 안 쓰이고(궁합 규칙 보강 다음 커밋에서 매트릭스/톤온톤에 쓸 예정),
  // 이번 커밋의 목적은 isNeutral 하나 — 회색/차콜 무채색 인식 버그 수정.
  static const Map<String, ResolvedColor> _table = {
    '블랙': ResolvedColor(family: null, brightness: ColorBrightness.dark, temperature: ColorTemperature.neutral, isNeutral: true),
    '화이트': ResolvedColor(family: null, brightness: ColorBrightness.light, temperature: ColorTemperature.neutral, isNeutral: true),
    '네이비': ResolvedColor(family: null, brightness: ColorBrightness.dark, temperature: ColorTemperature.cool, isNeutral: true),
    '그레이': ResolvedColor(family: null, brightness: ColorBrightness.medium, temperature: ColorTemperature.neutral, isNeutral: true),
    '회색': ResolvedColor(family: null, brightness: ColorBrightness.medium, temperature: ColorTemperature.neutral, isNeutral: true),
    '차콜': ResolvedColor(family: null, brightness: ColorBrightness.dark, temperature: ColorTemperature.neutral, isNeutral: true),
    '베이지': ResolvedColor(family: null, brightness: ColorBrightness.light, temperature: ColorTemperature.warm, isNeutral: true),
    '아이보리': ResolvedColor(family: null, brightness: ColorBrightness.light, temperature: ColorTemperature.warm, isNeutral: true),
    '카키': ResolvedColor(family: null, brightness: ColorBrightness.medium, temperature: ColorTemperature.warm, isNeutral: true),
    '그레이지': ResolvedColor(family: null, brightness: ColorBrightness.light, temperature: ColorTemperature.neutral, isNeutral: true),
    '크림': ResolvedColor(family: null, brightness: ColorBrightness.light, temperature: ColorTemperature.warm, isNeutral: true),
    '에크루': ResolvedColor(family: null, brightness: ColorBrightness.light, temperature: ColorTemperature.warm, isNeutral: true),
    '와인': ResolvedColor(family: 'wine', brightness: ColorBrightness.dark, temperature: ColorTemperature.warm, isNeutral: false),
    '버건디': ResolvedColor(family: 'wine', brightness: ColorBrightness.dark, temperature: ColorTemperature.warm, isNeutral: false),
    '레드': ResolvedColor(family: 'red', brightness: ColorBrightness.medium, temperature: ColorTemperature.warm, isNeutral: false),
    '핑크': ResolvedColor(family: 'pink', brightness: ColorBrightness.light, temperature: ColorTemperature.warm, isNeutral: false),
    '옐로우': ResolvedColor(family: 'yellow', brightness: ColorBrightness.medium, temperature: ColorTemperature.warm, isNeutral: false),
    '블루': ResolvedColor(family: 'blue', brightness: ColorBrightness.medium, temperature: ColorTemperature.cool, isNeutral: false),
    '스카이블루': ResolvedColor(family: 'blue', brightness: ColorBrightness.light, temperature: ColorTemperature.cool, isNeutral: false),
    '인디고': ResolvedColor(family: 'blue', brightness: ColorBrightness.dark, temperature: ColorTemperature.cool, isNeutral: false),
    '브라운': ResolvedColor(family: 'brown', brightness: ColorBrightness.dark, temperature: ColorTemperature.warm, isNeutral: false),
    '카멜': ResolvedColor(family: 'brown', brightness: ColorBrightness.medium, temperature: ColorTemperature.warm, isNeutral: false),
    '오렌지': ResolvedColor(family: 'orange', brightness: ColorBrightness.medium, temperature: ColorTemperature.warm, isNeutral: false),
    '그린': ResolvedColor(family: 'green', brightness: ColorBrightness.medium, temperature: ColorTemperature.cool, isNeutral: false),
    '올리브': ResolvedColor(family: 'green', brightness: ColorBrightness.dark, temperature: ColorTemperature.warm, isNeutral: false),
  };

  // 라벨이 긴 것부터(부분 문자열 매칭 시 "스카이블루"가 "블루"보다 먼저
  // 걸리도록) 정렬해둔 키 목록.
  static final List<String> _keysByLengthDesc = _table.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  static ResolvedColor resolve(String rawColor) {
    final normalized = rawColor.trim();
    if (normalized.isEmpty) return ResolvedColor.fallback;

    final exact = _table[normalized];
    if (exact != null) return exact;

    final stripped = normalized.replaceAll(RegExp(r'\s+'), '');
    for (final key in _keysByLengthDesc) {
      if (stripped.contains(key)) return _table[key]!;
    }

    return ResolvedColor.fallback;
  }
}
