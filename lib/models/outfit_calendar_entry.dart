import 'package:cloud_firestore/cloud_firestore.dart';

// users/{uid}/calendar/{id} 컬렉션 문서 — 사용자가 날짜별로 남기는 착장(OOTD)
// 기록 1건. 이후 에이전트가 이 데이터를 읽어 선제 추천/주간 플랜에 쓰고,
// recommendationId를 통해 "추천 대비 실제 선택" 피드백을 학습한다.
//
// date는 시간대 혼선을 막기 위해 자정으로 정규화해 저장한다. 월/범위 조회는
// where(date >=, <=) + orderBy(date)로 하는데, range와 orderBy가 같은 필드라
// 복합 인덱스 없이 자동 단일필드 인덱스로 충분하다.
class OutfitCalendarEntry {
  static const sourceManual = 'manual'; // 사용자가 직접 기록
  static const sourceAgent = 'agent'; // 에이전트 플랜을 수락해 기록

  // 미래 날짜에 TPO 태그만 먼저 등록한 "예정" vs 실제 착장이 담긴 "기록".
  // status가 없는 과거 문서는 recorded로 간주해 하위호환을 지킨다.
  static const statusPlanned = 'planned';
  static const statusRecorded = 'recorded';

  final String id;
  final DateTime date; // 자정 정규화된 날짜
  final String tpoTag; // '출근'|'데이트'|'여행'|'운동'|'모임'|'일상' 등
  final String? fittingImageUrl; // 가상 피팅 이미지 (있으면)
  // fitting_cache 문서 id — 서명 URL 이행 A-5(§10-1). fittingImageUrl이
  // OutfitHistoryEntry(_selectedFitting)에서 온 경우에만 채워진다.
  final String? fittingCacheKey;
  final List<String> itemIds;
  final List<String> itemSummaries; // "카테고리: 색상" 스냅샷 (기존 패턴)
  final String source; // sourceManual | sourceAgent
  final String? recommendationId; // 에이전트 추천에서 왔으면 그 문서 id
  final String status; // statusPlanned | statusRecorded
  final DateTime createdAt;

  const OutfitCalendarEntry({
    required this.id,
    required this.date,
    required this.tpoTag,
    this.fittingImageUrl,
    this.fittingCacheKey,
    this.itemIds = const [],
    this.itemSummaries = const [],
    this.source = sourceManual,
    this.recommendationId,
    this.status = statusRecorded,
    required this.createdAt,
  });

  // 착장 없이 태그만 있는 미래 예정인지. status 우선, 없으면 itemIds 비어있음으로 판단.
  bool get isPlanned => status == statusPlanned || (itemIds.isEmpty && fittingImageUrl == null);

  // 시간·분·초를 버린 자정 기준 날짜. 저장 키와 조회 범위를 일관되게 맞춘다.
  static DateTime normalizeDate(DateTime d) => DateTime(d.year, d.month, d.day);

  factory OutfitCalendarEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return OutfitCalendarEntry(
      id: doc.id,
      date: (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
      tpoTag: data['tpoTag'] as String? ?? '일상',
      fittingImageUrl: data['fittingImageUrl'] as String?,
      fittingCacheKey: data['fittingCacheKey'] as String?,
      itemIds: (data['itemIds'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      itemSummaries:
          (data['itemSummaries'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      source: data['source'] as String? ?? sourceManual,
      recommendationId: data['recommendationId'] as String?,
      status: data['status'] as String? ?? statusRecorded,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  // id는 Firestore가 add() 시점에 자동 부여하므로 쓰기에는 포함하지 않는다.
  // date는 사용자가 고른 날짜라 서버 타임스탬프가 아니라 정규화한 값을 그대로,
  // createdAt만 서버 타임스탬프로 남긴다.
  Map<String, dynamic> toFirestore() => {
        'date': Timestamp.fromDate(normalizeDate(date)),
        'tpoTag': tpoTag,
        if (fittingImageUrl != null) 'fittingImageUrl': fittingImageUrl,
        if (fittingCacheKey != null) 'fittingCacheKey': fittingCacheKey,
        'itemIds': itemIds,
        'itemSummaries': itemSummaries,
        'source': source,
        if (recommendationId != null) 'recommendationId': recommendationId,
        'status': status,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
