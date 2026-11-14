// 눌러서 전체를 펼치는 글·예시 표시 — docs/task_demo_flow_v1.md §9 (2)(3).
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/widgets/expandable_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _long = '1. 코디 분위기: 화이트, 차콜, 블랙으로 구성된 모노톤 조합이라 깔끔하고 도회적인 미니멀 무드가 살아납니다. '
    '오버사이즈 실루엣이 반복되어 힘을 뺀 세련된 스트리트 감성이 있고, 스트라이프 슬랙스가 단조로움을 덜어줍니다.\n'
    '2. 신발 추천: 블랙 가죽 로퍼는 포멀한 하의와 블레이저에 격식을 맞춰 전체 균형을 잡아줍니다. 마지막문장끝';

Future<void> _pump(WidgetTester tester, String text, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: ExpandableText(text)))),
      ),
    ),
  ));
}

int? _maxLines(WidgetTester tester) => tester.widget<Text>(find.byType(Text).first).maxLines;

void main() {
  testWidgets('긴 글은 두 줄로 접혀 있다가 누르면 전체, 다시 누르면 접힌다', (tester) async {
    await _pump(tester, _long);
    expect(_maxLines(tester), 2);
    expect(find.text('전체 보기'), findsOneWidget);
    await tester.tap(find.text('전체 보기'));
    await tester.pump();
    expect(_maxLines(tester), isNull);
    expect(find.text('접기'), findsOneWidget);
    await tester.tap(find.text('접기'));
    await tester.pump();
    expect(_maxLines(tester), 2);
  });

  testWidgets('글자 크기 2배에서도 펼친 뒤 스크롤로 끝까지 보고 접을 수 있다', (tester) async {
    await _pump(tester, _long, scale: 2.0);
    await tester.tap(find.text('전체 보기'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('접기'), 100);
    expect(find.text('접기').hitTestable(), findsOneWidget);
    await tester.tap(find.text('접기'));
    await tester.pump();
    expect(_maxLines(tester), 2);
  });

  testWidgets('짧은 글은 펼치기 표시 없이 그대로', (tester) async {
    await _pump(tester, '짧은 설명');
    expect(find.text('전체 보기'), findsNothing);
  });

  testWidgets('예시 표시', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DemoBadge())));
    expect(find.text('예시'), findsOneWidget);
  });

  test('추천의 예보 조회 실패 표시(forecastMissing)는 켰을 때만 저장한다', () {
    RecommendationEntry rec({bool missing = false}) => RecommendationEntry(
        id: '', itemIds: const ['a'], itemSummaries: const [], summaryText: '', triggerItemId: '',
        createdAt: DateTime(2026), forecastMissing: missing);
    expect(rec().toFirestore().containsKey('forecastMissing'), isFalse);
    expect(rec(missing: true).toFirestore()['forecastMissing'], isTrue);
  });
}
