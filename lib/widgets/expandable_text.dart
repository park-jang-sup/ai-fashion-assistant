import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

// 눌러서 전체를 펼치는 글 — docs/task_demo_flow_v1.md §9 (3). 에이전트가 준비한 코디
// 설명("1. 코디 분위기: …")이 두 줄에서 잘리고 전체를 볼 방법이 없었다. 피팅룸의 색상
// 팁처럼 그 자리에서 펼친다(아래에서 올라오는 창이 아니라 인라인이라, 글자를 키운
// 기기에서도 화면 스크롤로 끝까지 읽고 "접기"로 닫을 수 있다). 글이 줄 수를 넘지 않으면
// 펼치기 표시 없이 그대로 보인다. 글 자체는 바꾸지 않는다.
class ExpandableText extends StatefulWidget {
  final String text;
  final int collapsedMaxLines;
  final TextStyle style;

  const ExpandableText(
    this.text, {
    super.key,
    this.collapsedMaxLines = 2,
    this.style = const TextStyle(color: AppColors.textSecondary, fontSize: 13),
  });

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: widget.collapsedMaxLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      final text = Text(
        widget.text,
        maxLines: _expanded ? null : widget.collapsedMaxLines,
        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        style: widget.style,
      );
      if (!overflows) return text;
      // 자기 탭을 먼저 받아 카드 전체의 탭(예: 홈 카드 → 피팅룸 이동)과 겹치지 않게 한다.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            const SizedBox(height: 4),
            Text(_expanded ? '접기' : '전체 보기',
                style: const TextStyle(color: AppColors.blue, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      );
    });
  }
}

// 데모 옷장의 예시 일정·그 추천 표시 — §9 (2). 사용자가 넣지 않은 일정이 "에이전트가
// 준비한 코디"로만 떠 있어 당황했다.
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.amberPale,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text('예시',
          style: TextStyle(color: AppColors.amber, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}
