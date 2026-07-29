import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:table_calendar/table_calendar.dart';
import '../constants/app_colors.dart';
import '../constants/tpo_tags.dart';
import '../models/agent_log_entry.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/wardrobe_item.dart';
import '../services/agent_planner.dart';
import '../services/firestore_service.dart';
import '../widgets/calendar_record_sheet.dart';
import '../widgets/weekly_plan_sheet.dart';

// 착장 캘린더(OOTD 기록) 탭. 월간 뷰에서 기록 있는 날에 마커를 찍고,
// 날짜를 누르면 그날 기록을 아래에 보여준다. 기록이 없으면 추가 버튼.
// 이 데이터는 이후 에이전트가 선제 추천/주간 플랜에 활용한다.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = OutfitCalendarEntry.normalizeDate(DateTime.now());
  bool _planning = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // 오늘 자정 기준. 미래 날짜인지 판정에 쓴다.
  DateTime get _today => OutfitCalendarEntry.normalizeDate(DateTime.now());
  bool _isFuture(DateTime day) => day.isAfter(_today);

  List<OutfitCalendarEntry> _entriesForDay(
      List<OutfitCalendarEntry> monthEntries, DateTime day) {
    return monthEntries.where((e) => isSameDay(e.date, day)).toList();
  }

  Future<void> _openRecordSheet() async {
    await showCalendarRecordSheet(context, date: _selectedDay);
    // 저장은 Firestore 스트림으로 자동 반영되므로 별도 새로고침이 필요 없다.
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: isError ? AppColors.red : AppColors.navy,
    ));
  }

  // ── 레벨 2: 주간 코디 플랜 ──────────────────────────────
  Future<void> _runWeeklyPlan() async {
    final uid = _uid;
    if (uid == null || _planning) return;
    setState(() => _planning = true);
    try {
      final plan = await AgentPlanner.generateWeeklyPlan(uid);
      if (!mounted) return;
      await showWeeklyPlanSheet(context, plan: plan, onConfirm: _confirmPlanDay);
    } on StateError catch (e) {
      _showSnack(e.message, isError: true);
    } catch (e) {
      _showSnack('플랜 생성 실패: $e', isError: true);
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  // 주간 플랜의 특정 날 조합을 그 날짜의 착장으로 확정 저장(source: agent).
  Future<void> _confirmPlanDay(WeeklyPlanDay day) async {
    final uid = _uid;
    if (uid == null) return;
    final entry = OutfitCalendarEntry(
      id: '',
      date: day.date,
      tpoTag: day.tpoTag,
      itemIds: day.items.map((i) => i.id).toList(),
      itemSummaries:
          day.items.map((i) => '${i.category}: ${i.attributes?.color ?? ''}'.trim()).toList(),
      source: OutfitCalendarEntry.sourceAgent,
      createdAt: DateTime.now(),
    );
    try {
      await FirestoreService.addCalendarEntry(uid, entry);
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCalendarLogged,
          message: '${day.date.month}/${day.date.day} [${day.tpoTag}] 주간 플랜 코디를 캘린더에 확정했습니다',
        ),
      ));
      // 레벨 3: 확정도 "그날의 실제 선택"이므로 추천과 대조해 피드백을 감지한다.
      unawaited(AgentPlanner.detectFeedbackForCalendarEntry(uid, entry));
      _showSnack('${day.date.month}/${day.date.day} 코디를 캘린더에 저장했어요');
    } catch (e) {
      _showSnack('저장 실패: $e', isError: true);
    }
  }

  // ── 미래 날짜: 일정(TPO) 태그만 먼저 등록 ────────────────
  Future<void> _registerScheduleTag() async {
    final uid = _uid;
    if (uid == null) return;
    final tpo = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _TpoPickerSheet(date: _selectedDay),
    );
    if (tpo == null) return;
    final entry = OutfitCalendarEntry(
      id: '',
      date: _selectedDay,
      tpoTag: tpo,
      status: OutfitCalendarEntry.statusPlanned,
      createdAt: DateTime.now(),
    );
    try {
      await FirestoreService.addCalendarEntry(uid, entry);
      _showSnack('${_selectedDay.month}/${_selectedDay.day} [$tpo] 일정을 등록했어요 — 에이전트가 코디를 준비합니다');
    } catch (e) {
      _showSnack('일정 등록 실패: $e', isError: true);
    }
  }

  Future<void> _confirmDelete(OutfitCalendarEntry entry) async {
    final uid = _uid;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('기록 삭제',
            style: TextStyle(
                color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
        content: const Text('이 착장 기록을 삭제하시겠습니까?',
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
      await FirestoreService.deleteCalendarEntry(uid, entry.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('삭제 실패: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  // 예정(planned) 일정 하나에 에이전트가 이미 준비해둔 선제 추천이 있는지
  // 확인한다. targetDate는 정확히 그 날짜로 만들어지므로(agent_planner.dart의
  // _prepareRecommendationFor) windowDays=0(정확히 그 날) 범위 조회를 재사용하고,
  // 태그 일치·아직 반응 없음만 클라이언트에서 거른다. 새 복합 인덱스 불필요.
  Future<RecommendationEntry?> _matchingRecommendationFor(OutfitCalendarEntry planned) async {
    final uid = _uid;
    if (uid == null) return null;
    final recs = await FirestoreService.recommendationsInDateRangeSilently(uid, planned.date, 0);
    final matches = recs
        .where((r) => r.targetTpoTag == planned.tpoTag && r.userChoice == null)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matches.isEmpty ? null : matches.first;
  }

  // 예정 일정을 착장 기록으로 전환 — 같은 문서를 업데이트한다(TPO는 이미
  // 있으니 시트에 미리 채워서 다시 고르지 않아도 되게 한다).
  Future<void> _recordForPlannedEntry(OutfitCalendarEntry planned) async {
    await showCalendarRecordSheet(
      context,
      date: planned.date,
      existingEntryId: planned.id,
      initialTpoTag: planned.tpoTag,
    );
  }

  // "이 코디로 확정" — 에이전트가 준비한 추천 그대로 같은 문서를 기록으로
  // 전환한다. itemIds가 추천과 100% 동일하므로 detectFeedbackForCalendarEntry가
  // 자동으로 accepted 처리한다(별도 로직 불필요, 기존 학습 파이프라인 재사용).
  Future<void> _confirmAgentRecommendation(
    OutfitCalendarEntry planned,
    RecommendationEntry rec,
  ) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await FirestoreService.updateCalendarEntry(
        uid,
        planned.id,
        status: OutfitCalendarEntry.statusRecorded,
        itemIds: rec.itemIds,
        itemSummaries: rec.itemSummaries,
        source: OutfitCalendarEntry.sourceAgent,
        recommendationId: rec.id,
      );
      final updated = OutfitCalendarEntry(
        id: planned.id,
        date: planned.date,
        tpoTag: planned.tpoTag,
        itemIds: rec.itemIds,
        itemSummaries: rec.itemSummaries,
        source: OutfitCalendarEntry.sourceAgent,
        recommendationId: rec.id,
        status: OutfitCalendarEntry.statusRecorded,
        createdAt: planned.createdAt,
      );
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCalendarLogged,
          message:
              '${planned.date.month}/${planned.date.day} [${planned.tpoTag}] 에이전트가 준비한 코디를 그대로 기록했습니다',
          relatedDocId: rec.id,
        ),
      ));
      unawaited(AgentPlanner.detectFeedbackForCalendarEntry(uid, updated));
      unawaited(FirestoreService.dismissRecommendation(uid, rec.id));
      _showSnack('${planned.date.month}/${planned.date.day} 코디를 확정했어요');
    } catch (e) {
      _showSnack('확정 실패: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return const Center(
          child: Text('로그인이 필요합니다', style: TextStyle(color: AppColors.textMuted)));
    }
    return StreamBuilder<List<OutfitCalendarEntry>>(
      stream: FirestoreService.calendarEntriesForMonth(
          uid, _focusedDay.year, _focusedDay.month),
      builder: (context, snapshot) {
        final monthEntries = snapshot.data ?? const <OutfitCalendarEntry>[];
        final dayEntries = _entriesForDay(monthEntries, _selectedDay);
        // 캘린더/버튼까지 한 화면(단일 스크롤)으로 묶어, 기록 목록을 내려도
        // 위쪽 버튼에 가려지지 않고 화면 전체가 함께 스크롤되게 한다.
        // 화면 배경은 흰색으로 통일하고, 그레이 톤은 달력 영역에만 남긴다
        // (_buildCalendar 참고).
        return Container(
          color: Colors.white,
          child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('착장 캘린더',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
              ),
            ),
            _buildCalendar(monthEntries),
            _buildWeeklyPlanButton(),
            const Divider(height: 1, color: AppColors.divider),
            dayEntries.isEmpty
                ? _buildEmptyDay()
                // 옷장에서 옷을 개별 선택해 기록한 착장은 fittingImageUrl이 없어
                // 대표 아이템 썸네일을 만들려면 itemIds → WardrobeItem 매칭이
                // 필요하다(_recordedEntryCard 참고).
                : StreamBuilder<List<WardrobeItem>>(
                    // uid를 못 구하면 스트림을 만들지 않는다(빈 문자열/임의
                    // 값 조회로 "옷장이 비었다"는 잘못된 화면을 막기 위함).
                    stream: _uid != null
                        ? FirestoreService.wardrobeStream(_uid!)
                        : const Stream<List<WardrobeItem>>.empty(),
                    builder: (context, wardrobeSnapshot) {
                      final wardrobeById = {
                        for (final w in wardrobeSnapshot.data ?? const <WardrobeItem>[]) w.id: w,
                      };
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _dayHeader(),
                            const SizedBox(height: 12),
                            ...dayEntries.map((e) => _buildEntryCard(e, wardrobeById)),
                            const SizedBox(height: 12),
                            // 미래 날짜엔 일정 태그를 더 등록, 오늘/과거엔 착장 기록.
                            _isFuture(_selectedDay)
                                ? _scheduleButton(compact: true)
                                : _addButton(compact: true),
                          ],
                        ),
                      );
                    },
                  ),
          ],
          ),
        );
      },
    );
  }

  Widget _buildWeeklyPlanButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: ElevatedButton(
          onPressed: _planning ? null : _runWeeklyPlan,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.navy,
            disabledBackgroundColor: AppColors.navy.withValues(alpha: 0.6),
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(_planning ? '플랜 짜는 중...' : '이번 주 코디 플랜 받기',
              style: const TextStyle(
                  color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _buildCalendar(List<OutfitCalendarEntry> monthEntries) {
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.only(bottom: 8),
      child: TableCalendar<OutfitCalendarEntry>(
      firstDay: DateTime.utc(2020, 1, 1),
      lastDay: DateTime.utc(2035, 12, 31),
      focusedDay: _focusedDay,
      currentDay: DateTime.now(),
      locale: 'ko_KR',
      startingDayOfWeek: StartingDayOfWeek.monday,
      availableGestures: AvailableGestures.horizontalSwipe,
      headerStyle: const HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        titleTextStyle: TextStyle(
            color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
      ),
      calendarStyle: CalendarStyle(
        todayDecoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        todayTextStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
        selectedDecoration: const BoxDecoration(
          color: Colors.black,
          shape: BoxShape.circle,
        ),
        markersMaxCount: 0,
        outsideDaysVisible: false,
      ),
      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
      onDaySelected: (selectedDay, focusedDay) {
        setState(() {
          _selectedDay = OutfitCalendarEntry.normalizeDate(selectedDay);
          _focusedDay = focusedDay;
        });
      },
      onPageChanged: (focusedDay) {
        // 월 이동 → 해당 월 스트림으로 재구독.
        setState(() => _focusedDay = focusedDay);
      },
      ),
    );
  }

  Widget _dayHeader() {
    return Text(
      '${_selectedDay.month}월 ${_selectedDay.day}일 기록',
      style: const TextStyle(
          color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
    );
  }

  Widget _buildEmptyDay() {
    final future = _isFuture(_selectedDay);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(future ? Icons.event_outlined : Icons.checkroom_outlined,
                color: AppColors.textDisabled, size: 40),
            const SizedBox(height: 12),
            Text(
                future
                    ? '${_selectedDay.month}월 ${_selectedDay.day}일 일정을 등록해보세요'
                    : '${_selectedDay.month}월 ${_selectedDay.day}일 기록이 없어요',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
                future
                    ? 'TPO 태그를 남기면 에이전트가 코디를 미리 준비해요'
                    : '오늘 입은 착장을 기록해보세요',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
            const SizedBox(height: 16),
            // 미래 날짜엔 "일정 태그 등록"을, 오늘/과거엔 "착장 기록하기"를 제공.
            future ? _scheduleButton(compact: false) : _addButton(compact: false),
          ],
        ),
      ),
    );
  }

  Widget _addButton({required bool compact}) {
    return SizedBox(
      width: compact ? double.infinity : 220,
      height: 46,
      child: OutlinedButton.icon(
        onPressed: _openRecordSheet,
        icon: const Icon(Icons.add, size: 18, color: Colors.black),
        label: const Text('착장 기록하기',
            style: TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w700)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.black),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  Widget _scheduleButton({required bool compact}) {
    return SizedBox(
      width: compact ? double.infinity : 220,
      height: 46,
      child: OutlinedButton.icon(
        onPressed: _registerScheduleTag,
        icon: const Icon(Icons.event_available, size: 18, color: AppColors.navy),
        label: const Text('일정 태그 등록',
            style: TextStyle(color: AppColors.navy, fontSize: 14, fontWeight: FontWeight.w700)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: AppColors.navy),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  // 예정 일정은 별도 위젯(_PlannedEntryCard)이 에이전트 추천 여부를 비동기로
  // 확인해서 보여주므로 여기서는 분기만 한다.
  Widget _buildEntryCard(OutfitCalendarEntry entry, Map<String, WardrobeItem> wardrobeById) {
    if (entry.isPlanned) {
      return _PlannedEntryCard(
        entry: entry,
        fetchRecommendation: () => _matchingRecommendationFor(entry),
        onConfirmRecommendation: (rec) => _confirmAgentRecommendation(entry, rec),
        onRecordManually: () => _recordForPlannedEntry(entry),
        onDelete: () => _confirmDelete(entry),
      );
    }
    return _recordedEntryCard(entry, wardrobeById);
  }

  // 착장 썸네일 우선순위: (1) 전신 가상 피팅 사진 (2) 옷장에서 개별 선택한
  // 아이템 중 대표 1벌(상의 우선, 없으면 첫 아이템)의 컷아웃/원본 이미지
  // (3) 아무것도 못 찾으면 옷걸이 아이콘.
  WardrobeItem? _representativeItem(
      OutfitCalendarEntry entry, Map<String, WardrobeItem> wardrobeById) {
    final items = entry.itemIds.map((id) => wardrobeById[id]).whereType<WardrobeItem>().toList();
    if (items.isEmpty) return null;
    return items.firstWhere((i) => i.category == '상의', orElse: () => items.first);
  }

  Widget _recordedEntryCard(OutfitCalendarEntry entry, Map<String, WardrobeItem> wardrobeById) {
    final tag = TpoTags.byLabel(entry.tpoTag);
    final summary = entry.itemSummaries.isEmpty
        ? '코디 조합'
        : entry.itemSummaries.map((s) => s.split(':').first.trim()).join(', ');
    final representativeItem =
        entry.fittingImageUrl == null ? _representativeItem(entry, wardrobeById) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 60,
              height: 76,
              child: entry.fittingImageUrl != null
                  ? CachedNetworkImage(
                      imageUrl: entry.fittingImageUrl!,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.background),
                      errorWidget: (_, __, ___) => Container(
                        color: AppColors.background,
                        child: const Icon(Icons.image_outlined, color: AppColors.textDisabled),
                      ),
                    )
                  : representativeItem != null
                      ? Container(
                          color: AppColors.background,
                          padding: const EdgeInsets.all(4),
                          child: CachedNetworkImage(
                            imageUrl:
                                representativeItem.cutoutImageUrl ?? representativeItem.imageUrl,
                            fit: BoxFit.contain,
                            placeholder: (_, __) => Container(color: AppColors.background),
                            errorWidget: (_, __, ___) => Container(
                              color: AppColors.background,
                              child:
                                  const Icon(Icons.checkroom, color: AppColors.textDisabled),
                            ),
                          ),
                        )
                      : Container(
                          color: AppColors.background,
                          child: const Icon(Icons.checkroom, color: AppColors.textDisabled),
                        ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: tag.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tag.icon, size: 13, color: tag.color),
                      const SizedBox(width: 4),
                      Text(tag.label,
                          style: TextStyle(
                              color: tag.color, fontSize: 12, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                if (entry.source == OutfitCalendarEntry.sourceAgent) ...[
                  const SizedBox(height: 4),
                  const Text('에이전트 추천에서 기록',
                      style: TextStyle(color: AppColors.blue, fontSize: 11)),
                ],
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _confirmDelete(entry),
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.delete_outline, color: AppColors.textDisabled, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// 예정(planned) 일정 카드 — 에이전트가 그 날짜/TPO를 위해 이미 준비해둔
// 선제 추천이 있는지 비동기로 확인해서, 있으면 미리보기+확정 버튼을,
// 없으면 기존처럼 착장 기록하기 버튼만 보여준다.
class _PlannedEntryCard extends StatefulWidget {
  final OutfitCalendarEntry entry;
  final Future<RecommendationEntry?> Function() fetchRecommendation;
  final ValueChanged<RecommendationEntry> onConfirmRecommendation;
  final VoidCallback onRecordManually;
  final VoidCallback onDelete;

  const _PlannedEntryCard({
    required this.entry,
    required this.fetchRecommendation,
    required this.onConfirmRecommendation,
    required this.onRecordManually,
    required this.onDelete,
  });

  @override
  State<_PlannedEntryCard> createState() => _PlannedEntryCardState();
}

class _PlannedEntryCardState extends State<_PlannedEntryCard> {
  late final Future<RecommendationEntry?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.fetchRecommendation();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final tag = TpoTags.byLabel(entry.tpoTag);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: tag.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(tag.icon, size: 13, color: tag.color),
                    const SizedBox(width: 4),
                    Text(tag.label,
                        style: TextStyle(
                            color: tag.color, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: widget.onDelete,
                child: const Icon(Icons.delete_outline, color: AppColors.textDisabled, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FutureBuilder<RecommendationEntry?>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Text('예정 일정 확인 중...',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12));
              }
              final rec = snapshot.data;
              if (rec == null) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('에이전트가 코디를 준비할 예정이에요',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 40,
                      child: OutlinedButton.icon(
                        onPressed: widget.onRecordManually,
                        icon: const Icon(Icons.add, size: 16, color: Colors.black),
                        label: const Text('이 날 착장 기록하기',
                            style: TextStyle(
                                color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.black),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                );
              }

              // 에이전트가 이미 준비해둔 추천이 있음 — 미리보기 + 확정 버튼.
              final preview = rec.summaryText.isNotEmpty
                  ? rec.summaryText
                  : rec.itemSummaries.map((s) => s.split(':').first.trim()).join(', ');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 14, color: AppColors.navy),
                      SizedBox(width: 6),
                      Text('에이전트가 준비한 코디',
                          style: TextStyle(
                              color: AppColors.navy, fontSize: 12, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: ElevatedButton(
                            onPressed: () => widget.onConfirmRecommendation(rec),
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
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: OutlinedButton(
                            onPressed: widget.onRecordManually,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: AppColors.border),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: const Text('직접 기록',
                                style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// 미래 날짜에 TPO 태그만 먼저 등록할 때 뜨는 태그 선택 시트.
// 선택된 태그 라벨을 pop으로 반환한다(취소 시 null).
class _TpoPickerSheet extends StatelessWidget {
  final DateTime date;

  const _TpoPickerSheet({required this.date});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${date.month}월 ${date.day}일 일정 태그',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('이 날의 상황(TPO)을 골라주세요',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: TpoTags.all.map((tag) {
                return GestureDetector(
                  onTap: () => Navigator.pop(context, tag.label),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: tag.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: tag.color.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tag.icon, size: 16, color: tag.color),
                        const SizedBox(width: 6),
                        Text(tag.label,
                            style: TextStyle(
                                color: tag.color, fontSize: 13, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
