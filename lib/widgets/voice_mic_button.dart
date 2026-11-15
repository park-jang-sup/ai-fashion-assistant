import 'dart:math' as math;

import 'package:flutter/material.dart';

// 마이크 버튼 — 듣는 중이면 마이크를 감싼 원이 소리 크기(0~1)에 따라 커졌다 작아진다.
// 소리 크기 값이 오지 않는 기기에서는(levelSeen == false) 일정한 속도로 부드럽게 맥박친다.
// 꺼져 있으면 움직이지 않는다. 켜짐은 빨강, 꺼짐은 회색.
// 원은 Transform으로만 커져 자리를 차지하지 않는다 — 입력창과 보내기 버튼이 밀리지 않는다.

const voiceRingMinScale = 0.75;
const voiceRingMaxScale = 1.35;

// 소리 크기 → 원의 크기.
double voiceRingScale(double level) =>
    voiceRingMinScale + (voiceRingMaxScale - voiceRingMinScale) * level.clamp(0.0, 1.0);

class VoiceMicButton extends StatefulWidget {
  final bool listening;
  final ValueNotifier<double> level;
  final bool Function() levelSeen;
  final VoidCallback onPressed;
  const VoiceMicButton(
      {super.key, required this.listening, required this.level, required this.levelSeen, required this.onPressed});

  @override
  State<VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends State<VoiceMicButton> with SingleTickerProviderStateMixin {
  // 소리 크기 값이 없을 때의 맥박(1.2초 주기).
  late final AnimationController _pulse;
  double _shown = 0; // 부드럽게 따라가는 소리 크기

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    if (widget.listening) _pulse.repeat();
  }

  @override
  void didUpdateWidget(VoiceMicButton old) {
    super.didUpdateWidget(old);
    if (widget.listening && !_pulse.isAnimating) _pulse.repeat();
    if (!widget.listening && _pulse.isAnimating) {
      _pulse.stop();
      _shown = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  double _scale() {
    if (!widget.listening) return 1;
    if (!widget.levelSeen()) {
      final t = (1 - math.cos(_pulse.value * 2 * math.pi)) / 2; // 0→1→0
      return voiceRingScale(0.15 + 0.5 * t);
    }
    _shown += (widget.level.value - _shown) * 0.35;
    return voiceRingScale(_shown);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.listening;
    return IconButton(
      tooltip: on ? '듣기 멈추기' : '말로 입력',
      isSelected: on,
      onPressed: widget.onPressed,
      icon: SizedBox(
        width: 24,
        height: 24,
        child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
          if (on)
            AnimatedBuilder(
              animation: Listenable.merge([_pulse, widget.level]),
              builder: (_, __) => Transform.scale(
                key: const Key('voice-ring'),
                scale: _scale(),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.red.withValues(alpha: 0.18)),
                ),
              ),
            ),
          Icon(on ? Icons.mic : Icons.mic_none, color: on ? Colors.red : Colors.grey.shade600),
        ]),
      ),
    );
  }
}
