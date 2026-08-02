import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

// ── FCM 등록 토큰 관리 (B단계) ────────────────────────────────
// 서버가 이 기기로 알림을 보낼 수 있는지만 담당한다. 언제 보낼지는
// C단계(스케줄러)가 정한다 — 이 서비스는 트리거 판단을 하지 않는다.
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
