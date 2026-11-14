import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

// AI에게 부탁하기 마스코트(docs/task_agent_ask_v1.md §2-5) — 원형으로 잘라 쓴다.
// 이미지를 불러오지 못하면 기본 아이콘으로 대체해 화면이 깨지지 않게 한다.
class AgentMascot extends StatelessWidget {
  static const asset = 'assets/images/agent_mascot.png';
  final double size;
  const AgentMascot({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          color: AppColors.bluePale,
          alignment: Alignment.center,
          child: Icon(Icons.smart_toy_outlined, size: size * 0.6, color: AppColors.blue),
        ),
      ),
    );
  }
}
