import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'agent_planner.dart';
import 'firestore_service.dart';

// ── FCM 등록 토큰 관리 + 수신 처리 (B단계 + C단계) ──────────────
// 서버가 이 기기로 알림을 보낼 수 있는지(토큰 등록)와, 탭했을 때 기존
// runProactiveCheck 경로를 태우는 것까지만 담당한다. 언제 보낼지 판단하는
// 쪽(C단계 스케줄러)은 서버에 있다 — 이 서비스는 트리거 판단을 하지 않는다.
class FcmService {
  FcmService._();

  static final _db = FirebaseFirestore.instance;
  static final _functions = FirebaseFunctions.instanceFor(region: 'asia-northeast3');

  // 앱 시작 시 1회 호출. Android 13+ 알림 권한은 NotificationService가 이미
  // 요청하므로(POST_NOTIFICATIONS, 로컬 알림과 동일 권한) 여기서 다시
  // requestPermission()을 부르지 않는다 — 중복 프롬프트를 피한다.
  static Future<void> init() async {
    // [FCM-DIAG] 원인 조사용 임시 로그 — fcm_tokens에 토큰이 전혀 안 쌓이는데
    // Dart 쪽 catch 블록도 네이티브 로그도 아무 신호가 없어서, init() 진입
    // 자체가 안 되는지/getToken()에서 멈추는지/조용히 null이 오는지부터
    // 구분해야 했다. 원인이 확정되면 이 블록의 로그·타임아웃 값(§아래)을
    // 다시 볼 것 — 지금은 진단이 목적이라 세 지점만 최소로 찍는다.
    debugPrint('[FCM-DIAG] init() 진입');

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await _registerCurrentToken(uid);
    }

    // 토큰은 앱 재설치·데이터 삭제·주기적 갱신으로 바뀐다(함정 5) — 한 번
    // 저장하고 끝내면 조용히 도달하지 않게 된다.
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) return;
      _saveToken(currentUid, token);
    });

    // C단계 — 푸시를 "탭"했을 때만 반응한다. onMessage(포그라운드 수신)는
    // 일부러 안 넣는다 — 앱이 떠 있을 때는 기존 WorkManager 경로와 겹칠 수
    // 있고, C의 목적은 "앱이 죽어 있을 때 도달"이지 포그라운드 알림이
    // 아니다. 새 파이프라인이 아니라 기존 AgentPlanner.runProactiveCheck를
    // 그대로 태운다 — 단, 아래 두 경로가 runProactiveCheck를 부르는지
    // 여부가 갈린다(이유는 _handleMessageTap 주석 참고).
    //
    // 앱이 백그라운드에 살아 있는 상태에서 탭한 경우 — AppShell이 이미
    // 훨씬 전에 마운트돼 있어 initState()가 다시 안 돈다. 이 경로가
    // runProactiveCheck의 유일한 트리거다.
    FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _handleMessageTap(message, isColdStart: false),
    );
    // 앱이 완전히 종료된 상태에서 탭해 새로 기동된 경우 — 이 메시지는
    // onMessageOpenedApp으로 안 오고 getInitialMessage()로만 잡힌다.
    // 콜드스타트라 AppShell.initState()(main.dart:188)가 곧 자체적으로
    // runProactiveCheck를 돈다 — 여기서 또 부르면 안 된다.
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) _handleMessageTap(message, isColdStart: true);
    });
  }

  // source가 'server_scheduler'가 아니어도(예: B단계 sendTestPush) 그냥
  // 태운다 — 어차피 우리 앱이 보낸 알림을 탭했다는 건 "지금 확인이 필요한
  // 코디가 있을 수 있다"는 신호로 취급해도 무해하다(runProactiveCheck 자체가
  // 추천 없는 예정일이 없으면 아무것도 안 만든다). BackgroundAgent.run을 안
  // 거치므로 클라이언트의 invokeCount/invocationLog(로컬 카운터 포함)는 이
  // 경로에서 전혀 안 늘어난다.
  //
  // isColdStart로 runProactiveCheck 호출 여부가 갈린다 — 이건 코드만
  // 봐서는 알 수 없는 판단이라 반드시 여기 남긴다. AppShell.initState()
  // (main.dart:188)가 "앱-진입 시 1회" 자체적으로 선제 추천 체크를 도는데,
  // 이 initState는 위젯이 새로 만들어질 때만 실행된다:
  //   - 앱 완전 종료 상태에서 탭 → 콜드스타트 → AppShell 신규 생성 →
  //     initState() 실행 → 거기서 이미 runProactiveCheck를 돈다. 여기서
  //     또 부르면 같은 날짜에 추천이 두 개 생긴다(2026-08-02 실기기
  //     검증에서 실제로 관측 - 8/4 대상 추천 2건, 1초 간격 생성).
  //   - 앱이 백그라운드에 살아 있는 상태에서 탭 → 포그라운드 복귀만 발생,
  //     initState()는 다시 안 돈다(WidgetsBindingObserver 등 lifecycle
  //     훅이 없음) → 이 경로에서는 여기서 부르는 게 유일한 트리거다.
  // 락을 걸어 경합을 막는 방향은 일부러 안 갔다 - 어느 쪽이 막힐지가
  // 타이밍에 달려 "서버 푸시가 완주로 이어진 비율"이라는 계측 자체가
  // 왜곡된다. isColdStart로 애초에 한쪽만 부르면 경합 자체가 안 생기고
  // 인과도 계측으로 그대로 보존된다.
  //
  // "서버 푸시가 실제로 완주로 이어졌는가"(C단계의 가장 값진 산출물)를
  // 보려면 서버가 "보냈다"는 사실만으로는 부족하고 탭 이후 실행 여부를
  // 클라이언트가 남겨야 한다. source == 'server_scheduler'일 때만
  // agent_meta의 **별도** 필드에 남긴다 — 기존 invokeCount/lastRunAt는
  // 여전히 runProactiveCheck 내부(BackgroundAgent 경유 실행)만의 몫으로 안
  // 건드리고, runProactiveCheck 시그니처에 플래그를 넘기는 침습도 하지
  // 않는다.
  //   - serverTapCount: 탭이 감지된 사실(증가) - 두 경로 모두 동일하게
  //     기록한다. 탭 자체는 출처(콜드스타트/백그라운드)와 무관하다.
  //   - serverTapAt: 탭이 감지된 시각 - 두 경로 모두 기록한다.
  //     isColdStart일 땐 여기서 runProactiveCheck를 안 부르므로 "완주
  //     시각"을 직접 잡을 방법이 없다. **lastRunAt과 대조해 사후 판정하는
  //     방법은 성립하지 않는다** - lastRunAt은 background_agent.dart의
  //     BackgroundAgent.run()(WorkManager가 3시간마다 부르는 콜백)
  //     내부에서만 갱신되고, 여기(AppShell.initState, main.dart:188)의
  //     맨 runProactiveCheck 호출은 BackgroundAgent를 거치지 않아
  //     lastRunAt을 전혀 안 건드린다 - 콜드스타트 경로가 완주해도
  //     lastRunAt은 예전 WorkManager 실행 시각 그대로다(2026-08-02
  //     실기기 검증 중 자체 발견 - 최초 설계는 이 대조가 가능하다고
  //     잘못 가정했었다). 콜드스타트 경로의 완주 여부는 계측 필드로
  //     판정할 수 없고, 결과물(해당 targetDate에 추천이 실제로
  //     생성됐는지)로만 확인 가능하다.
  //   - serverTapLastRunAt: isColdStart가 아닐 때만(runProactiveCheck를
  //     실제로 여기서 부른 경우만) 그 Future가 끝난 시점에 기록한다 -
  //     runProactiveCheck는 내부에서 이미 예외를 삼키므로 .then만으로
  //     안전하다. isColdStart 경로에서는 이 필드가 갱신되지 않는다 -
  //     4주 표본을 다룰 때 콜드스타트 탭은 이 필드로 완주 여부를 판정할
  //     수 없다는 걸 모르면 전부 "완주 안 됨"으로 잘못 읽게 된다.
  // getInitialMessage() 재소비 필터 — 2026-08-02 실기기 검증 중 실측 확인:
  // adb install -r로 프로세스가 강제 종료·재기동된 직후의 실행에서,
  // 실제 탭이 없었는데도 getInitialMessage()가 **이미 한 번 처리했던**
  // 이전 알림(다른 targetDate)을 다시 반환했다(FlutterFire #10768과 같은
  // 증상 - "getInitialMessage() returns non null notification even after
  // it is consumed"). 이 경우 실제 탭 없이 serverTapCount가 올라가
  // 계측이 오염된다. targetDate가 아니라 message.messageId로 걸러내는
  // 이유 - 같은 날짜로 여러 번 푸시가 나갈 수 있고, 그건 각각 별개의
  // 도달 시도라 targetDate만으로 걸러내면 진짜 새 푸시까지 막힌다.
  //
  // SharedPreferences가 아니라 파일인 이유 - 2026-07-30 결정을 그대로
  // 따른다(background_agent.dart:89-94 참고): shared_preferences는 이
  // 저장소 pubspec에 없고, Firestore/auth와 무관한 순수 로컬 상태 하나에
  // 새 의존성을 추가하지 않는다. 이미 의존성인 path_provider로 충분하다.
  // 임시파일+rename 원자적 교체 패턴도 로컬 발화 카운터(같은 파일)와
  // 동일한 이유(도중에 죽어도 반쪽 파일이 안 남음)로 그대로 따른다.
  static const _lastMessageIdFileName = 'fcm_last_message_id.txt';

  static Future<File> _lastMessageIdFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_lastMessageIdFileName');
  }

  // 읽기/쓰기 실패 시 폴백은 "필터링하지 않고 통과" - 이 필터는 계측
  // 정확도를 높이는 부가 기능이지, 탭 처리 자체를 막을 이유가 아니다.
  static Future<String?> _readLastMessageId() async {
    try {
      final file = await _lastMessageIdFile();
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      return null;
    }
  }

  static Future<void> _writeLastMessageId(String id) async {
    try {
      final file = await _lastMessageIdFile();
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(id);
      await tmpFile.rename(file.path);
    } catch (e) {
      // 무시 - 다음 탭에서 이 필터가 안 걸릴 뿐, 탭 처리 자체는 계속돼야 한다.
    }
  }

  static Future<void> _handleMessageTap(RemoteMessage message, {required bool isColdStart}) async {
    final messageId = message.messageId;
    if (messageId != null) {
      final lastId = await _readLastMessageId();
      if (lastId == messageId) {
        // 이미 처리한 메시지의 재소비 - 계측도 하지 않고 즉시 return.
        // 이 로그가 실제로 필터링됐는지 확인할 유일한 방법이다(계측을
        // 안 남기는 게 목적이라 agent_meta엔 아무 흔적도 안 남는다).
        debugPrint('[FCM-TAP] 재소비 필터링(messageId=$messageId) - 스킵');
        return;
      }
      await _writeLastMessageId(messageId);
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final source = message.data['source'] ?? 'unknown';
    debugPrint('[FCM-TAP] source=$source targetDate=${message.data['targetDate']} '
        'isColdStart=$isColdStart');

    final isServerTriggered = source == 'server_scheduler';
    if (isServerTriggered) {
      unawaited(FirestoreService.setBackgroundAgentMeta(uid, {
        'serverTapCount': FieldValue.increment(1),
        'serverTapAt': Timestamp.fromDate(DateTime.now()),
      }));
    }

    if (isColdStart) {
      // AppShell.initState()(main.dart:188)가 곧 자체적으로
      // runProactiveCheck를 돈다 - 여기서 또 부르면 중복 생성이 된다.
      return;
    }

    final check = AgentPlanner.runProactiveCheck(uid);
    if (isServerTriggered) {
      unawaited(check.then((_) => FirestoreService.setBackgroundAgentMeta(uid, {
            'serverTapLastRunAt': Timestamp.fromDate(DateTime.now()),
          })));
    } else {
      unawaited(check);
    }
  }

  static Future<void> _registerCurrentToken(String uid) async {
    try {
      debugPrint('[FCM-DIAG] getToken() 호출 직전');
      // 진단 목적의 타임아웃 — getToken()이 hang인지 조용한 null 반환인지
      // 구분이 안 돼 넣었다. 10초는 임의값(정상 응답이면 훨씬 빨리 끝남).
      // 원인이 확정되면 이 타임아웃과 재시도 정책을 다시 설계할 것 —
      // 지금은 "진단"이 목적이라 실패해도 폴백은 원래 정책 그대로
      // "아무것도 하지 않음"(토큰 저장을 건너뛸 뿐 앱 동작엔 영향 없음).
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 10));
      debugPrint('[FCM-DIAG] getToken() 반환: ${token == null ? "null" : "non-null"}');
      if (token != null) await _saveToken(uid, token);
    } catch (e) {
      debugPrint('[FCM] 토큰 조회 실패(무시): $e');
    }
  }

  // 문서 id를 토큰 문자열 자체로 써서 같은 토큰이 중복 저장되지 않게 한다.
  // 여러 기기를 대비해 단일 필드가 아니라 컬렉션으로 둔다(함정 5).
  static Future<void> _saveToken(String uid, String token) async {
    try {
      debugPrint('[FCM-DIAG] _saveToken() 진입');
      await _db
          .collection('users')
          .doc(uid)
          .collection('fcm_tokens')
          .doc(token)
          .set({'updatedAt': FieldValue.serverTimestamp()});
      debugPrint('[FCM-DIAG] _saveToken() 완료');
    } catch (e) {
      debugPrint('[FCM] 토큰 저장 실패(무시): $e');
    }
  }

  // 설정 화면 진단 버튼 — 호출한 uid의 모든 등록 기기로 서버가 테스트
  // 푸시를 보낸다. 결과(발송 성공 수/등록된 토큰 수)를 그대로 돌려줘
  // 호출부가 스낵바 문구를 만들 수 있게 한다.
  static Future<({int sentCount, int tokenCount})> sendTestPush() async {
    final result = await _functions.httpsCallable('sendTestPush').call();
    final data = result.data as Map;
    return (
      sentCount: data['sentCount'] as int,
      tokenCount: data['tokenCount'] as int,
    );
  }
}
