// outfit_reason.dart의 isNeutralColor 소스 교체 검증 — 점수/매칭 결과에는
// 영향이 없고 설명 문구만 바뀌는 경로라 실옷장 diff 없이 텍스트 샘플
// 몇 개로 가볍게 확인한다.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/constants/outfit_reason.dart';
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// 옛 8색 무채색 세트 기준으로 재구현한 _colorRelationTag — outfit_reason.dart
// 원본은 private이라 직접 호출 불가, "전" 문구를 보여주기 위한 검증 전용 복제.
const _legacyNeutralColors = {
  '화이트', '블랙', '네이비', '그레이', '베이지', '아이보리', '카키', '그레이지',
};

String? _legacyColorRelationTag(String anchorColor, String candidateColor) {
  if (anchorColor.isEmpty || candidateColor.isEmpty) return null;
  final anchorNeutral = _legacyNeutralColors.contains(anchorColor);
  final candidateNeutral = _legacyNeutralColors.contains(candidateColor);
  if (anchorColor == candidateColor) {
    return '$candidateColor 톤으로 통일감 있게 맞춘 조합이에요';
  }
  if (anchorNeutral && candidateNeutral) {
    return '둘 다 활용도 높은 기본 톤이라 실패 없는 조합이에요';
  }
  if (anchorNeutral || candidateNeutral) {
    return '차분하게 매치하면서 $candidateColor로 포인트를 주는 조합이에요';
  }
  return null;
}

WardrobeItem _item(String id, String category, String color) => WardrobeItem(
      id: id,
      imageUrl: '',
      category: category,
      createdAt: DateTime(2026, 1, 1),
      attributes: ClothingAttributes(
        color: color,
        style: '기본',
        pattern: '무지',
        formality: '캐주얼',
        fit: '레귤러',
        tags: const [],
      ),
    );

void main() {
  test('차콜+회색: 무채색 문구 누락 → 제대로 언급', () {
    final anchor = _item('a', '상의', '차콜');
    final candidate = _item('b', '하의', '회색');

    final before = _legacyColorRelationTag('차콜', '회색');
    final after = buildOutfitReason(anchor: anchor, candidate: candidate);

    print('[색상이유] 차콜+회색 — 전(색상규칙 판단 보류): $before');
    print('[색상이유] 차콜+회색 — 후: $after');

    expect(before, isNull, reason: '전엔 둘 다 미인식이라 색상 규칙 자체가 판단 보류였음');
    expect(after, contains('둘 다 활용도 높은 기본 톤'), reason: '후엔 둘 다 무채색으로 인식돼야 함');
  });

  test('차콜+블루: 무채색+포인트컬러 문구 누락 → 제대로 언급', () {
    final anchor = _item('a', '상의', '차콜');
    final candidate = _item('b', '하의', '블루');

    final before = _legacyColorRelationTag('차콜', '블루');
    final after = buildOutfitReason(anchor: anchor, candidate: candidate);

    print('[색상이유] 차콜+블루 — 전(색상규칙 판단 보류): $before');
    print('[색상이유] 차콜+블루 — 후: $after');

    expect(before, isNull, reason: '전엔 차콜이 미인식이라 대비 문구가 안 나왔음');
    expect(after, contains('포인트를 주는'), reason: '후엔 차콜이 무채색으로 인식돼 대비 문구가 나와야 함');
  });

  test('회색+회색(동색): 전/후 무관하게 동일(동색 분기가 먼저 걸림)', () {
    final anchor = _item('a', '상의', '회색');
    final candidate = _item('b', '하의', '회색');
    final after = buildOutfitReason(anchor: anchor, candidate: candidate);
    print('[색상이유] 회색+회색 — 후: $after');
    expect(after, contains('회색 톤으로 통일감'));
  });

  test('그레이+베이지(원래도 인식됐던 조합): 전/후 동일해야 함(회귀 없음)', () {
    final before = _legacyColorRelationTag('그레이', '베이지');
    final anchor = _item('a', '상의', '그레이');
    final candidate = _item('b', '하의', '베이지');
    final after = buildOutfitReason(anchor: anchor, candidate: candidate);
    print('[색상이유] 그레이+베이지 — 전: $before / 후: $after');
    expect(after, contains(before!));
  });
}
