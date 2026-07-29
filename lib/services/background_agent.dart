import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import '../firebase_options.dart';
import 'firestore_service.dart';

// WorkManager가 부르는 진입점. @pragma('vm:entry-point')가 없으면 릴리스
// 빌드에서 트리 셰이킹으로 제거되어 "디버그는 정상, 릴리스만 안 도는" 형태로
// 나타난다.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return await BackgroundAgent.run(force: inputData?['force'] == true);
  });
}

// B단계: 콜백이 타임스탬프만 찍는 빈 백그라운드. 에이전트 로직(AgentSweeper,
// AgentPlanner.runProactiveCheck)은 C단계에서 run()의 표시된 자리에 연결한다.
class BackgroundAgent {
  static const _minInterval = Duration(hours: 10);

  // 최소 간격 판정 — 이 작업에서 유일하게 분리해 테스트하는 순수 함수.
  // lastRunAt이 미래(기기 시각 변경 등)면 실행 쪽으로 폴백한다: 그렇지
  // 않으면 시각이 잘못 기록된 뒤로 영영 실행되지 않을 수 있기 때문이다.
  @visibleForTesting
  static bool shouldRunNow({
    required DateTime? lastRunAt,
    required DateTime now,
    required bool force,
    Duration minInterval = _minInterval,
  }) {
    if (force) return true;
    if (lastRunAt == null) return true;
    if (lastRunAt.isAfter(now)) return true;
    return now.difference(lastRunAt) >= minInterval;
  }

  // 반환값: true = 성공 또는 재시도해도 달라지지 않는 상황(다음 주기까지
  // 대기). false = Firebase 초기화 자체가 실패한 경우로 한정 — 그 외에는
  // 이 프로젝트가 이미 가진 태스크 큐(agent_tasks)와 재시도가 겹치지
  // 않도록 항상 true를 반환한다.
  static Future<bool> run({bool force = false}) async {
    // 백그라운드 콜백은 별도 아이솔레이트에서 실행되므로 main()의 초기화가
    // 전혀 적용돼 있지 않다 — 여기서 다시 해야 한다.
    WidgetsFlutterBinding.ensureInitialized();

    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } catch (e) {
      debugPrint('[BG] Firebase 초기화 실패: $e');
      return false; // WorkManager 재시도
    }

    // App Check는 현재 강제(enforce)되지 않으므로 여기서 activate하지 않는다.
    // 나중에 강제로 전환하면 이 아이솔레이트에서도 activate가 필요해진다.

    // initializeApp() 직후 currentUser를 바로 읽으면 인증 상태의 디스크
    // 복원이 아직 끝나지 않아 거의 확실히 null이다. authStateChanges()의
    // 첫 값(복원 완료 신호)을 기다리되, 무한 대기를 막기 위해 타임아웃을 둔다.
    final user = await FirebaseAuth.instance
        .authStateChanges()
        .firstWhere((u) => u != null)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (user == null) {
      // 로그인 안 된 상태 — 재시도해도 달라지지 않는다. 절대 여기서
      // signInAnonymously()를 부르지 않는다: 새 익명 uid가 생겨 유령
      // 계정 아래 추천이 쌓이고 사용자는 영영 보지 못한다.
      return true;
    }
    final uid = user.uid;

    Map<String, dynamic>? meta;
    try {
      meta = await FirestoreService.getBackgroundAgentMeta(uid);
    } catch (e) {
      // 가드를 못 읽으면 실행하지 않는다 — 가드가 불확실한 채로 파이프라인이
      // 도는 것보다 이번 실행을 거르는 게 낫다.
      debugPrint('[BG] 가드 읽기 실패, 이번 실행 건너뜀: $e');
      return true;
    }

    final lastRunAt = (meta?['lastRunAt'] as Timestamp?)?.toDate();
    final now = DateTime.now();
    if (!shouldRunNow(lastRunAt: lastRunAt, now: now, force: force)) {
      return true;
    }

    // startedAt을 먼저 기록해야 "실행이 아예 안 걸렸다"와 "실행되다 OS에
    // 죽었다"를 구분할 수 있다. 이 쓰기가 실패하면 마찬가지로 실행하지 않는다.
    try {
      await FirestoreService.setBackgroundAgentMeta(uid, {
        'startedAt': Timestamp.fromDate(now),
      });
    } catch (e) {
      debugPrint('[BG] 가드 쓰기(startedAt) 실패, 이번 실행 건너뜀: $e');
      return true;
    }

    // ── C단계에서 채울 자리 ──────────────────────────────────
    // 6-1. AgentSweeper.run(uid)
    // 6-2. 3초 대기
    // 6-3. AgentPlanner.runProactiveCheck(uid, maxPlans: 2)
    // 6-4. created > 0 이면 NotificationService.showRecommendationReady(firstLabel)
    // 6-5. 로그 드레인 대기
    // B단계에서는 의도적으로 비워둔다.

    try {
      await FirestoreService.setBackgroundAgentMeta(uid, {
        'lastRunAt': Timestamp.fromDate(DateTime.now()),
        'lastResultCreated': 0,
        'lastError': null,
      });
    } catch (e) {
      // 완료 기록 실패는 다음 실행 판단에 영향을 주지만, 이번 실행 자체는
      // 이미 끝났으므로 재시도를 요청하지 않는다.
      debugPrint('[BG] 가드 쓰기(lastRunAt) 실패: $e');
    }

    return true;
  }
}
