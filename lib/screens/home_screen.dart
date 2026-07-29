import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_colors.dart';
import '../constants/tpo_tags.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/wardrobe_item.dart';
import '../services/agent_activity.dart';
import '../services/firestore_service.dart';
import '../services/weather_service.dart';
import '../widgets/calendar_record_sheet.dart';

// ── 홈 화면: "DOT." 레퍼런스 디자인에 맞춰 단순화한 버전.
// 인사/날씨 히어로, 액션 그리드, 최근 착장 레일, AI 팁 배너를 하나의
// 미니멀한 세로 흐름(로고 → 오늘의 인사 → 날씨 → 추천 코디 카드)으로 정리했다.
class HomeScreen extends StatelessWidget {
  final ValueChanged<int> onNavigate;
  final ValueChanged<List<WardrobeItem>> onOpenFittingRoom;

  const HomeScreen({super.key, required this.onNavigate, required this.onOpenFittingRoom});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: SingleChildScrollView(
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '오늘 뭐 입지?',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'AI가 옷장 속 아이템을 분석해 오늘의 코디를 추천해요',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                const _WeatherRow(),
                const SizedBox(height: 30),
                const Text(
                  '오늘의 추천 코디',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                _RecommendationCard(onOpenFittingRoom: onOpenFittingRoom, onNavigate: onNavigate),
                const SizedBox(height: 32),
                _WeeklyCalendarSection(onNavigate: onNavigate),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 날씨 한 줄 ────────────────────────────────────────────
// WeatherService(Open-Meteo, 서울 좌표 고정)에서 가져온다. 실패하면 하드코딩된
// 값으로 폴백하지 않고 "불러오지 못했다"고 정직하게 표시한다.
class _WeatherRow extends StatefulWidget {
  const _WeatherRow();

  @override
  State<_WeatherRow> createState() => _WeatherRowState();
}

class _WeatherRowState extends State<_WeatherRow> {
  WeatherSnapshot? _weather;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snapshot = await WeatherService.fetch();
    if (!mounted) return;
    setState(() {
      _weather = snapshot;
      _loading = false;
    });
  }

  // 로컬 규칙 기반 한 줄 조언(Gemini 호출 없음) — 오늘 강수확률이 높으면
  // 비 관련 조언을 우선하고, 아니면 현재 기온대에 맞는 옷차림을 안내한다.
  String _adviceFor(WeatherSnapshot w) {
    final today = w.forDate(DateTime.now());
    if (today != null && today.precipitationProbability >= WeatherService.rainProbabilityThreshold) {
      return '비 예보가 있어요, 우산을 챙기세요';
    }
    final tempC = w.current.tempC;
    if (tempC >= 28) return '가볍고 통풍 잘 되는 소재가 좋아요';
    if (tempC >= 23) return '반팔이나 얇은 셔츠면 충분해요';
    if (tempC >= 17) return '가벼운 아우터 한 장이면 충분해요';
    if (tempC >= 9) return '니트나 가디건 등 보온에 신경 써주세요';
    return '두꺼운 아우터가 필요한 쌀쌀한 날씨예요';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textMuted),
      );
    }
    final weather = _weather;
    if (weather == null) {
      return const Text(
        '날씨 정보를 불러오지 못했어요',
        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
      );
    }
    final condition = weather.current.condition;
    return Row(
      children: [
        Icon(condition.icon, color: const Color(0xFFF59E0B), size: 18),
        const SizedBox(width: 8),
        Text(
          '서울 · ${condition.label} ${weather.current.tempC.round()}°',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _adviceFor(weather),
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ── 추천 코디 카드: 새 옷 등록을 계기로 백그라운드에서 자동 생성된
// 코디 1건을 큰 사진 카드로 보여준다. 없으면 AI 피팅을 유도하는 빈 상태를
// 보여준다.
class _RecommendationCard extends StatelessWidget {
  final ValueChanged<List<WardrobeItem>> onOpenFittingRoom;
  final ValueChanged<int> onNavigate;

  const _RecommendationCard({required this.onOpenFittingRoom, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return _EmptyCard(onNavigate: onNavigate);

    return StreamBuilder<RecommendationEntry?>(
      stream: FirestoreService.recommendationStream(uid),
      builder: (context, snapshot) {
        final entry = snapshot.data;
        if (entry != null) {
          return StreamBuilder<List<WardrobeItem>>(
            stream: FirestoreService.wardrobeStream(uid),
            builder: (context, wardrobeSnapshot) {
              final byId = {
                for (final i in wardrobeSnapshot.data ?? const <WardrobeItem>[]) i.id: i,
              };
              final matchedItems =
                  entry.itemIds.map((id) => byId[id]).whereType<WardrobeItem>().toList();
              if (matchedItems.isEmpty) return _EmptyCard(onNavigate: onNavigate);
              return _RecommendationCardBody(
                key: ValueKey(entry.id),
                entry: entry,
                matchedItems: matchedItems,
                onTap: () => onOpenFittingRoom(matchedItems),
              );
            },
          );
        }
        return ValueListenableBuilder<String?>(
          valueListenable: AgentActivity.current,
          builder: (context, activity, _) {
            if (activity == null) return _EmptyCard(onNavigate: onNavigate);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Column(
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      activity,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _RecommendationCardBody extends StatefulWidget {
  final RecommendationEntry entry;
  final List<WardrobeItem> matchedItems;
  final VoidCallback onTap;

  const _RecommendationCardBody({
    super.key,
    required this.entry,
    required this.matchedItems,
    required this.onTap,
  });

  @override
  State<_RecommendationCardBody> createState() => _RecommendationCardBodyState();
}

class _RecommendationCardBodyState extends State<_RecommendationCardBody> {
  final _pageController = PageController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.matchedItems.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!_pageController.hasClients) return;
        final next = ((_pageController.page ?? 0).round() + 1) % widget.matchedItems.length;
        _pageController.animateToPage(next,
            duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // 추천 조합을 그대로 캘린더 착장 기록 시트에 프리필해서 연다 — 사용자가
  // 조합을 외워서 옷장에서 하나씩 다시 고르지 않아도 되게 한다(scrap_screen의
  // "캘린더에 기록"과 동일한 패턴).
  Future<void> _recordToCalendar(BuildContext context) async {
    final first = widget.matchedItems.first;
    final saved = await showCalendarRecordSheet(
      context,
      date: widget.entry.targetDate ?? DateTime.now(),
      prefillImageUrl: first.cutoutImageUrl ?? first.imageUrl,
      prefillItemIds: widget.entry.itemIds,
      prefillItemSummaries: widget.entry.itemSummaries,
      recommendationId: widget.entry.id,
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('캘린더에 착장을 기록했어요'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.blue,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final items = widget.matchedItems;
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 4 / 5,
              child: Container(
                color: AppColors.background,
                child: items.length <= 1
                    ? _RecommendationItemImage(item: items.first)
                    : Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          PageView.builder(
                            controller: _pageController,
                            itemCount: items.length,
                            itemBuilder: (context, i) =>
                                _RecommendationItemImage(item: items[i]),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var i = 0; i < items.length; i++)
                                  AnimatedBuilder(
                                    animation: _pageController,
                                    builder: (context, _) {
                                      final page = _pageController.hasClients
                                          ? (_pageController.page ?? 0).round()
                                          : 0;
                                      return Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 3),
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: page == i
                                              ? Colors.white
                                              : Colors.white.withValues(alpha: 0.4),
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            if (entry.fallbackNote != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: AppColors.amberPale,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: AppColors.amber, size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        entry.fallbackNote!,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // 선택 카테고리 미달(optionalNote)/자기 성능 인지(confidenceNote)/
            // 날씨 근거(weatherNote)/진단-수리 표시(repairNote) — 전엔 모델에만
            // 있고 어디서도 렌더링하지 않던 죽은 출력. fallbackNote(경고, amber
            // 풀폭 배너)와 겹치지 않도록 배너를 새로 쌓지 않고, 회색 배경 한
            // 칸에 아이콘+텍스트 색상만 다르게 줄줄이 묶어 카드가 과하게
            // 길어지지 않게 한다.
            if (entry.optionalNote != null ||
                entry.weatherNote != null ||
                entry.confidenceNote != null ||
                entry.repairNote != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppColors.background,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (entry.optionalNote != null)
                      _AgentNoteLine(
                        icon: Icons.info_outline,
                        color: AppColors.amber,
                        text: entry.optionalNote!,
                      ),
                    if (entry.weatherNote != null)
                      Padding(
                        padding: EdgeInsets.only(top: entry.optionalNote != null ? 6 : 0),
                        child: _AgentNoteLine(
                          icon: Icons.cloud_outlined,
                          color: AppColors.teal,
                          text: entry.weatherNote!,
                        ),
                      ),
                    if (entry.confidenceNote != null)
                      Padding(
                        padding: EdgeInsets.only(
                            top: (entry.optionalNote != null || entry.weatherNote != null)
                                ? 6
                                : 0),
                        child: _AgentNoteLine(
                          icon: Icons.psychology_outlined,
                          color: AppColors.blue,
                          text: entry.confidenceNote!,
                        ),
                      ),
                    if (entry.repairNote != null)
                      Padding(
                        padding: EdgeInsets.only(
                            top: (entry.optionalNote != null ||
                                    entry.weatherNote != null ||
                                    entry.confidenceNote != null)
                                ? 6
                                : 0),
                        child: _AgentNoteLine(
                          icon: Icons.auto_fix_high,
                          color: AppColors.purple,
                          text: '한 번 다듬었어요 · ${entry.repairNote!}',
                        ),
                      ),
                  ],
                ),
              ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '오늘의 추천 셋업',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${entry.itemIds.length} items',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                  if (entry.summaryText.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      entry.summaryText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ],
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () => _recordToCalendar(context),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.event_available_outlined,
                            color: AppColors.blue, size: 15),
                        const SizedBox(width: 6),
                        const Text('캘린더에 기록',
                            style: TextStyle(
                                color: AppColors.blue,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 추천 조합 슬라이드 한 장 — 배경 제거본이 있으면 우선 사용.
// confidenceNote/weatherNote/repairNote 공용 한 줄 — 아이콘/텍스트를 같은
// 색으로 칠해 종류를 구분하되, fallbackNote처럼 풀폭 배경은 따로 두지
// 않아(공유 컨테이너의 회색 배경 안에 묶여) 여러 개가 겹쳐도 배너가
// 쌓이는 느낌 없이 카드 세로 길이가 완만하게 늘어난다.
class _AgentNoteLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _AgentNoteLine({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _RecommendationItemImage extends StatelessWidget {
  final WardrobeItem item;

  const _RecommendationItemImage({required this.item});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: CachedNetworkImage(
        imageUrl: item.cutoutImageUrl ?? item.imageUrl,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) =>
            const Icon(Icons.image_not_supported_outlined, color: AppColors.textDisabled),
      ),
    );
  }
}

// ── 추천 코디가 아직 없을 때의 빈 상태 ────────────────────
class _EmptyCard extends StatelessWidget {
  final ValueChanged<int> onNavigate;

  const _EmptyCard({required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Icon(Icons.checkroom_outlined, color: AppColors.textDisabled, size: 30),
          const SizedBox(height: 12),
          const Text(
            '아직 추천 코디가 없어요',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'AI 피팅을 먼저 사용해 보세요',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => onNavigate(2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'AI 피팅 하러 가기',
                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 착장 캘린더(주간) 임베드: 캘린더 탭의 핵심 기능(기록 추가·수정·삭제)을
// 홈 화면에서 한 주 단위로 바로 쓸 수 있게 옮겨왔다. 월간 전체 보기는
// "월별 보기"를 눌러 기존 캘린더 탭(index 3)에서 그대로 이용한다.
class _WeeklyCalendarSection extends StatefulWidget {
  final ValueChanged<int> onNavigate;

  const _WeeklyCalendarSection({required this.onNavigate});

  @override
  State<_WeeklyCalendarSection> createState() => _WeeklyCalendarSectionState();
}

class _WeeklyCalendarSectionState extends State<_WeeklyCalendarSection> {
  static const _weekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];

  DateTime _selectedDay = OutfitCalendarEntry.normalizeDate(DateTime.now());
  List<OutfitCalendarEntry> _weekEntries = const [];
  bool _loading = true;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // 일요일 시작 기준 이번 주 첫날.
  DateTime get _weekStart {
    final offset = _selectedDay.weekday % 7; // 월=1..토=6, 일=7→0
    return _selectedDay.subtract(Duration(days: offset));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final weekStart = _weekStart;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final entries = await FirestoreService.calendarEntriesForRange(uid, weekStart, weekEnd);
    if (!mounted) return;
    setState(() {
      _weekEntries = entries;
      _loading = false;
    });
  }

  List<OutfitCalendarEntry> _entriesForDay(DateTime day) =>
      _weekEntries.where((e) => _isSameDay(e.date, day)).toList();

  Future<void> _openRecordSheet(DateTime date, {OutfitCalendarEntry? existing}) async {
    final saved = await showCalendarRecordSheet(
      context,
      date: date,
      existingEntryId: existing?.id,
      initialTpoTag: existing?.tpoTag,
    );
    if (saved == true) _load();
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
            style:
                TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
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
      final uidNow = _uid;
      if (uidNow == null) return;
      await FirestoreService.deleteCalendarEntry(uidNow, entry.id);
      _load();
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

  @override
  Widget build(BuildContext context) {
    if (_uid == null) return const SizedBox.shrink();
    final weekStart = _weekStart;
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));
    final selectedEntries = _entriesForDay(_selectedDay);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('착장 캘린더',
                style: TextStyle(
                    color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w800)),
            GestureDetector(
              onTap: () => widget.onNavigate(3),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('월별 보기',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
                  SizedBox(width: 2),
                  Icon(Icons.chevron_right, color: AppColors.textMuted, size: 16),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child:
                Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textMuted)),
          )
        else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (i) {
              final day = days[i];
              final isSelected = _isSameDay(day, _selectedDay);
              final hasEntry = _entriesForDay(day).isNotEmpty;
              return GestureDetector(
                onTap: () => setState(() => _selectedDay = OutfitCalendarEntry.normalizeDate(day)),
                child: Column(
                  children: [
                    Text(
                      _weekdayLabels[i],
                      style: TextStyle(
                        color: i == 0 ? AppColors.red : AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.black : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          color: isSelected ? Colors.white : AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasEntry ? Colors.black : Colors.transparent,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 18),
          _buildDayCard(selectedEntries),
        ],
      ],
    );
  }

  Widget _buildDayCard(List<OutfitCalendarEntry> entries) {
    if (entries.isEmpty) {
      return GestureDetector(
        onTap: () => _openRecordSheet(_selectedDay),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 32),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              const Icon(Icons.checkroom_outlined, color: AppColors.textDisabled, size: 26),
              const SizedBox(height: 10),
              Text(
                '${_selectedDay.month}월 ${_selectedDay.day}일 착장 기록하기',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                '상황 태그를 고르면 AI가 코디를 추천해요',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    // 그날 기록이 여러 건이어도(예: 나중에 다시 기록) 모두 한눈에 보이도록
    // 옷장 스트림을 구독해 대표 이미지까지 갖춘 카드로 전부 나열한다.
    return StreamBuilder<List<WardrobeItem>>(
      // build() 맨 앞에서 _uid == null이면 이미 return된 뒤라 여기선 non-null.
      stream: FirestoreService.wardrobeStream(_uid!),
      builder: (context, snapshot) {
        final wardrobeById = {
          for (final w in snapshot.data ?? const <WardrobeItem>[]) w.id: w,
        };
        return Column(
          children: entries.map((entry) => _entryCard(entry, wardrobeById)).toList(),
        );
      },
    );
  }

  WardrobeItem? _representativeItem(
      OutfitCalendarEntry entry, Map<String, WardrobeItem> wardrobeById) {
    final items = entry.itemIds.map((id) => wardrobeById[id]).whereType<WardrobeItem>().toList();
    if (items.isEmpty) return null;
    return items.firstWhere((i) => i.category == '상의', orElse: () => items.first);
  }

  Widget _entryCard(OutfitCalendarEntry entry, Map<String, WardrobeItem> wardrobeById) {
    final tag = TpoTags.byLabel(entry.tpoTag);
    final summary = entry.itemSummaries.isEmpty
        ? '코디 조합'
        : entry.itemSummaries.map((s) => s.split(':').first.trim()).join(', ');
    final representativeItem =
        entry.fittingImageUrl == null ? _representativeItem(entry, wardrobeById) : null;
    return GestureDetector(
      onTap: () => _openRecordSheet(entry.date, existing: entry),
      child: Container(
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
      ),
    );
  }
}
