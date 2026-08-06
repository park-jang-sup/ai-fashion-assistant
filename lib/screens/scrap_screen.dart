import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_colors.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/scrap_entry.dart';
import '../services/firestore_service.dart';
import '../widgets/calendar_record_sheet.dart';
import '../widgets/full_screen_image_viewer.dart';
import '../widgets/signed_network_image.dart';

// 설정 화면 "내 스크랩"에서 진입 — 피팅룸에서 북마크한 가상 피팅 결과를
// 전체 목록으로 모아본다.
class ScrapScreen extends StatelessWidget {
  const ScrapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
        title: const Text('내 스크랩',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const Center(
              child: Text('로그인이 필요합니다',
                  style: TextStyle(color: AppColors.textMuted)))
          : StreamBuilder<List<ScrapEntry>>(
              stream: FirestoreService.scrapStream(uid),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(
                          color: AppColors.navy, strokeWidth: 2));
                }
                final entries = snapshot.data ?? const <ScrapEntry>[];
                if (entries.isEmpty) return const _EmptyState();

                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _ScrapCard(uid: uid, entry: entries[i]),
                );
              },
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                  color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.bookmark_border,
                  color: AppColors.textDisabled, size: 28),
            ),
            const SizedBox(height: 18),
            const Text('아직 스크랩한 착장이 없어요',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('AI 피팅에서 마음에 드는 결과를 저장해보세요',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13, height: 1.5)),
          ],
        ),
      ),
    );
  }
}

class _ScrapCard extends StatelessWidget {
  final String uid;
  final ScrapEntry entry;

  const _ScrapCard({required this.uid, required this.entry});

  // itemSummaries는 "카테고리: 속성..." 형태라, 카드에는 카테고리만 뽑아
  // "상의, 하의" 처럼 짧게 보여준다.
  String _summaryLine() {
    if (entry.itemSummaries.isEmpty) return '코디 조합';
    return entry.itemSummaries.map((s) => s.split(':').first.trim()).join(', ');
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('스크랩 삭제',
            style: TextStyle(
                color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
        content: const Text('이 스크랩을 삭제하시겠습니까?',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소',
                style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제',
                style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await FirestoreService.deleteScrap(uid, entry.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('삭제 실패: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  // 스크랩을 특정 날짜의 착장으로 캘린더에 기록. 날짜를 먼저 고른 뒤,
  // 캘린더 화면과 같은 바텀시트를 이 스크랩의 이미지/아이템으로 프리필해 연다.
  Future<void> _recordToCalendar(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: '착장을 입은 날짜 선택',
    );
    if (picked == null || !context.mounted) return;
    final saved = await showCalendarRecordSheet(
      context,
      date: OutfitCalendarEntry.normalizeDate(picked),
      prefillImageUrl: entry.fittingImageUrl,
      prefillCacheKey: entry.fittingCacheKey,
      prefillItemIds: entry.itemIds,
      prefillItemSummaries: entry.itemSummaries,
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('캘린더에 착장을 기록했어요'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.blue,
      ));
    }
  }

  void _openFullScreen(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => FullScreenImageViewer(
          imageUrl: entry.fittingImageUrl,
          label: '스크랩한 착장',
          signedCollection: entry.fittingCacheKey != null ? 'fitting_cache' : null,
          signedId: entry.fittingCacheKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openFullScreen(context),
      onLongPress: () => _confirmDelete(context),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
                color: AppColors.navy.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                    child: entry.fittingCacheKey != null
                        ? SignedNetworkImage(
                            collection: 'fitting_cache',
                            id: entry.fittingCacheKey!,
                            fallbackUrl: entry.fittingImageUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: AppColors.background),
                            errorWidget: (_, __, ___) => Container(
                              color: AppColors.background,
                              child: const Icon(Icons.image_outlined, color: AppColors.textDisabled),
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: entry.fittingImageUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: AppColors.background),
                            errorWidget: (_, __, ___) => Container(
                              color: AppColors.background,
                              child: const Icon(Icons.image_outlined, color: AppColors.textDisabled),
                            ),
                          ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: () => _confirmDelete(context),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, color: Colors.white, size: 14),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: GestureDetector(
                      onTap: () => _recordToCalendar(context),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.event_available, color: Colors.white, size: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                _summaryLine(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
