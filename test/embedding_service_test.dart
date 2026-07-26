// EmbeddingService.findSimilarItems의 순수 로직 단위 테스트.
// 실제 FashionCLIP 벡터 대신 합성 벡터로 필터링/정렬/제한 동작만 검증한다
// (코사인 유사도 자체는 내적 한 줄이라 별도 수학 검증이 필요 없음).
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/embedding_service.dart';

WardrobeItem _item(String id, String category, {List<double>? embedding}) => WardrobeItem(
      id: id,
      imageUrl: 'https://example.com/$id.png',
      category: category,
      createdAt: DateTime(2026, 1, 1),
      embedding: embedding,
    );

void main() {
  group('EmbeddingService.cosineSimilarity', () {
    test('길이가 다르면 null', () {
      expect(EmbeddingService.cosineSimilarity([1, 0], [1, 0, 0]), isNull);
    });

    test('둘 중 하나라도 null이면 null', () {
      expect(EmbeddingService.cosineSimilarity(null, [1, 0, 0]), isNull);
    });
  });

  group('EmbeddingService.findSimilarItems', () {
    final base = _item('base', '상의', embedding: [1, 0, 0]);

    test('같은 category만 반환한다', () {
      final wardrobe = [
        base,
        _item('same-cat', '상의', embedding: [0.9, 0.1, 0]),
        _item('diff-cat', '하의', embedding: [1, 0, 0]), // 완전 동일 벡터라도 카테고리 다르면 제외
      ];
      final result = EmbeddingService.findSimilarItems(item: base, wardrobe: wardrobe);
      expect(result.map((r) => r.itemId), ['same-cat']);
    });

    test('자기 자신은 제외된다', () {
      final wardrobe = [base, _item('other', '상의', embedding: [0.5, 0.5, 0])];
      final result = EmbeddingService.findSimilarItems(item: base, wardrobe: wardrobe);
      expect(result.any((r) => r.itemId == 'base'), isFalse);
    });

    test('기준 아이템 embedding이 null이면 빈 리스트(크래시 없음)', () {
      final noEmbedding = _item('no-emb', '상의');
      final wardrobe = [noEmbedding, _item('other', '상의', embedding: [1, 0, 0])];
      final result = EmbeddingService.findSimilarItems(item: noEmbedding, wardrobe: wardrobe);
      expect(result, isEmpty);
    });

    test('후보 중 embedding이 null인 것은 건너뛴다', () {
      final wardrobe = [
        base,
        _item('no-emb', '상의'), // embedding 없음 — 스킵돼야 함
        _item('has-emb', '상의', embedding: [0.9, 0.1, 0]),
      ];
      final result = EmbeddingService.findSimilarItems(item: base, wardrobe: wardrobe);
      expect(result.map((r) => r.itemId), ['has-emb']);
    });

    test('유사도 내림차순으로 정렬된다', () {
      final wardrobe = [
        base,
        _item('low', '상의', embedding: [0.1, 0.9, 0]), // 유사도 0.1
        _item('high', '상의', embedding: [0.9, 0.1, 0]), // 유사도 0.9
        _item('mid', '상의', embedding: [0.5, 0.5, 0]), // 유사도 0.5
      ];
      final result = EmbeddingService.findSimilarItems(item: base, wardrobe: wardrobe, topN: 10);
      expect(result.map((r) => r.itemId), ['high', 'mid', 'low']);
      for (var i = 0; i < result.length - 1; i++) {
        expect(result[i].similarity, greaterThanOrEqualTo(result[i + 1].similarity));
      }
    });

    test('topN 개수 제한이 지켜진다', () {
      final wardrobe = [
        base,
        for (var i = 0; i < 5; i++) _item('cand-$i', '상의', embedding: [1 - i * 0.1, i * 0.1, 0]),
      ];
      final result = EmbeddingService.findSimilarItems(item: base, wardrobe: wardrobe, topN: 2);
      expect(result.length, 2);
    });
  });
}
