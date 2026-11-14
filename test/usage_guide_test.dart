// 첫 실행 사용 가이드 — docs/task_demo_flow_v1.md 부분 C.
import 'package:ai_fashion_assistant/screens/usage_guide_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, {double textScale = 1.0}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: const UsageGuideScreen(),
      ),
    ),
  ));
}

void main() {
  group('띄울지 — 계정 단위(§4-1)', () {
    bool show(String uid, {Set<String> dismissed = const {}, Set<String> shown = const {}}) =>
        UsageGuide.shouldShow(uid: uid, dismissedUids: dismissed, shownThisLaunch: shown);
    test('새 계정은 뜬다', () => expect(show('new'), isTrue));
    test('"다시 보지 않기"를 누른 계정은 안 뜬다(새 실행에서도)', () {
      expect(show('a', dismissed: {'a'}), isFalse);
    });
    test('"닫기"만 누른 계정은 같은 실행에서 안 뜨고 새 실행에서 뜬다', () {
      expect(show('a', shown: {'a'}), isFalse);
      expect(show('a'), isTrue, reason: '새 실행 = 이번 실행 기억이 빈 상태');
    });
    test('다른 계정의 선택은 영향을 주지 않는다', () {
      expect(show('b', dismissed: {'a'}, shown: {'a'}), isTrue);
    });
    test('"다시 보지 않기" 저장 키에 uid가 들어간다', () {
      expect(UsageGuide.dismissFileNameFor('abc'), 'usage_guide_dismissed_abc.txt');
      expect(UsageGuide.dismissFileNameFor('abc'), isNot(UsageGuide.dismissFileNameFor('xyz')));
    });
  });

  test('1쪽 — 데모 옷장 예시 일정 안내(§9 (2))', () {
    expect(UsageGuide.pages[0].body, contains('데모 옷장을 불러오면 내일 예시 일정이 함께 들어가요'));
  });

  test('4쪽 — AI에게 부탁하기 한 문장(docs/task_agent_ask_v1.md §2-5)', () {
    expect(UsageGuide.pages[3].body, contains('화면의 AI 비서 버튼을 눌러 말로 부탁할 수도 있어요'));
  });

  test('다섯 쪽, 지시서 순서', () {
    expect(UsageGuide.pages.map((p) => p.title).toList(), [
      '내 옷장을 아는 AI 비서',
      '코디 분석',
      '가상 피팅',
      '일정을 넣으면 미리 준비',
      'AI가 한 일 보기',
    ]);
  });

  testWidgets('왼쪽 아래 다시 보지 않기, 오른쪽 아래 닫기 — 마지막 쪽은 시작하기', (tester) async {
    await _pump(tester);
    expect(find.text('다시 보지 않기'), findsOneWidget);
    expect(find.text('닫기'), findsOneWidget);
    expect(tester.getCenter(find.text('다시 보지 않기')).dx, lessThan(180));
    expect(tester.getCenter(find.text('닫기')).dx, greaterThan(180));
    for (var i = 0; i < UsageGuide.pages.length - 1; i++) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
    }
    expect(find.text('시작하기'), findsOneWidget);
    expect(find.text('닫기'), findsNothing);
  });

  testWidgets('글자를 두 배로 키워도 넘침 없이 버튼이 보인다', (tester) async {
    await _pump(tester, textScale: 2.0);
    for (var i = 0; i < UsageGuide.pages.length; i++) {
      expect(tester.takeException(), isNull);
      expect(find.text('다시 보지 않기').hitTestable(), findsOneWidget);
      if (i < UsageGuide.pages.length - 1) {
        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pumpAndSettle();
      }
    }
    expect(find.text('시작하기').hitTestable(), findsOneWidget);
  });
}
