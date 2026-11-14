// 설정 화면 정리(시험용 기능을 "테스트 도구" 화면으로 옮김) — 설정 화면에 시험용 항목이 없고, 테스트 도구
// 화면에 옮긴 항목이 모두 있으며, 예보 가정을 켜면 설정 화면의 "테스트 도구" 줄에 켜짐 표시가 보인다.
// Firebase 없이 그린다(settingsCurrentUser·settingsBackgroundMetaStream), 예보 가정 파일은 임시 폴더.
import 'dart:io';

import 'package:ai_fashion_assistant/screens/settings_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _User implements User {
  @override
  String get uid => 'u';
  @override
  List<UserInfo> get providerData => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _testItems = [
  '테스트 알림 보내기',
  'FCM 테스트 푸시',
  '예보 가정(테스트용)',
  '즉시 실행 (테스트)',
  '지연 실행 30초 (시연용)',
  '주기 실행 시뮬레이션 (가드 적용)',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings_test_tools');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    settingsCurrentUser = () => _User();
    settingsBackgroundMetaStream = (_) => Stream.value(null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {} // 임시 폴더 — 지우지 못해도 무시
  });

  // 파일 읽기·쓰기는 실제 IO라 실제 시간과 pump를 몇 번 번갈아 준다.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SettingsScreen())));
    await settle(tester);
  }

  testWidgets('설정 화면 — 카드·체험·설정·정보·계정 순서, 시험용 항목은 보이지 않는다', (tester) async {
    await pumpSettings(tester);
    for (final item in _testItems) {
      expect(find.text(item), findsNothing, reason: item);
    }
    expect(find.textContaining('uid:'), findsNothing);
    expect(find.textContaining('로컬 발화 카운터'), findsNothing);
    expect(find.textContaining('마지막 완료'), findsNothing);
    expect(find.text('백그라운드 에이전트(진단)'), findsNothing);
    final order = [
      '마이페이지',
      'AI 비서 활동 내역',
      '체험',
      '데모 옷장 불러오기',
      '데모 옷장 비우기',
      '설정',
      '내 스크랩',
      '사용 가이드 다시 보기',
      '푸시 알림',
      '마케팅 정보 수신',
      '지역',
      '정보',
      '이용약관',
      '개인정보처리방침',
      '오픈소스 라이선스',
      '앱 버전',
      '테스트 도구',
      '계정',
      '계정 연동',
      '로그아웃',
    ];
    final ys = [for (final t in order) tester.getTopLeft(find.text(t).first).dy];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]), reason: '${order[i - 1]} → ${order[i]}');
    }
    expect(find.text('알림 테스트, 백그라운드 실행, 예보 가정'), findsOneWidget);
    expect(find.text('심사·시연용 데모 옷장을 내 옷장으로 복사합니다'), findsOneWidget);
    expect(find.text('데모로 불러온 옷과 예시 일정만 삭제됩니다'), findsOneWidget);
  });

  testWidgets('테스트 도구 화면 — 안내 한 줄과 알림·백그라운드 에이전트·진단 정보 묶음의 항목이 모두 있다', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('테스트 도구'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(TestToolsScreen), findsOneWidget);
    expect(find.text('개발과 시연 확인용 기능입니다. 일반 사용에는 필요하지 않습니다.'), findsOneWidget);
    final order = [
      '알림',
      '테스트 알림 보내기',
      'FCM 테스트 푸시',
      '백그라운드 에이전트',
      '예보 가정(테스트용)',
      '즉시 실행 (테스트)',
      '지연 실행 30초 (시연용)',
      '주기 실행 시뮬레이션 (가드 적용)',
      '진단 정보',
      'uid: u (탭하여 복사)',
    ];
    final ys = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]), reason: '${order[i - 1]} → ${order[i]}');
    }
    expect(find.textContaining('로컬 발화 카운터'), findsOneWidget);
    expect(find.text('아직 실행 기록 없음'), findsOneWidget); // 마지막 완료·invokeCount 자리(기록 없음)
    expect(find.byTooltip('다시 읽기'), findsOneWidget);
    // 설명 글은 그대로
    expect(find.text('서버가 이 계정의 등록 기기로 직접 보냅니다'), findsOneWidget);
    expect(find.text('누른 뒤 앱을 완전히 종료해도 실행됩니다'), findsOneWidget);
    expect(find.text('force 없이 등록 — 최근 실행이 있으면 skipped로 기록됩니다'), findsOneWidget);
    expect(find.text('실제 예보를 씁니다'), findsOneWidget);
  });

  testWidgets('예보 가정을 켜면 설정 화면의 "테스트 도구" 줄에 켜짐 표시, 끄면 원래 설명', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('테스트 도구'));
    await tester.pumpAndSettle();
    await settle(tester);
    await tester.tap(find.text('없음'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('비').last);
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.textContaining('실제 예보 대신 가정한 예보로 추천합니다'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text('예보 가정 켜짐: 비'), findsOneWidget);
    expect(find.text('알림 테스트, 백그라운드 실행, 예보 가정'), findsNothing);
    // 끄면 원래 설명으로
    await tester.tap(find.text('테스트 도구'));
    await tester.pumpAndSettle();
    await settle(tester);
    await tester.tap(find.text('비'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('없음').last);
    await tester.pumpAndSettle();
    await settle(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text('알림 테스트, 백그라운드 실행, 예보 가정'), findsOneWidget);
  });
}
