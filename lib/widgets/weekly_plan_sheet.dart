import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../constants/tpo_tags.dart';
import '../services/agent_planner.dart';
import 'signed_network_image.dart';

// 주간 코디 플랜 결과 시트 — 날짜별 조합 카드 리스트. 각 카드의 "이 코디로
// 확정"을 누르면 onConfirm으로 그 날 착장이 캘린더에 저장된다(중복 확정 방지로
// 확정한 카드는 비활성 표시).
Future<void> showWeeklyPlanSheet(
  BuildContext context, {
  required List<WeeklyPlanDay> plan,
  required Future<void> Function(WeeklyPlanDay day) onConfirm,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _WeeklyPlanSheet(plan: plan, onConfirm: onConfirm),
  );
}

class _WeeklyPlanSheet extends StatefulWidget {
  final List<WeeklyPlanDay> plan;
  final Future<void> Function(WeeklyPlanDay day) onConfirm;

  const _WeeklyPlanSheet({required this.plan, required this.onConfirm});

  @override
  State<_WeeklyPlanSheet> createState() => _WeeklyPlanSheetState();
}

class _WeeklyPlanSheetState extends State<_WeeklyPlanSheet> {
  final Set<int> _confirmed = {}; // 확정 완료된 카드 인덱스

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  String _dayLabel(WeeklyPlanDay d) =>
      '${d.date.month}/${d.date.day} (${_weekdays[d.date.weekday - 1]})';

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: AppColors.navy, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('이번 주 코디 플랜',
                        style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(Icons.close, color: AppColors.textMuted, size: 22),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('중복 없이 일정별로 배분했어요. 마음에 드는 날은 확정해 캘린더에 담아보세요.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.4)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                itemCount: widget.plan.length,
                itemBuilder: (context, i) => _planCard(i, widget.plan[i]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _planCard(int index, WeeklyPlanDay day) {
    final tag = TpoTags.byLabel(day.tpoTag);
    final confirmed = _confirmed.contains(index);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_dayLabel(day),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tag.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(tag.icon, size: 12, color: tag.color),
                    const SizedBox(width: 3),
                    Text(day.tpoTag,
                        style: TextStyle(
                            color: tag.color, fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            child: Row(
              children: day.items
                  .map((item) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SignedNetworkImage(
                            collection: 'wardrobe',
                            id: item.id,
                            urlIndex: item.cutoutImageUrl != null ? 1 : 0,
                            fallbackUrl: item.cutoutImageUrl ?? item.imageUrl,
                            width: 52,
                            height: 64,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: AppColors.surface),
                            errorWidget: (_, __, ___) => Container(color: AppColors.surface),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          if (day.reason.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(day.reason,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.5)),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: confirmed
                ? OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.check_circle, size: 16, color: AppColors.green),
                    label: const Text('캘린더에 저장됨',
                        style: TextStyle(
                            color: AppColors.green, fontSize: 13, fontWeight: FontWeight.w700)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.green),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  )
                : ElevatedButton(
                    onPressed: () async {
                      await widget.onConfirm(day);
                      if (mounted) setState(() => _confirmed.add(index));
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.navy,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('이 코디로 확정',
                        style: TextStyle(
                            color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
          ),
        ],
      ),
    );
  }
}
