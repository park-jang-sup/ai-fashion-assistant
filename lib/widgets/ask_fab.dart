import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/ask_controller.dart';
import '../services/ask_fab_prefs.dart';
import 'agent_mascot.dart';

// AI에게 부탁하기 떠 있는 마스코트 버튼(docs/task_agent_ask_v1.md §10 A·B). AskController를 구독만
// 한다 — 진행 중이면 고리, 사용자 차례(확인·질문)이거나 새 답이 있으면 점, 평소엔 마스코트만.

// 탭별 자리(AppShell 본문 Stack 기준, 아래쪽 탐색 막대 위). 기본은 오른쪽 아래, 가상 피팅 진행
// 표시(오른쪽 아래 16px, 56px)의 위. 옷장은 추가 버튼(오른쪽 20px, 아래 74px, 56px) 위로,
// 피팅룸은 스크롤하는 분석 버튼과 겹치지 않게 고정 머리글의 오른쪽 위로 옮긴다.
class AskFabPlacement {
  final double right;
  final double? top;
  final double? bottom;
  const AskFabPlacement({required this.right, this.top, this.bottom});
}

const askFabSize = 52.0;

AskFabPlacement askFabPlacementFor(int tab) => switch (tab) {
      1 => const AskFabPlacement(right: 18, bottom: 142), // 옷장: 추가 버튼(아래 74~130) 위, 가운데 맞춤
      2 => const AskFabPlacement(right: 20, top: 18), // 피팅룸: 머리글 오른쪽 빈자리
      _ => const AskFabPlacement(right: 18, bottom: 84), // 홈·캘린더·설정: 가상 피팅 진행 표시 위
    };

class AskFab extends StatelessWidget {
  final AskController controller;
  final VoidCallback onTap;
  final bool showBubble;
  final bool bubbleOnRight; // 왼쪽 가장자리에 붙었으면 말풍선을 오른쪽에
  final Key? circleKey;
  const AskFab(
      {super.key,
      required this.controller,
      required this.onTap,
      this.showBubble = false,
      this.bubbleOnRight = false,
      this.circleKey});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.buttonState;
        final bubble = Container(
          key: const Key('ask-fab-bubble'),
          margin: bubbleOnRight ? const EdgeInsets.only(left: 8) : const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.navy,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Text('AI에게 부탁하기',
              style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showBubble && !bubbleOnRight) bubble,
            Semantics(
              button: true,
              label: 'AI에게 부탁하기',
              child: GestureDetector(
                onTap: onTap,
                child: SizedBox(
                  key: circleKey,
                  width: askFabSize + 8,
                  height: askFabSize + 8,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: askFabSize,
                        height: askFabSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.22),
                                blurRadius: 10,
                                offset: const Offset(0, 4)),
                          ],
                        ),
                        child: const AgentMascot(size: askFabSize - 4),
                      ),
                      if (state == AskButtonState.running)
                        const SizedBox(
                          key: Key('ask-fab-ring'),
                          width: askFabSize + 6,
                          height: askFabSize + 6,
                          child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.blue),
                        ),
                      if (state == AskButtonState.attention)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: Container(
                            key: const Key('ask-fab-dot'),
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: AppColors.red,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (showBubble && bubbleOnRight) bubble,
          ],
        );
      },
    );
  }
}

// 끌어서 옮길 수 있는 떠 있는 버튼(docs/task_agent_ask_v2.md §2-G). 본문 Stack(하단 탭 위 영역)
// 안으로만 움직이고, 놓으면 가까운 좌우 가장자리에 붙는다. 옮긴 자리는 계정별로 기기에 저장해
// 모든 탭에 쓰고, 옮긴 적이 없으면 탭별 기본 자리(askFabPlacementFor)를 쓴다. Stack의 직계
// 자식으로 Positioned를 돌려준다(_FloatingFittingIcon과 같은 방식).
const askFabSideEdge = 18.0; // 좌우 가장자리 거리(기본 자리의 right와 같다)
const askFabVerticalEdge = 8.0;

class MovableAskFab extends StatefulWidget {
  final AskController controller;
  final VoidCallback onTap;
  final bool showBubble;
  final int tab;
  final double maxWidth;
  final double maxHeight;
  final String? uid;
  final AskFabSpotStore store;
  const MovableAskFab({
    super.key,
    required this.controller,
    required this.onTap,
    required this.tab,
    required this.maxWidth,
    required this.maxHeight,
    required this.uid,
    this.showBubble = false,
    this.store = const AskFabPrefs(),
  });

  @override
  State<MovableAskFab> createState() => _MovableAskFabState();
}

class _MovableAskFabState extends State<MovableAskFab> {
  static const _box = askFabSize + 8;
  final _circleKey = GlobalKey();
  AskFabSpot? _spot;
  Offset? _drag; // 끄는 동안의 왼쪽 위(본문 Stack 기준)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MovableAskFab old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) {
      _spot = null;
      _load();
    }
  }

  Future<void> _load() async {
    final uid = widget.uid;
    if (uid == null) return;
    final spot = await widget.store.load(uid);
    if (mounted && uid == widget.uid && _drag == null) setState(() => _spot = spot);
  }

  double get _maxLeft => (widget.maxWidth - _box - askFabSideEdge).clamp(askFabSideEdge, double.infinity);
  double get _maxTop => (widget.maxHeight - _box - askFabVerticalEdge).clamp(askFabVerticalEdge, double.infinity);

  void _start(DragStartDetails _) {
    final circle = _circleKey.currentContext?.findRenderObject() as RenderBox?;
    final stack = (context.findRenderObject() as RenderBox?)?.parent as RenderBox?;
    if (circle == null || stack == null) return;
    final o = circle.localToGlobal(Offset.zero, ancestor: stack);
    setState(() => _drag = Offset(o.dx.clamp(askFabSideEdge, _maxLeft), o.dy.clamp(askFabVerticalEdge, _maxTop)));
  }

  void _update(DragUpdateDetails d) {
    final p = _drag;
    if (p == null) return;
    setState(() => _drag = Offset((p.dx + d.delta.dx).clamp(askFabSideEdge, _maxLeft),
        (p.dy + d.delta.dy).clamp(askFabVerticalEdge, _maxTop)));
  }

  // 놓으면 가까운 좌우 가장자리에 붙이고 저장한다.
  void _end() {
    final p = _drag;
    if (p == null) return;
    final spot = AskFabSpot(left: p.dx + _box / 2 < widget.maxWidth / 2, top: p.dy);
    setState(() {
      _drag = null;
      _spot = spot;
    });
    final uid = widget.uid;
    if (uid != null) widget.store.save(uid, spot);
  }

  @override
  Widget build(BuildContext context) {
    final drag = _drag;
    final spot = _spot;
    Widget fab({required bool bubbleOnRight, bool bubble = true}) => GestureDetector(
          onPanStart: _start,
          onPanUpdate: _update,
          onPanEnd: (_) => _end(),
          onPanCancel: _end,
          child: AskFab(
            controller: widget.controller,
            onTap: widget.onTap,
            showBubble: widget.showBubble && bubble,
            bubbleOnRight: bubbleOnRight,
            circleKey: _circleKey,
          ),
        );
    if (drag != null) {
      return Positioned(left: drag.dx, top: drag.dy, child: fab(bubbleOnRight: false, bubble: false));
    }
    if (spot != null) {
      return Positioned(
        left: spot.left ? askFabSideEdge : null,
        right: spot.left ? null : askFabSideEdge,
        top: spot.top.clamp(askFabVerticalEdge, _maxTop),
        child: fab(bubbleOnRight: spot.left),
      );
    }
    final p = askFabPlacementFor(widget.tab);
    return Positioned(right: p.right, top: p.top, bottom: p.bottom, child: fab(bubbleOnRight: false));
  }
}
