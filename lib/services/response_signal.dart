import '../models/recommendation_entry.dart';

// 발화 정책 자기 조정(docs/task_agent_cadence_v1.md §4·§5)의 입력 산출부 —
// "판정 창(최근 N건)에 어떤 반응이 있었는가"만 순수 함수로 낸다. 판정
// 규칙(간격을 어떻게 바꿀지)은 cadence_policy.dart에 따로 있다 — 여기서
// 갈라놓은 이유는, §4-4가 이미 사전 등록한 대로 이 산출부만 나중에
// (a)의 발송-탭 매칭 데이터로 교체될 예정이기 때문이다. 판정 규칙과
// 그 단위 테스트는 입력이 어디서 오는지 몰라도 되게 만들어, 교체 시점에
// 판정부를 건드리지 않는다.
class ResponseSignal {
  final int sampleSize; // 응답 + 무반응(판정보류 제외) — 판정에 실제로 쓰인 건수
  final int respondedCount; // accepted + rejected_with_alternative
  final int acceptedCount; // respondedCount의 부분집합
  final int noResponseCount; // null이고 now - createdAt >= noResponseAfter
  final int pendingCount; // null이고 아직 noResponseAfter 미만(참고용, 판정 미포함)

  const ResponseSignal({
    required this.sampleSize,
    required this.respondedCount,
    required this.acceptedCount,
    required this.noResponseCount,
    required this.pendingCount,
  });
}

// windowSize=5, noResponseAfter=72시간이 기본값(docs/task_agent_cadence_v1.md
// §4-1). 72시간인 이유: 3.5.1절 피드백 매칭이 ±3일(72시간) 완화로 캘린더
// 기록을 추천에 연결하므로, 그보다 짧은 N을 쓰면 아직 매칭 창이 열려 있어
// 나중에 userChoice가 채워질 수도 있는 문서를 "무반응"으로 성급히 확정하는
// 모순이 생긴다.
//
// `candidates`는 정렬·필터 여부를 가정하지 않는다 — 이 함수가 직접
// (1) dismissed=true 제외, (2) createdAt 내림차순 정렬, (3) 상위
// windowSize건 선택을 전부 한다. 호출부가 이미 "최근 5건"으로 잘라
// 넘기면 dismissed 문서가 그 5건 안에 끼어 있을 때 실제 판정 대상이
// 5건보다 줄어드는 사고가 난다(docs/task_agent_cadence_v1.md §2-1
// 실측에서 yPyw4DC2 계정이 실제로 이 상황이었다 — 단순 createdAt
// 정렬로는 dismissed 문서가 최근 5건에 끼었다). 그래서 필터·정렬
// 책임을 이 함수 안으로 가져와 호출부가 무엇을 넘기든 안전하게 만든다.
ResponseSignal summarizeRecentResponses({
  required List<RecommendationEntry> candidates,
  required DateTime now,
  int windowSize = 5,
  Duration noResponseAfter = const Duration(hours: 72),
}) {
  final sorted = candidates.where((e) => !e.dismissed).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final window = sorted.take(windowSize);

  var responded = 0;
  var accepted = 0;
  var noResponse = 0;
  var pending = 0;

  for (final entry in window) {
    final isAccepted = entry.userChoice == RecommendationEntry.choiceAccepted;
    final isRejected =
        entry.userChoice == RecommendationEntry.choiceRejectedWithAlternative;
    if (isAccepted || isRejected) {
      responded++;
      if (isAccepted) accepted++;
      continue;
    }
    // userChoice == null (또는 알려지지 않은 값) — 경과 시간으로만 갈린다.
    if (now.difference(entry.createdAt) >= noResponseAfter) {
      noResponse++;
    } else {
      pending++;
    }
  }

  return ResponseSignal(
    sampleSize: responded + noResponse,
    respondedCount: responded,
    acceptedCount: accepted,
    noResponseCount: noResponse,
    pendingCount: pending,
  );
}
