import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_colors.dart';
import '../constants/tpo_tags.dart';
import '../models/agent_log_entry.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/outfit_history_entry.dart';
import '../models/wardrobe_item.dart';
import '../services/agent_planner.dart';
import '../services/firestore_service.dart';
import 'signed_network_image.dart';

// 착장 기록 바텀시트 — 캘린더 화면과 스크랩 화면이 공용으로 연다.
// (a) TPO 태그 선택 (b) 착장 소스 선택: 최근 가상 피팅 결과에서 고르거나
// 옷장에서 옷 2벌 이상 직접 선택 (c) 저장. 저장 성공 시 true를 반환한다.
//
// prefill* 인자는 스크랩 화면에서 "캘린더에 기록"으로 진입할 때, 그 스크랩의
// 피팅 이미지/아이템을 미리 채워 넣기 위한 것이다.
Future<bool?> showCalendarRecordSheet(
  BuildContext context, {
  required DateTime date,
  String? prefillImageUrl,
  String? prefillCacheKey,
  List<String> prefillItemIds = const [],
  List<String> prefillItemSummaries = const [],
  String? recommendationId,
  // 예정(planned) 일정을 기록으로 전환할 때만 채운다. 있으면 새 문서를
  // 만드는 대신 이 id의 문서를 recorded로 업데이트한다.
  String? existingEntryId,
  // 예정 일정은 이미 TPO 태그가 정해져 있으므로 다시 고르지 않아도 되게
  // 미리 선택해둔다(그래도 바꾸고 싶으면 바꿀 수 있음).
  String? initialTpoTag,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CalendarRecordSheet(
      date: date,
      prefillImageUrl: prefillImageUrl,
      prefillCacheKey: prefillCacheKey,
      prefillItemIds: prefillItemIds,
      prefillItemSummaries: prefillItemSummaries,
      recommendationId: recommendationId,
      existingEntryId: existingEntryId,
      initialTpoTag: initialTpoTag,
    ),
  );
}

class _CalendarRecordSheet extends StatefulWidget {
  final DateTime date;
  final String? prefillImageUrl;
  final String? prefillCacheKey;
  final List<String> prefillItemIds;
  final List<String> prefillItemSummaries;
  final String? recommendationId;
  final String? existingEntryId;
  final String? initialTpoTag;

  const _CalendarRecordSheet({
    required this.date,
    this.prefillImageUrl,
    this.prefillCacheKey,
    this.prefillItemIds = const [],
    this.prefillItemSummaries = const [],
    this.recommendationId,
    this.existingEntryId,
    this.initialTpoTag,
  });

  @override
  State<_CalendarRecordSheet> createState() => _CalendarRecordSheetState();
}

// 착장 소스: 최근 피팅 결과 하나를 고른 상태 vs 옷장에서 직접 고른 상태.
class _CalendarRecordSheetState extends State<_CalendarRecordSheet> {
  late String _tpo;
  bool _saving = false;

  // 최근 피팅에서 선택된 항목(있으면 옷장 선택보다 우선).
  OutfitHistoryEntry? _selectedFitting;
  String? _prefillImageUrl; // 스크랩에서 넘어온 이미지(피팅 목록에 없을 수도 있음)

  // 옷장 직접 선택 모드에서 고른 아이템 id들.
  final Set<String> _selectedItemIds = {};

  late Future<_SheetData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _tpo = widget.initialTpoTag ?? TpoTags.labels.last;
    _prefillImageUrl = widget.prefillImageUrl;
    if (widget.prefillItemIds.isNotEmpty) {
      _selectedItemIds.addAll(widget.prefillItemIds);
    }
    _dataFuture = _loadData();
  }

  Future<_SheetData> _loadData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const _SheetData(fittings: [], wardrobe: []);
    final results = await Future.wait([
      FirestoreService.getRecentHistorySilently(uid, limit: 50),
      FirestoreService.wardrobeStream(uid).first,
    ]);
    final history = results[0] as List<OutfitHistoryEntry>;
    final wardrobe = results[1] as List<WardrobeItem>;
    // 가상 피팅 결과(이미지 있는 것)만, URL 기준 중복 제거.
    final seen = <String>{};
    final fittings = history
        .where((e) =>
            e.type == OutfitHistoryEntry.typeFitting &&
            e.fittingImageUrl != null &&
            seen.add(e.fittingImageUrl!))
        .take(15)
        .toList();
    return _SheetData(fittings: fittings, wardrobe: wardrobe);
  }

  bool get _canSave {
    if (_selectedFitting != null || _prefillImageUrl != null) return true;
    return _selectedItemIds.length >= 2; // 옷장 직접 선택은 2벌 이상
  }

  Future<void> _save(List<WardrobeItem> wardrobe) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || !_canSave || _saving) return;
    setState(() => _saving = true);

    // 착장 소스 확정: 피팅 우선, 없으면 옷장 선택.
    String? imageUrl;
    String? cacheKey;
    List<String> itemIds;
    List<String> itemSummaries;
    if (_selectedFitting != null) {
      imageUrl = _selectedFitting!.fittingImageUrl;
      cacheKey = _selectedFitting!.fittingCacheKey;
      itemIds = _selectedFitting!.items.map((i) => i.id).toList();
      itemSummaries = _selectedFitting!.items
          .map((i) => '${i.category}: ${i.color ?? ''}'.trim())
          .toList();
    } else if (_prefillImageUrl != null) {
      imageUrl = _prefillImageUrl;
      cacheKey = widget.prefillCacheKey;
      itemIds = widget.prefillItemIds;
      itemSummaries = widget.prefillItemSummaries;
    } else {
      final byId = {for (final w in wardrobe) w.id: w};
      final picked = _selectedItemIds.map((id) => byId[id]).whereType<WardrobeItem>().toList();
      itemIds = picked.map((i) => i.id).toList();
      itemSummaries =
          picked.map((i) => '${i.category}: ${i.attributes?.color ?? ''}'.trim()).toList();
    }

    final source = widget.recommendationId != null
        ? OutfitCalendarEntry.sourceAgent
        : OutfitCalendarEntry.sourceManual;
    final entry = OutfitCalendarEntry(
      id: widget.existingEntryId ?? '',
      date: widget.date,
      tpoTag: _tpo,
      fittingImageUrl: imageUrl,
      fittingCacheKey: cacheKey,
      itemIds: itemIds,
      itemSummaries: itemSummaries,
      source: source,
      recommendationId: widget.recommendationId,
      status: OutfitCalendarEntry.statusRecorded,
      createdAt: DateTime.now(),
    );

    try {
      String docId;
      if (widget.existingEntryId != null) {
        // 예정 → 기록 전환: 새 문서 대신 기존 예정 문서를 업데이트한다.
        await FirestoreService.updateCalendarEntry(
          uid,
          widget.existingEntryId!,
          status: OutfitCalendarEntry.statusRecorded,
          fittingImageUrl: imageUrl,
          fittingCacheKey: cacheKey,
          itemIds: itemIds,
          itemSummaries: itemSummaries,
          source: source,
          recommendationId: widget.recommendationId,
        );
        docId = widget.existingEntryId!;
      } else {
        docId = await FirestoreService.addCalendarEntry(uid, entry);
      }
      // 활동 로그: 착장 기록은 취향 학습의 재료라 에이전트 서사에도 남긴다.
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCalendarLogged,
          message:
              '${widget.date.month}/${widget.date.day} [$_tpo] 착장이 기록되었습니다 — 에이전트가 취향 학습에 활용합니다',
          relatedDocId: widget.recommendationId ?? docId,
        ),
      ));
      // 레벨 3: 이 날짜/태그의 추천과 대조해 채택/불일치 피드백을 감지·기록한다.
      unawaited(AgentPlanner.detectFeedbackForCalendarEntry(uid, entry));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('기록 실패: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return FutureBuilder<_SheetData>(
            future: _dataFuture,
            builder: (context, snapshot) {
              final data = snapshot.data;
              return Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                    child: Row(
                      children: [
                        Text(
                          '${widget.date.month}월 ${widget.date.day}일 착장 기록',
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: const Icon(Icons.close, color: AppColors.textMuted, size: 22),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: data == null
                        ? const Center(
                            child: CircularProgressIndicator(
                                color: AppColors.navy, strokeWidth: 2))
                        : ListView(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                            children: [
                              _sectionLabel('TPO 태그'),
                              const SizedBox(height: 8),
                              _tpoChips(),
                              const SizedBox(height: 20),
                              _sectionLabel('착장 선택'),
                              const SizedBox(height: 4),
                              const Text(
                                '최근 가상 피팅 결과에서 고르거나, 옷장에서 2벌 이상 선택하세요',
                                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                              ),
                              const SizedBox(height: 12),
                              _fittingStrip(data.fittings),
                              const SizedBox(height: 18),
                              const Row(children: [
                                Expanded(child: Divider(color: AppColors.divider)),
                                Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 10),
                                  child: Text('또는 옷장에서 직접',
                                      style: TextStyle(
                                          color: AppColors.textPlaceholder, fontSize: 12)),
                                ),
                                Expanded(child: Divider(color: AppColors.divider)),
                              ]),
                              const SizedBox(height: 12),
                              _wardrobeGrid(data.wardrobe),
                            ],
                          ),
                  ),
                  _saveBar(data?.wardrobe ?? const []),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: const TextStyle(
            color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
      );

  Widget _tpoChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: TpoTags.all.map((tag) {
        final selected = _tpo == tag.label;
        return GestureDetector(
          onTap: () => setState(() => _tpo = tag.label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? tag.color.withValues(alpha: 0.12) : AppColors.background,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? tag.color : AppColors.border,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(tag.icon, size: 15, color: selected ? tag.color : AppColors.textMuted),
                const SizedBox(width: 5),
                Text(
                  tag.label,
                  style: TextStyle(
                    color: selected ? tag.color : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _fittingStrip(List<OutfitHistoryEntry> fittings) {
    // 스크랩에서 넘어온 프리필 이미지는 목록에 없어도 첫 칸에 선택된 상태로 보여준다.
    final hasPrefill = _prefillImageUrl != null && _selectedFitting == null;
    if (fittings.isEmpty && !hasPrefill) {
      return Container(
        height: 60,
        alignment: Alignment.center,
        child: const Text('최근 가상 피팅 결과가 없어요',
            style: TextStyle(color: AppColors.textPlaceholder, fontSize: 13)),
      );
    }
    return SizedBox(
      height: 150,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          if (hasPrefill) _fittingThumb(imageUrl: _prefillImageUrl!, selected: true, onTap: () {}),
          ...fittings.map((f) {
            final selected = identical(_selectedFitting, f);
            return _fittingThumb(
              imageUrl: f.fittingImageUrl!,
              cacheKey: f.fittingCacheKey,
              selected: selected,
              onTap: () => setState(() {
                _selectedFitting = selected ? null : f;
                _prefillImageUrl = null; // 목록에서 고르면 프리필은 해제
                if (_selectedFitting != null) _selectedItemIds.clear();
              }),
            );
          }),
        ],
      ),
    );
  }

  Widget _fittingThumb({
    required String imageUrl,
    String? cacheKey,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.blue : AppColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: cacheKey != null
                  ? SignedNetworkImage(
                      collection: 'fitting_cache',
                      id: cacheKey,
                      fallbackUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.background),
                      errorWidget: (_, __, ___) => Container(
                        color: AppColors.background,
                        child: const Icon(Icons.image_outlined, color: AppColors.textDisabled),
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.background),
                      errorWidget: (_, __, ___) => Container(
                        color: AppColors.background,
                        child: const Icon(Icons.image_outlined, color: AppColors.textDisabled),
                      ),
                    ),
            ),
            if (selected)
              const Positioned(
                top: 6,
                right: 6,
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: AppColors.blue,
                  child: Icon(Icons.check, color: Colors.white, size: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _wardrobeGrid(List<WardrobeItem> wardrobe) {
    // 피팅을 고른 상태에선 옷장 직접 선택을 비활성(둘 중 하나만).
    final disabled = _selectedFitting != null || _prefillImageUrl != null;
    if (wardrobe.isEmpty) {
      return Container(
        height: 60,
        alignment: Alignment.center,
        child: const Text('옷장에 등록된 옷이 없어요',
            style: TextStyle(color: AppColors.textPlaceholder, fontSize: 13)),
      );
    }
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 0.8,
        ),
        itemCount: wardrobe.length,
        itemBuilder: (context, i) {
          final item = wardrobe[i];
          final selected = _selectedItemIds.contains(item.id);
          return GestureDetector(
            onTap: disabled
                ? null
                : () => setState(() {
                      if (selected) {
                        _selectedItemIds.remove(item.id);
                      } else {
                        _selectedItemIds.add(item.id);
                      }
                    }),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? AppColors.blue : AppColors.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: SignedNetworkImage(
                      collection: 'wardrobe',
                      id: item.id,
                      urlIndex: item.cutoutImageUrl != null ? 1 : 0,
                      fallbackUrl: item.cutoutImageUrl ?? item.imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.background),
                      errorWidget: (_, __, ___) => Container(color: AppColors.background),
                    ),
                  ),
                  if (selected)
                    const Positioned(
                      top: 4,
                      right: 4,
                      child: CircleAvatar(
                        radius: 8,
                        backgroundColor: AppColors.blue,
                        child: Icon(Icons.check, color: Colors.white, size: 11),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _saveBar(List<WardrobeItem> wardrobe) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 10, 20, 10 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: _canSave && !_saving ? () => _save(wardrobe) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.black,
            disabledBackgroundColor: AppColors.border,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('이 날에 기록하기',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

class _SheetData {
  final List<OutfitHistoryEntry> fittings;
  final List<WardrobeItem> wardrobe;
  const _SheetData({required this.fittings, required this.wardrobe});
}
