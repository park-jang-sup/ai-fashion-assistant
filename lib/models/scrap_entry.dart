import 'package:cloud_firestore/cloud_firestore.dart';

// users/{uid}/scraps 컬렉션 문서 — 사용자가 피팅룸에서 직접 북마크한 가상
// 피팅 결과 1건. 해제(delete) 시 대상 문서를 지정해야 해서 RecommendationEntry와
// 동일하게 doc.id를 들고 있는 WardrobeItem 패턴을 따른다.
class ScrapEntry {
  final String id;
  final String fittingImageUrl;
  // fitting_cache 문서 id — 서명 URL 이행 A-5(§10-1). 스크랩 생성 시점에
  // FittingJobController.fittingCacheKey를 그대로 받아 저장한다.
  final String? fittingCacheKey;
  final List<String> itemIds;
  final List<String> itemSummaries; // "카테고리: 속성" 한 줄 요약, RecommendationEntry와 동일 패턴
  final DateTime createdAt;

  const ScrapEntry({
    required this.id,
    required this.fittingImageUrl,
    this.fittingCacheKey,
    required this.itemIds,
    required this.itemSummaries,
    required this.createdAt,
  });

  factory ScrapEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ScrapEntry(
      id: doc.id,
      fittingImageUrl: data['fittingImageUrl'] as String? ?? '',
      fittingCacheKey: data['fittingCacheKey'] as String?,
      itemIds: (data['itemIds'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      itemSummaries:
          (data['itemSummaries'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  // id는 Firestore가 add() 시점에 자동 부여하므로 쓰기에는 포함하지 않는다.
  Map<String, dynamic> toFirestore() => {
        'fittingImageUrl': fittingImageUrl,
        if (fittingCacheKey != null) 'fittingCacheKey': fittingCacheKey,
        'itemIds': itemIds,
        'itemSummaries': itemSummaries,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
