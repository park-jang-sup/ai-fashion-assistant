import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ── 로컬 알림 서비스 (A단계) ────────────────────────────────
// 백그라운드 실행과 무관하게 독립적으로 동작한다. 이 서비스 자체는
// 알림을 "발송"만 하며, 언제 발송할지는 호출부(추후 B/C단계)가 결정한다.
class NotificationService {
  NotificationService._();

  static const _channelId = 'agent_recommendation';
  static const _channelName = '코디 추천';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);

    // 중요도를 defaultImportance로 둔다 — high는 헤드업 배너로 떠서 방해가 된다.
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      importance: Importance.defaultImportance,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  // Android 13+ 런타임 권한. 앱 첫 실행 시(또는 홈 화면 진입 시) 호출한다.
  // 거부돼도 예외를 던지지 않는다 — 사용자의 선택이므로 호출부는 결과를
  // 무시해도 된다.
  static Future<bool> requestPermissionIfNeeded() async {
    try {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return granted ?? false;
    } catch (e) {
      debugPrint('[Notification] 권한 요청 실패(무시): $e');
      return false;
    }
  }

  // label 예: "내일 [결혼식]"
  static Future<void> showRecommendationReady(String label) async {
    try {
      await _plugin.show(
        0,
        '코디 준비됐어요',
        '$label 일정에 맞는 코디를 준비해뒀어요',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Notification] 발송 실패(무시): $e');
    }
  }
}
