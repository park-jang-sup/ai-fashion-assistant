import '../models/wardrobe_item.dart';

// 같은 카테고리 내 유사 옷 검색(CLIP 임베딩 통합 A단계). RAG 이력 검색이나
// OutfitMatcher의 궁합 매칭과는 무관 — 옷↔옷 시각 유사도 비교만 담당한다.
class SimilarItem {
  final String itemId;
  final double similarity;

  const SimilarItem(this.itemId, this.similarity);
}

class EmbeddingService {
  // 두 벡터 모두 FashionCLIP L2정규화 벡터라고 가정 → 내적이 곧 코사인 유사도.
  // null이거나 길이가 다르면(모델이 바뀌었거나 데이터가 깨진 경우) 비교 불가로 null.
  static double? cosineSimilarity(List<double>? a, List<double>? b) {
    if (a == null || b == null) return null;
    if (a.length != b.length) return null;
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  // 기준 아이템과 "같은 category"인 아이템 중 embedding이 있는 것만 대상으로
  // 코사인 유사도 상위 topN을 반환한다. 다른 카테고리는 절대 섞이지 않는다.
  static List<SimilarItem> findSimilarItems({
    required WardrobeItem item,
    required List<WardrobeItem> wardrobe,
    int topN = 5,
  }) {
    if (item.embedding == null) return const [];

    final scored = <SimilarItem>[];
    for (final other in wardrobe) {
      if (other.id == item.id) continue;
      if (other.category != item.category) continue;
      final sim = cosineSimilarity(item.embedding, other.embedding);
      if (sim == null) continue;
      scored.add(SimilarItem(other.id, sim));
    }
    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    return scored.take(topN).toList();
  }
}
