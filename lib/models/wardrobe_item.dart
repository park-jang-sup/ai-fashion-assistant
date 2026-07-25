import 'package:cloud_firestore/cloud_firestore.dart';
import 'clothing_attributes.dart';
import 'clothing_size.dart';

class WardrobeItem {
  final String id;
  final String imageUrl;
  final String? cutoutImageUrl; // null = 배경 제거본 없음(원본만 사용)
  final String category;
  // '액세서리' 카테고리 내에서만 쓰이는 세부 타입(모자/가방/시계 등).
  // null = 미분류 — 코디 보드에서 세 슬롯 전부에 폴백으로 노출된다.
  final String? subCategory;
  final DateTime createdAt;
  final ClothingAttributes? attributes; // null = 아직 속성 추출 전(레거시 포함)
  final ClothingSize? size; // null = 치수 미입력
  // FashionCLIP 512차원 L2정규화 벡터(tools/backfill_embeddings로 백필됨).
  // null = 백필 이전 데이터이거나 백필 대상 제외('전신' 카테고리 등).
  final List<double>? embedding;

  const WardrobeItem({
    required this.id,
    required this.imageUrl,
    this.cutoutImageUrl,
    required this.category,
    this.subCategory,
    required this.createdAt,
    this.attributes,
    this.size,
    this.embedding,
  });

  factory WardrobeItem.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final attributesMap = data['attributes'] as Map<String, dynamic>?;
    final sizeMap = data['size'] as Map<String, dynamic>?;
    final embeddingMap = data['embedding'] as Map<String, dynamic>?;
    return WardrobeItem(
      id: doc.id,
      imageUrl: data['imageUrl'] as String? ?? '',
      cutoutImageUrl: data['cutoutImageUrl'] as String?,
      category: data['category'] as String? ?? '상의',
      subCategory: data['subCategory'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      attributes:
          attributesMap != null ? ClothingAttributes.fromJson(attributesMap) : null,
      size: sizeMap != null ? ClothingSize.fromJson(sizeMap) : null,
      embedding: (embeddingMap?['vector'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'imageUrl': imageUrl,
        if (cutoutImageUrl != null) 'cutoutImageUrl': cutoutImageUrl,
        'category': category,
        if (subCategory != null) 'subCategory': subCategory,
        'createdAt': FieldValue.serverTimestamp(),
        if (attributes != null) 'attributes': attributes!.toFirestore(),
        if (size != null) 'size': size!.toFirestore(),
      };
}
