import 'package:cloud_firestore/cloud_firestore.dart';
import 'wardrobe_item.dart';

// 코디 조합 하나에 참여한 옷 한 벌의 스냅샷. 나중에 원본 wardrobe 문서가
// 삭제되거나 속성이 재추출돼도 과거 이력이 그대로 남도록 값을 복사해 저장한다.
class HistoryItemSnapshot {
  final String id;
  final String category;
  final String? color;
  final String? style;
  final String? formality;

  const HistoryItemSnapshot({
    required this.id,
    required this.category,
    this.color,
    this.style,
    this.formality,
  });

  factory HistoryItemSnapshot.fromWardrobeItem(WardrobeItem item) {
    return HistoryItemSnapshot(
      id: item.id,
      category: item.category,
      color: item.attributes?.color,
      style: item.attributes?.style,
      formality: item.attributes?.formality,
    );
  }

  factory HistoryItemSnapshot.fromJson(Map<String, dynamic> json) {
    return HistoryItemSnapshot(
      id: json['id'] as String? ?? '',
      category: json['category'] as String? ?? '',
      color: json['color'] as String?,
      style: json['style'] as String?,
      formality: json['formality'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'id': id,
        'category': category,
        if (color != null) 'color': color,
        if (style != null) 'style': style,
        if (formality != null) 'formality': formality,
      };
}

// users/{uid}/history 컬렉션 문서 — 개인화 추천을 위해 축적되는 코디 사용 이력.
class OutfitHistoryEntry {
  static const typeAnalysis = 'analysis';
  static const typeFitting = 'fitting';
  static const typeBoard = 'board';

  final String type;
  final List<HistoryItemSnapshot> items;
  final int? score; // 코디 분석 시 파싱된 점수. 그 외 타입은 null.
  final DateTime? createdAt; // 읽을 때만 채워짐(쓸 때는 서버 타임스탬프 사용)
  final String? fittingImageUrl; // type == typeFitting일 때만 채워지는 결과 이미지 URL.
  // fitting_cache 문서 id(서명 URL 이행 A-5, docs/task_signed_urls_v1.md
  // §10-1) — fittingImageUrl과 같이 있을 때만 의미가 있다. 2026-08-06
  // 이전 이력은 tools/backfill_fitting_cache_key로 소급 채워졌고, 그
  // 이후 생성분은 _logFittingHistorySilently가 매번 같이 쓴다. 없으면
  // (극히 드물게 uid 없어 캐시 문서 저장을 건너뛴 경우) 화면은
  // fittingImageUrl로 폴백한다.
  final String? fittingCacheKey;

  const OutfitHistoryEntry({
    required this.type,
    required this.items,
    this.score,
    this.createdAt,
    this.fittingImageUrl,
    this.fittingCacheKey,
  });

  List<String> get itemIds => items.map((e) => e.id).toList()..sort();

  factory OutfitHistoryEntry.fromFirestore(Map<String, dynamic> data) {
    final itemsList = (data['items'] as List?) ?? const [];
    return OutfitHistoryEntry(
      type: data['type'] as String? ?? '',
      items: itemsList
          .map((e) => HistoryItemSnapshot.fromJson(e as Map<String, dynamic>))
          .toList(),
      score: data['score'] as int?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      fittingImageUrl: data['fittingImageUrl'] as String?,
      fittingCacheKey: data['fittingCacheKey'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'type': type,
        'itemIds': itemIds,
        'items': items.map((e) => e.toFirestore()).toList(),
        if (score != null) 'score': score,
        if (fittingImageUrl != null) 'fittingImageUrl': fittingImageUrl,
        if (fittingCacheKey != null) 'fittingCacheKey': fittingCacheKey,
        'createdAt': FieldValue.serverTimestamp(),
      };

  // 코디 분석 프롬프트의 "최근 코디 이력" 섹션에 한 줄씩 삽입할 요약.
  String toPromptLine() {
    final typeLabel = switch (type) {
      typeAnalysis => '분석',
      typeFitting => '피팅',
      typeBoard => '보드',
      _ => type,
    };
    final itemsText = items.map((e) {
      final attrs = [e.color, e.style, e.formality]
          .where((v) => v != null && v.isNotEmpty)
          .join('/');
      return attrs.isEmpty ? e.category : '${e.category}($attrs)';
    }).join(', ');
    final scoreText = score != null ? ', 점수 $score' : '';
    return '[$typeLabel] $itemsText$scoreText';
  }
}
