import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'constants/app_colors.dart';
import 'models/wardrobe_item.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/wardrobe_screen.dart';
import 'screens/fitting_room_screen.dart';
import 'screens/calendar_screen.dart';
import 'screens/settings_screen.dart';
import 'package:workmanager/workmanager.dart';
import 'services/agent_planner.dart';
import 'services/agent_sweeper.dart';
import 'services/background_agent.dart';
import 'services/fitting_job_controller.dart';
import 'services/fitting_progress.dart';
import 'services/notification_service.dart';
import 'services/fcm_service.dart';
import 'debug/similarity_check.dart';
import 'firebase_options.dart';

// 킬 스위치 — B단계에서 도입한 백그라운드 코드를 컴파일 타임에 통째로 끈다.
// `--dart-define=BG_AGENT=false`로 빌드하면 등록 코드가 건너뛰어져 A단계와
// 완전히 동일하게 동작한다(USE_EMULATOR, RUN_SIMILARITY_CHECK와 동일 패턴).
const kEnableBackgroundAgent =
    bool.fromEnvironment('BG_AGENT', defaultValue: true);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 디버그 전용 로컬 검증 경로 — `--dart-define=USE_EMULATOR=true`로 실행하면
  // 배포된 프로젝트 대신 로컬 Firebase Emulator에 붙어, 로컬 firestore.rules로
  // 저장 기능을 검증한다. 기본값 false라 일반 빌드/배포에는 전혀 영향 없음.
  // 안드로이드 에뮬레이터에서 호스트 PC는 10.0.2.2로 접근한다.
  // App Check, 화면 방향 고정은 모바일(android/ios) 전용 네이티브 구현만 있어서
  // windows 등 데스크톱에서 호출하면 MissingPluginException이 뜬다. UI 확인용
  // 데스크톱 실행을 막지 않도록 모바일 플랫폼에서만 실행한다.
  final isMobile = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  const useEmulator = bool.fromEnvironment('USE_EMULATOR');
  if (useEmulator) {
    FirebaseFirestore.instance.useFirestoreEmulator('10.0.2.2', 8080);
    await FirebaseAuth.instance.useAuthEmulator('10.0.2.2', 9099);
  } else if (isMobile) {
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
    );
  }

  // [검증 전용] --dart-define=RUN_SIMILARITY_CHECK=true 로 빌드했을 때만 실행.
  // 실제 구현은 lib/debug/similarity_check.dart 참고. 기본값 false라 일반
  // 빌드/배포에는 전혀 영향 없음.
  const runSimilarityCheckFlag = bool.fromEnvironment('RUN_SIMILARITY_CHECK');
  if (runSimilarityCheckFlag) {
    await runSimilarityCheck();
    runApp(const SimilarityCheckApp());
    return;
  }

  // 착장 캘린더(table_calendar)의 한국어 월/요일 표기를 위해 로케일 데이터 초기화.
  await initializeDateFormatting('ko_KR', null);

  // 로컬 알림 초기화 + 첫 실행 시 런타임 권한 요청(Android 13+). 신규 네이티브
  // 플러그인 초기화라 실패해도 앱 구동을 막지 않도록 통째로 감싼다.
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await NotificationService.init();
      await NotificationService.requestPermissionIfNeeded();
    } catch (e) {
      debugPrint('[Notification] 초기화 실패(무시하고 앱 계속): $e');
    }
  }

  // 백그라운드 주기 실행 등록(B단계). Android 전용 — iOS의 Background Fetch는
  // OS 재량이라 하루 한 번도 보장되지 않아 이번 범위에서 제외한다. 이 저장소는
  // 릴리스 빌드에서만 터지는 네이티브 결함을 이미 겪었으므로, 등록 실패가
  // 앱 기동 자체를 막지 않도록 통째로 감싼다.
  if (kEnableBackgroundAgent && defaultTargetPlatform == TargetPlatform.android) {
    try {
      // isInDebugMode는 workmanager 0.9.0부터 deprecated·무동작이라 넘기지 않는다.
      await Workmanager().initialize(backgroundCallbackDispatcher);
      await Workmanager().registerPeriodicTask(
        'dot-proactive-check',
        'proactiveCheck',
        frequency: const Duration(hours: 3),
        // keep이 중요하다 — 앱을 열 때마다 replace하면 주기가 계속 리셋되어
        // 영영 실행되지 않는다. (workmanager 0.9.0부터 periodic task는
        // ExistingWorkPolicy가 아니라 ExistingPeriodicWorkPolicy를 쓴다.)
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } catch (e) {
      debugPrint('[BG] 등록 실패(무시하고 앱 계속): $e');
    }
  }

  if (isMobile) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  runApp(const AiFashionAssistantApp());
}

class AiFashionAssistantApp extends StatelessWidget {
  const AiFashionAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DOT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.blue),
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: AppColors.background,
              body: Center(
                child: CircularProgressIndicator(
                    color: AppColors.navy, strokeWidth: 2),
              ),
            );
          }
          if (snapshot.hasData) return const AppShell();
          return const LoginScreen();
        },
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  // ── 피팅룸 아이템 상태(코디보드 슬롯 8개) ─────────────────
  final Map<String, WardrobeItem?> _fittingItems = {
    '아우터': null,
    '상의': null,
    '하의': null,
    '신발': null,
    '모자': null,
    '가방': null,
    '시계': null,
    '팔찌': null,
  };
  WardrobeItem? _fittingUserPhoto; // 전신 사진

  // AppShell(탭 전환에도 살아있는 레벨)에서 보관 → 다른 탭으로 이동해도
  // 진행 중인 AI 분석/가상 피팅 작업과 결과가 유지된다.
  final FittingJobController _fittingJob = FittingJobController();

  @override
  void initState() {
    super.initState();
    // 상태 지속성(복구) → 레벨 1 선제 추천 순으로 앱 진입 시 1회씩 실행한다.
    // 복구가 새 작업보다 우선이고, 둘 다 Gemini를 호출할 수 있어 동시에
    // 겹치지 않도록 순차 실행 + 짧은 간격을 둔다(과부하 시 호출이 한꺼번에
    // 몰리는 것을 완화). 부가 기능이라 실패해도 조용히 무시한다.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      unawaited(() async {
        await AgentSweeper.run(uid);
        await Future.delayed(const Duration(seconds: 2));
        await AgentPlanner.runProactiveCheck(uid);
      }());
    }

    // FCM 토큰 등록(B단계) — StreamBuilder가 LoginScreen에서 AppShell로
    // 전환될 때마다(=인증 상태가 생길 때마다) initState가 다시 돌아, 앱
    // 시작 시 이미 로그인돼 있던 경우와 방금 로그인한 경우를 둘 다 덮는다.
    // 신규 네이티브 플러그인이라 실패해도 앱 구동을 막지 않도록 감싼다.
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(() async {
        try {
          await FcmService.init();
        } catch (e) {
          debugPrint('[FCM] 초기화 실패(무시): $e');
        }
      }());
    }
  }

  @override
  void dispose() {
    _fittingJob.dispose();
    super.dispose();
  }

  // 액세서리는 등록 카테고리가 전부 "액세서리"라 subCategory(모자/가방/시계/팔찌)로
  // 코디보드 슬롯 키를 가려낸다. 그 외 카테고리는 카테고리명이 곧 슬롯 키.
  String? _boardSlotKeyFor(WardrobeItem item) {
    if (item.category == '액세서리') return item.subCategory;
    return item.category;
  }

  // 옷장 탭에서 선택 → 피팅룸 이동
  void _sendToFittingRoom(WardrobeItem item) {
    final slotKey = _boardSlotKeyFor(item);
    if (slotKey == null) return;
    setState(() {
      _fittingItems[slotKey] = item;
      _tabIndex = 2;
    });
  }

  // 홈 화면의 추천 코디 카드 탭 → 조합에 포함된 아이템들을 피팅룸 코디보드
  // 슬롯에 한 번에 채우고 이동. 코디보드 슬롯에 없는 카테고리는 자연스럽게
  // 무시된다.
  void _sendRecommendationToFittingRoom(List<WardrobeItem> items) {
    setState(() {
      for (final item in items) {
        final slotKey = _boardSlotKeyFor(item);
        if (slotKey != null && _fittingItems.containsKey(slotKey)) {
          _fittingItems[slotKey] = item;
        }
      }
      _tabIndex = 2;
    });
  }

  // 피팅룸 인라인: 슬롯에 아이템 설정
  void _setFittingItem(String category, WardrobeItem item) {
    setState(() => _fittingItems[category] = item);
  }

  // 피팅룸 인라인: 슬롯 비우기
  void _clearFittingItem(String category) {
    setState(() => _fittingItems[category] = null);
  }

  // 피팅룸 인라인: 전신 사진 설정
  void _setFittingUserPhoto(WardrobeItem item) {
    setState(() => _fittingUserPhoto = item);
  }

  // 피팅룸 인라인: 전신 사진 초기화
  void _clearFittingUserPhoto() {
    setState(() => _fittingUserPhoto = null);
  }

  // 피팅룸 결과 카드를 접었을 때 나타나는 플로팅 아이콘 탭 — 피팅룸 탭으로
  // 전환하고 카드를 다시 펼친다(완료 상태 아이콘을 탭했을 때도 동일).
  void _openFittingRoomFromFloatingIcon() {
    FittingProgress.collapsed.value = false;
    setState(() {
      _tabIndex = 2;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        // Positioned는 Stack의 직계 RenderObjectWidget 자손이어야 하므로,
        // 제약을 읽기 위한 LayoutBuilder는 Stack 바깥(위)에서 한 번만 감싸고
        // 그 결과값만 _FloatingFittingIcon에 넘긴다. LayoutBuilder를 Stack
        // 안쪽(_FloatingFittingIcon.build() 내부)에 두면 LayoutBuilder 자체가
        // RenderObjectWidget이라 Positioned가 Stack이 아니라 LayoutBuilder의
        // RenderObject에 StackParentData를 적용하려다 실패한다
        // ("Incorrect use of ParentDataWidget" — 매 드래그 프레임마다 예외가
        // 던져지면서 위치 갱신이 반영되지 않아 아이콘이 움직이지 않던 원인).
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                _buildBody(),
                _FloatingFittingIcon(
                  jobController: _fittingJob,
                  onTap: _openFittingRoomFromFloatingIcon,
                  maxWidth: constraints.maxWidth,
                  maxHeight: constraints.maxHeight,
                ),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: _BottomNav(
        activeIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
      ),
    );
  }

  Widget _buildBody() {
    switch (_tabIndex) {
      case 0:
        return HomeScreen(
          onNavigate: (i) => setState(() => _tabIndex = i),
          onOpenFittingRoom: _sendRecommendationToFittingRoom,
        );
      case 1:
        // 옷장: 아이템 선택 콜백 전달
        return WardrobeScreen(onSelectItem: _sendToFittingRoom);
      case 2:
        return FittingRoomScreen(
          jobController: _fittingJob,
          selectedItems: Map.from(_fittingItems),
          userPhoto: _fittingUserPhoto,
          onSetItem: _setFittingItem,
          onClearItem: _clearFittingItem,
          onSetUserPhoto: _setFittingUserPhoto,
          onClearUserPhoto: _clearFittingUserPhoto,
        );
      case 3:
        return const CalendarScreen();
      case 4:
        return const SettingsScreen();
      default:
        return HomeScreen(
          onNavigate: (i) => setState(() => _tabIndex = i),
          onOpenFittingRoom: _sendRecommendationToFittingRoom,
        );
    }
  }
}

// ── 피팅룸 진행 상황 플로팅 아이콘 ────────────────────────
// 결과 카드를 접었을 때(FittingProgress.collapsed) 어느 탭에서든 계속
// 보이는 드래그 가능한 배지. FittingJobController를 구독만 하고 절대
// 상태를 바꾸지 않는다(순수 UI 레이어).
enum _FittingIconPhase { hidden, running, success, error }

class _FloatingFittingIcon extends StatefulWidget {
  final FittingJobController jobController;
  final VoidCallback onTap;
  final double maxWidth;
  final double maxHeight;

  const _FloatingFittingIcon({
    required this.jobController,
    required this.onTap,
    required this.maxWidth,
    required this.maxHeight,
  });

  @override
  State<_FloatingFittingIcon> createState() => _FloatingFittingIconState();
}

class _FloatingFittingIconState extends State<_FloatingFittingIcon>
    with SingleTickerProviderStateMixin {
  static const _size = 56.0;
  static const _margin = 16.0;

  _FittingIconPhase _phase = _FittingIconPhase.hidden;
  bool _wasBusy = false;
  Timer? _autoHideTimer;
  late final AnimationController _bounceController;
  late final Animation<double> _bounceScale;

  double? _left;
  double? _top;

  // onTap과 onPanUpdate를 GestureDetector에 함께 배선하면 제스처 아레나에서
  // 탭 인식기가 이겨버려 드래그가 무시되는 경우가 있다. 그래서 onTap은 아예
  // 쓰지 않고, onPanDown/Update/End로만 직접 탭-드래그를 판별한다: 누른
  // 뒤 뗄 때까지의 누적 이동 거리가 임계값 이하면 탭으로, 넘으면 드래그로
  // 처리한다.
  static const _tapSlop = 8.0;
  double _dragDistance = 0;

  @override
  void initState() {
    super.initState();
    widget.jobController.addListener(_onJobChanged);
    FittingProgress.collapsed.addListener(_onCollapsedChanged);
    _bounceController =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _bounceScale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.3).chain(CurveTween(curve: Curves.easeOut)), weight: 50),
      TweenSequenceItem(
          tween: Tween(begin: 1.3, end: 1.0).chain(CurveTween(curve: Curves.easeIn)), weight: 50),
    ]).animate(_bounceController);
    _refreshPhase();
  }

  @override
  void dispose() {
    widget.jobController.removeListener(_onJobChanged);
    FittingProgress.collapsed.removeListener(_onCollapsedChanged);
    _autoHideTimer?.cancel();
    _bounceController.dispose();
    super.dispose();
  }

  void _onCollapsedChanged() => _refreshPhase();

  void _onJobChanged() {
    final busy = widget.jobController.isBusy;
    final justFinished = _wasBusy && !busy;
    _wasBusy = busy;
    _refreshPhase();
    if (justFinished && _phase == _FittingIconPhase.success) {
      _bounceController.forward(from: 0);
    }
  }

  // 컨트롤러의 현재 상태로부터 아이콘 단계를 다시 계산한다. collapse
  // 시점에 이미 완료/실패 상태였던 경우도 이 재계산 덕에 바로 반영된다.
  void _refreshPhase() {
    final c = widget.jobController;
    final _FittingIconPhase next;
    if (c.isBusy) {
      next = _FittingIconPhase.running;
    } else if (c.analysisError != null || c.fittingError != null) {
      next = _FittingIconPhase.error;
    } else if (c.analysisResult != null || c.fittingImage != null || c.fittingImageUrl != null) {
      next = _FittingIconPhase.success;
    } else {
      next = _FittingIconPhase.hidden;
    }
    if (next == _FittingIconPhase.running) {
      _autoHideTimer?.cancel();
    } else if (next != _phase) {
      _scheduleAutoHide();
    }
    if (mounted) setState(() => _phase = next);
  }

  void _scheduleAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _phase = _FittingIconPhase.hidden);
    });
  }

  void _handleTap() {
    _autoHideTimer?.cancel();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: FittingProgress.collapsed,
      builder: (context, collapsed, _) {
        final maxW = widget.maxWidth;
        final maxH = widget.maxHeight;
        if (!collapsed || _phase == _FittingIconPhase.hidden) return const SizedBox.shrink();
        if (maxW <= _size || maxH <= _size) return const SizedBox.shrink();
        _left ??= maxW - _size - _margin;
        _top ??= maxH - _size - _margin;
        final minLeft = _margin;
        final maxLeft = (maxW - _size - _margin).clamp(minLeft, double.infinity);
        final minTop = _margin;
        final maxTop = (maxH - _size - _margin).clamp(minTop, double.infinity);
        final left = _left!.clamp(minLeft, maxLeft);
        final top = _top!.clamp(minTop, maxTop);

        return Positioned(
          left: left,
          top: top,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (_) {
              _dragDistance = 0;
            },
            onPanUpdate: (details) {
              _dragDistance += details.delta.distance;
              setState(() {
                _left = (_left! + details.delta.dx).clamp(minLeft, maxLeft);
                _top = (_top! + details.delta.dy).clamp(minTop, maxTop);
              });
            },
            onPanEnd: (_) {
              if (_dragDistance < _tapSlop) _handleTap();
            },
            child: AnimatedBuilder(
              animation: _bounceController,
              builder: (context, child) => Transform.scale(
                scale: _phase == _FittingIconPhase.success ? _bounceScale.value : 1.0,
                child: child,
              ),
              child: _buildBadge(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBadge() {
    late final Color bg;
    late final Widget icon;
    switch (_phase) {
      case _FittingIconPhase.running:
        bg = AppColors.navy;
        icon = const Icon(Icons.checkroom, color: Colors.white, size: 24);
        break;
      case _FittingIconPhase.success:
        bg = AppColors.blue;
        icon = const Icon(Icons.check, color: Colors.white, size: 26);
        break;
      case _FittingIconPhase.error:
        bg = AppColors.red;
        icon = const Icon(Icons.priority_high, color: Colors.white, size: 26);
        break;
      case _FittingIconPhase.hidden:
        bg = AppColors.navy;
        icon = const SizedBox.shrink();
    }
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_phase == _FittingIconPhase.running)
            const Padding(
              padding: EdgeInsets.all(4),
              child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white70),
            ),
          icon,
        ],
      ),
    );
  }
}

// ── 하단 네비게이션 바 ─────────────────────────────────────
class _BottomNav extends StatelessWidget {
  final int activeIndex;
  final ValueChanged<int> onTap;

  const _BottomNav({required this.activeIndex, required this.onTap});

  static const _items = [
    _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: ''),
    _NavItem(
        icon: Icons.checkroom_outlined,
        activeIcon: Icons.checkroom,
        label: ''),
    _NavItem(
        icon: Icons.auto_awesome_outlined,
        activeIcon: Icons.auto_awesome,
        label: ''),
    _NavItem(
        icon: Icons.calendar_month_outlined,
        activeIcon: Icons.calendar_month,
        label: ''),
    _NavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: ''),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              final isActive = activeIndex == i;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onTap(i),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 44,
                        height: 30,
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFFEDEDED)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          isActive ? item.activeIcon : item.icon,
                          color: isActive
                              ? Colors.black
                              : AppColors.textPlaceholder,
                          size: 21,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight:
                              isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive
                              ? Colors.black
                              : AppColors.textPlaceholder,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}
