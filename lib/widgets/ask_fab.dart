import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/ask_controller.dart';
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
  const AskFab({super.key, required this.controller, required this.onTap, this.showBubble = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.buttonState;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showBubble)
              Container(
                key: const Key('ask-fab-bubble'),
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.navy,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('AI에게 부탁하기',
                    style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
            Semantics(
              button: true,
              label: 'AI에게 부탁하기',
              child: GestureDetector(
                onTap: onTap,
                child: SizedBox(
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
          ],
        );
      },
    );
  }
}
