import '../models/wardrobe_item.dart';
import '../services/outfit_matcher.dart';

// AI 피팅 로딩 팝업의 추천 캐러셀에 쓰는 "이유" 문장을 로컬 규칙으로
// 조합한다(Gemini 호출 없음, 즉시 생성). 색상 관계 → 격식 일치 →
// 카테고리별 한 마디 순으로 적용 가능한 첫 규칙만 쓰고, 속성이 부족하면
// 안전한 기본 문구로 폴백한다. anchor는 항상 "지금 피팅 중인 아이템"이라
// 문장에 명시해 어떤 아이템과 어울리는지가 드러나게 한다(예: "피팅 중인
// 블랙 상의와 어울리는 하의예요").
String buildOutfitReason({
  required WardrobeItem anchor,
  required WardrobeItem candidate,
}) {
  final anchorColor = anchor.attributes?.color ?? '';
  final anchorLabel = anchorColor.isEmpty ? '피팅 중인 ${anchor.category}' : '피팅 중인 $anchorColor ${anchor.category}';

  final tag = _colorRelationTag(anchorColor, candidate.attributes?.color ?? '') ??
      _formalityTag(anchor.attributes?.formality, candidate.attributes?.formality) ??
      _categoryTag(candidate) ??
      '어울리는 ${candidate.category}예요';

  return '$anchorLabel${_withWaGwa(anchor.category)} $tag';
}

// 한글 명사 뒤 접속조사(와/과) 선택 — 마지막 음절에 받침이 있으면 "과".
bool _hasBatchim(String word) {
  if (word.isEmpty) return false;
  final code = word.codeUnitAt(word.length - 1);
  const hangulBase = 0xAC00; // '가'
  const hangulLast = 0xD7A3; // '힣'
  if (code < hangulBase || code > hangulLast) return false;
  return (code - hangulBase) % 28 != 0;
}

String _withWaGwa(String word) => _hasBatchim(word) ? '과' : '와';

// 색상 관계 기반 — 동색(통일감)/뉴트럴끼리(무난)/뉴트럴+포인트(대비) 순으로 판단.
// 반환값은 항상 "…와/과 " 뒤에 자연스럽게 이어지는 서술절이다.
String? _colorRelationTag(String anchorColor, String candidateColor) {
  if (anchorColor.isEmpty || candidateColor.isEmpty) return null;
  final anchorNeutral = OutfitMatcher.isNeutralColor(anchorColor);
  final candidateNeutral = OutfitMatcher.isNeutralColor(candidateColor);

  if (anchorColor == candidateColor) {
    return '$candidateColor 톤으로 통일감 있게 맞춘 조합이에요';
  }
  if (anchorNeutral && candidateNeutral) {
    return '둘 다 활용도 높은 기본 톤이라 실패 없는 조합이에요';
  }
  if (anchorNeutral || candidateNeutral) {
    return '차분하게 매치하면서 $candidateColor로 포인트를 주는 조합이에요';
  }
  return null; // 둘 다 포인트 컬러면 색상만으로는 판단 보류 — 다음 규칙으로.
}

// 격식 기반 — 두 아이템의 격식이 같을 때만 의미 있는 문장이 된다.
String? _formalityTag(String? anchorFormality, String? candidateFormality) {
  if (anchorFormality == null || candidateFormality == null || anchorFormality != candidateFormality) {
    return null;
  }
  switch (anchorFormality) {
    case '캐주얼':
      return '편하게 소화하는 데일리 조합이에요';
    case '세미포멀':
      return '깔끔하게 떨어지는 세미 정장 조합이에요';
    case '포멀':
      return '격식 있게 딱 떨어지는 조합이에요';
    default:
      return null;
  }
}

// 카테고리별 한 마디 — 색상/격식 규칙이 둘 다 적용 안 될 때의 마지막 폴백.
String? _categoryTag(WardrobeItem candidate) {
  final style = candidate.attributes?.style;
  switch (candidate.category) {
    case '신발':
      return (style != null && style.isNotEmpty)
          ? '$style 슈즈로 마무리하는 조합이에요'
          : '신발로 마무리하는 조합이에요';
    case '액세서리':
      return '포인트로 더하기 좋은 조합이에요';
    default:
      return null;
  }
}
