import 'package:cloud_firestore/cloud_firestore.dart';
import 'wardrobe_item.dart';

// users/{uid}/recommendations 컬렉션 문서 — 새 옷 등록을 계기로 백그라운드에서
// 자동 생성된 "능동 추천" 코디 1건. dismiss 시 대상 문서를 지정해야 해서
// (OutfitHistoryEntry와 달리) doc.id를 들고 있는 WardrobeItem 패턴을 따른다.
class RecommendationEntry {
  // userChoice에 들어가는 알려진 값. AgentStats/피드백 감지 로직이 리터럴
  // 문자열 대신 이 상수를 참조한다.
  static const choiceAccepted = 'accepted';
  static const choiceRejectedWithAlternative = 'rejected_with_alternative';

  final String id;
  final List<String> itemIds;
  final List<String> itemSummaries; // "카테고리: 속성" 한 줄 요약, HistoryEntry와 동일 패턴
  final int? colorScore;
  final String summaryText;
  final String triggerItemId; // 이 추천을 유발한 새 옷의 id
  final DateTime createdAt;
  final bool dismissed;
  // 자기 평가 루프가 Gemini로 비교 평가한 조합 개수. 루프 도입 전에 저장된
  // 문서에는 없으므로 nullable — null이면 카드에 평가 문구를 생략한다.
  final int? evaluatedCount;
  // 평가한 후보들의 점수(탈락 포함, 평가 순서대로 — 점수 파싱 실패는 0).
  // 활동 로그 화면이 "후보별 점수: 62 → 85" 타임라인을 그릴 때 쓴다.
  final List<int> candidateScores;
  // 일정 기반 선제 추천에서만 채워지는 필드 — 이 추천이 어느 날짜/상황(TPO)
  // 일정을 위해 준비됐는지. null이면 "새 옷 등록" 계기의 일반 추천이다.
  final DateTime? targetDate; // 자정 정규화
  final String? targetTpoTag;
  // ── 레벨 3: 피드백 학습 ──
  // 사용자가 이 추천의 날짜/태그에 실제 착장을 기록했을 때의 반응.
  // 'accepted'(추천대로 입음) | 'rejected_with_alternative'(다른 조합 선택) | null(아직 기록 없음).
  final String? userChoice;
  final List<String> userChosenItemIds; // rejected일 때 사용자가 실제로 고른 조합
  // 이 추천을 생성할 때 과거 불일치 피드백이 실제로 프롬프트에 주입됐는지.
  // true일 때만 카드에 "지난번 선택을 반영했어요"를 표시한다(거짓 표시 금지).
  final bool reflectedFeedback;
  // ── 레벨 4: 실패 대응 ──
  // 해당 TPO 격식에 딱 맞는 조합이 없어 "가장 가까운 차선"으로 채운 경우.
  final bool isFallback;
  // ── 진단-수리 루프 ── 자기 평가 총점이 기준 미달일 때 어떤 아이템을
  // 교체해 다시 평가했는지. repairAttempted가 true일 때만 카드에 "한 번
  // 다듬었다"는 문구를 보여준다.
  final bool repairAttempted;
  final String? repairNote; // 예: "아우터 교체(격식 개선)"
  // isFallback=true일 때 그 원인(카테고리 부족 vs 궁합 점수 낮음)을 설명하는
  // 문구. null이면 배지를 표시하지 않는다(AgentPlanner.buildFallbackNote 참고).
  final String? fallbackNote;
  // ── 예보 재계획 ── 이 추천을 생성한 시점의 해당 날짜 예보 스냅샷. 이후
  // 앱 실행 시 예보가 유의미하게 달라졌는지 비교하는 기준값이라, 일정
  // 기반 선제 추천(targetDate 있음)에서만 채워진다(AgentPlanner.
  // shouldReplanForWeather 참고).
  final int? forecastPrecipProbability;
  final double? forecastMaxTempC;
  // 예보 변화로 이 날짜의 추천이 재계획된 횟수(원본은 0). 무한 재계획을
  // 막는 상한 체크에 쓴다.
  final int replanCount;
  // ── 채택률 지표 ── 선제 추천 생성 시점에 해당 targetTpoTag의 최근 채택률을
  // 확인해 남기는 자기 성능 인지 문구. null이면 카드에 표시하지 않는다
  // (표본이 부족하거나 채택률이 중간대라 눈에 띄게 언급할 필요가 없는 경우).
  final String? confidenceNote;
  // ── 날씨 관찰 ── 선제 추천 대상 날짜의 예보(비/기온)가 특이할 때 남기는
  // 문구. null이면 그 날 날씨가 평이했거나 예보 조회에 실패한 경우.
  final String? weatherNote;

  const RecommendationEntry({
    required this.id,
    required this.itemIds,
    required this.itemSummaries,
    this.colorScore,
    required this.summaryText,
    required this.triggerItemId,
    required this.createdAt,
    this.dismissed = false,
    this.evaluatedCount,
    this.candidateScores = const [],
    this.targetDate,
    this.targetTpoTag,
    this.userChoice,
    this.userChosenItemIds = const [],
    this.reflectedFeedback = false,
    this.isFallback = false,
    this.repairAttempted = false,
    this.repairNote,
    this.fallbackNote,
    this.forecastPrecipProbability,
    this.forecastMaxTempC,
    this.replanCount = 0,
    this.confidenceNote,
    this.weatherNote,
  });

  factory RecommendationEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return RecommendationEntry(
      id: doc.id,
      itemIds: (data['itemIds'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      itemSummaries:
          (data['itemSummaries'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      colorScore: data['colorScore'] as int?,
      summaryText: data['summaryText'] as String? ?? '',
      triggerItemId: data['triggerItemId'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dismissed: data['dismissed'] as bool? ?? false,
      evaluatedCount: data['evaluatedCount'] as int?,
      candidateScores: (data['candidateScores'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      targetDate: (data['targetDate'] as Timestamp?)?.toDate(),
      targetTpoTag: data['targetTpoTag'] as String?,
      userChoice: data['userChoice'] as String?,
      userChosenItemIds:
          (data['userChosenItemIds'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      reflectedFeedback: data['reflectedFeedback'] as bool? ?? false,
      isFallback: data['isFallback'] as bool? ?? false,
      repairAttempted: data['repairAttempted'] as bool? ?? false,
      repairNote: data['repairNote'] as String?,
      fallbackNote: data['fallbackNote'] as String?,
      forecastPrecipProbability: data['forecastPrecipProbability'] as int?,
      forecastMaxTempC: (data['forecastMaxTempC'] as num?)?.toDouble(),
      replanCount: data['replanCount'] as int? ?? 0,
      confidenceNote: data['confidenceNote'] as String?,
      weatherNote: data['weatherNote'] as String?,
    );
  }

  // id는 Firestore가 add() 시점에 자동 부여하므로 쓰기에는 포함하지 않는다.
  Map<String, dynamic> toFirestore() => {
        'itemIds': itemIds,
        'itemSummaries': itemSummaries,
        if (colorScore != null) 'colorScore': colorScore,
        'summaryText': summaryText,
        'triggerItemId': triggerItemId,
        'createdAt': FieldValue.serverTimestamp(),
        'dismissed': dismissed,
        if (evaluatedCount != null) 'evaluatedCount': evaluatedCount,
        if (candidateScores.isNotEmpty) 'candidateScores': candidateScores,
        if (targetDate != null)
          'targetDate': Timestamp.fromDate(
              DateTime(targetDate!.year, targetDate!.month, targetDate!.day)),
        if (targetTpoTag != null) 'targetTpoTag': targetTpoTag,
        if (userChoice != null) 'userChoice': userChoice,
        if (userChosenItemIds.isNotEmpty) 'userChosenItemIds': userChosenItemIds,
        if (reflectedFeedback) 'reflectedFeedback': reflectedFeedback,
        if (isFallback) 'isFallback': isFallback,
        if (repairAttempted) 'repairAttempted': repairAttempted,
        if (repairNote != null) 'repairNote': repairNote,
        if (fallbackNote != null) 'fallbackNote': fallbackNote,
        if (forecastPrecipProbability != null)
          'forecastPrecipProbability': forecastPrecipProbability,
        if (forecastMaxTempC != null) 'forecastMaxTempC': forecastMaxTempC,
        if (replanCount > 0) 'replanCount': replanCount,
        if (confidenceNote != null) 'confidenceNote': confidenceNote,
        if (weatherNote != null) 'weatherNote': weatherNote,
      };

  // "관련 코디 이력" 프롬프트 섹션에 한 줄씩 삽입할 요약. 실제로 다른 조합을
  // 선택했던 기록(rejected_with_alternative)이면 그 대안 아이템까지 구체적으로
  // 남긴다 — 가장 강한 교정 신호이므로 생략하지 않는다(wardrobeById가 있을
  // 때만 대안 아이템의 색상/카테고리를 복원할 수 있다).
  String toPromptLine({Map<String, WardrobeItem>? wardrobeById}) {
    final tagText = '[${targetTpoTag ?? '일상'}] ';
    final proposed = itemSummaries.map((s) {
      final idx = s.indexOf(':');
      if (idx < 0) return s.trim();
      final cat = s.substring(0, idx).trim();
      final color = s.substring(idx + 1).trim().split('/').first.trim();
      return color.isEmpty ? cat : '$color $cat';
    }).join('+');

    if (userChoice == choiceRejectedWithAlternative &&
        userChosenItemIds.isNotEmpty &&
        wardrobeById != null) {
      final chosen = userChosenItemIds
          .map((id) => wardrobeById[id])
          .whereType<WardrobeItem>()
          .map((w) {
            final c = w.attributes?.color ?? '';
            return c.isEmpty ? w.category : '$c ${w.category}';
          })
          .join('+');
      if (chosen.isNotEmpty) {
        return '$tagText상황에서 제안한 ($proposed) 대신 ($chosen)를 선택한 적이 있음';
      }
    }

    final scoreText = colorScore != null ? ', 점수 $colorScore' : '';
    final choiceText = userChoice == choiceAccepted ? ' — 채택됨' : '';
    return '$tagText$proposed$scoreText$choiceText';
  }
}
