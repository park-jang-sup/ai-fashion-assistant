// 추천 카드 "AI 추천" 표시 — docs/task_demo_flow_v1.md §10-3.
import 'package:ai_fashion_assistant/screens/fitting_room_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('글에 나온 옷은 진한 모양, 나머지는 같은 글자의 옅은 모양(색만 다름)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Column(children: [AiRecommendBadge(strong: true), AiRecommendBadge(strong: false)])),
    ));
    expect(find.text('AI 추천'), findsNWidgets(2));
    final texts = tester.widgetList<Text>(find.text('AI 추천')).toList();
    expect(texts[0].style!.color, isNot(texts[1].style!.color));
    final boxes = tester
        .widgetList<Container>(find.ancestor(of: find.text('AI 추천'), matching: find.byType(Container)))
        .map((c) => (c.decoration as BoxDecoration).color)
        .toList();
    expect(boxes[0], isNot(boxes[1]));
  });
}
