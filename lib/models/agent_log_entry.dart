import 'package:cloud_firestore/cloud_firestore.dart';

// users/{uid}/agent_logs/{id} 컬렉션 문서 — 에이전트가 백그라운드에서 밟은
// "행동 단위" 한 건. history가 결과물(코디/착장)을 남긴다면 agent_logs는
// 그 결과에 이르기까지의 서사(감지 → 후보 생성 → 평가 → 등록)를 남긴다.
// 심사/시연에서 "뒤에서 스스로 일하는 비서"임을 타임라인으로 보여주는 용도.
class AgentLogEntry {
  // 알려진 eventType 상수. 화면이 아이콘/그룹을 결정할 때 참조하고,
  // 이 목록에 없는 값이 와도(모델 진화 대비) 화면은 기본 아이콘으로 처리한다.
  static const typeNewItemDetected = 'new_item_detected';
  static const typeCandidatesGenerated = 'candidates_generated';
  static const typeCandidateEvaluated = 'candidate_evaluated';
  static const typeRecommendationRegistered = 'recommendation_registered';
  static const typeAnalysisCompleted = 'analysis_completed';
  static const typeFittingGenerated = 'fitting_generated';
  static const typeCalendarLogged = 'calendar_logged';
  static const typeScheduleDetected = 'schedule_detected'; // 다가오는 일정 감지(선제 추천)
  static const typeWeeklyPlanned = 'weekly_planned'; // 주간 코디 플랜 수립
  static const typeTaskRecovered = 'task_recovered'; // 실패했던 작업을 재발견/재개/보류(상태 지속성)
  static const typeWeatherChecked = 'weather_checked'; // 날씨를 관찰 도구로 확인(주간 플랜/선제 추천)
  static const typeWeeklyPlanFailed = 'weekly_plan_failed'; // 주간 플랜 생성 실패(docs/task_weekly_plan_scale_v1.md 4단계)
  // 발화 정책 자기 조정(docs/task_agent_cadence_v1.md §6-1) — 판단 근거와
  // 결과를 별도 이벤트 두 개로 남긴다(다른 파이프라인들과 같은 관례,
  // "감지 → 조정" 두 단계). 조정이 실제로 있을 때만 남기고, 유지 판단은
  // agent_logs(서사)가 아니라 agent_meta(진단, lastCadenceReason)에만
  // 남긴다 — §6-2 참고.
  static const typeCadenceSignalDetected = 'cadence_signal_detected';
  static const typeCadenceAdjusted = 'cadence_adjusted';

  final String id;
  final DateTime? createdAt; // 읽을 때만 채워짐(쓸 때는 서버 타임스탬프 사용)
  final String eventType;
  final String message; // 사용자에게 그대로 보여줄 한국어 문장
  // 같은 파이프라인에 속한 연속 이벤트를 화면에서 묶기 위한 상관 id.
  // 추천 파이프라인은 트리거된 옷 id를 공유 id로 쓴다(등록 문서 id는 마지막에야
  // 생기므로). 단발 이벤트(분석/피팅 완료)는 null.
  final String? relatedDocId;
  // [docs/task_selfeval_followup_v1.md 2단계] typeCandidateEvaluated
  // 이벤트에서, 이 후보를 평가한 모델이 주 모델이 아니어서(폴백 응답)
  // 점수는 있어도 통과/미달 판정에 쓰지 않았다는 표시. message 문구는
  // 사람이 읽는 서사라 나중에 바뀔 수 있으므로, "판정 불가가 얼마나
  // 자주 발생하는지"(업스트림 건강도의 대리 지표)를 셀 때는 이 필드를
  // 쓴다 — message 문자열 매칭에 의존하지 않는다. 다른 이벤트 타입에는
  // 의미가 없어 항상 false.
  final bool verdictWithheld;
  // typeWeeklyPlanFailed 전용 계측 필드(docs/task_weekly_plan_scale_v1.md
  // 4단계) — 어떤 실패가 얼마나 자주 나는지 릴리스에서도 남게 한다.
  // 사용자 식별 정보·옷장 내용(아이템 id/속성)은 담지 않는다 — 옷장의
  // 크기(문자 수)만 담는다.
  final String? weeklyPlanFailureReason; // WeeklyPlanFailureReason.name
  final String? weeklyPlanExceptionType; // 원 예외의 런타임 타입(디버깅용)
  final List<String>? weeklyPlanViolations; // request_shape.ts의 violations
  final int? weeklyPlanStatusCode; // GeminiApiException.statusCode
  final int? weeklyPlanCatalogChars; // 옷장 카탈로그 문자수(상한 접근 계측과 공유)

  const AgentLogEntry({
    required this.id,
    this.createdAt,
    required this.eventType,
    required this.message,
    this.relatedDocId,
    this.verdictWithheld = false,
    this.weeklyPlanFailureReason,
    this.weeklyPlanExceptionType,
    this.weeklyPlanViolations,
    this.weeklyPlanStatusCode,
    this.weeklyPlanCatalogChars,
  });

  factory AgentLogEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return AgentLogEntry(
      id: doc.id,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      eventType: data['eventType'] as String? ?? '',
      message: data['message'] as String? ?? '',
      relatedDocId: data['relatedDocId'] as String?,
      verdictWithheld: data['verdictWithheld'] as bool? ?? false,
      weeklyPlanFailureReason: data['weeklyPlanFailureReason'] as String?,
      weeklyPlanExceptionType: data['weeklyPlanExceptionType'] as String?,
      weeklyPlanViolations:
          (data['weeklyPlanViolations'] as List?)?.map((e) => e.toString()).toList(),
      weeklyPlanStatusCode: data['weeklyPlanStatusCode'] as int?,
      weeklyPlanCatalogChars: data['weeklyPlanCatalogChars'] as int?,
    );
  }

  // id는 Firestore가 add() 시점에 자동 부여하므로 쓰기에는 포함하지 않는다.
  Map<String, dynamic> toFirestore() => {
        'eventType': eventType,
        'message': message,
        if (relatedDocId != null) 'relatedDocId': relatedDocId,
        if (verdictWithheld) 'verdictWithheld': verdictWithheld,
        if (weeklyPlanFailureReason != null) 'weeklyPlanFailureReason': weeklyPlanFailureReason,
        if (weeklyPlanExceptionType != null) 'weeklyPlanExceptionType': weeklyPlanExceptionType,
        if (weeklyPlanViolations != null) 'weeklyPlanViolations': weeklyPlanViolations,
        if (weeklyPlanStatusCode != null) 'weeklyPlanStatusCode': weeklyPlanStatusCode,
        if (weeklyPlanCatalogChars != null) 'weeklyPlanCatalogChars': weeklyPlanCatalogChars,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
