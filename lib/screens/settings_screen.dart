import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';
import '../constants/app_colors.dart';
import '../data/region_presets.dart';
import '../models/user_profile.dart';
import '../services/background_agent.dart';
import '../services/fcm_service.dart';
import '../services/firestore_service.dart';
import '../services/weather_service.dart';
import '../services/google_auth_service.dart';
import '../services/notification_service.dart';
import 'agent_log_screen.dart';
import 'usage_guide_screen.dart';
import 'body_profile_screen.dart';
import 'scrap_screen.dart';
import 'privacy_info_screen.dart';

part 'test_tools_screen.dart';

// 화면 테스트에서 Firebase 없이 그리기 위한 자리 — 앱에서는 이 기본값을 그대로 쓴다.
@visibleForTesting
User? Function() settingsCurrentUser = () => FirebaseAuth.instance.currentUser;
@visibleForTesting
Stream<Map<String, dynamic>?> Function(String uid) settingsBackgroundMetaStream =
    FirestoreService.backgroundAgentMetaStream;

// ── 설정 화면: "DOT." 레퍼런스 디자인(더보기)에 맞춰 단순한 리스트형으로
// 정리했다. 기존 화면의 실제 기능(내 스크랩, AI 비서 활동 내역, 체형 정보)은
// 그대로 유지하고, 나머지 항목(프로필/알림/약관 등)은 새 레이아웃에 맞게
// 재배치했다.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  UserProfile? _profile;
  bool _pushEnabled = true;
  bool _marketingEnabled = false;
  bool _linkingGoogle = false;

  // 예보 가정(테스트용) — 바꾸는 곳은 테스트 도구 화면. 여기서는 "테스트 도구" 줄의 켜짐 표시에만 쓴다.
  ForecastAssumption _forecastAssumption = ForecastAssumption.none;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadForecastAssumption();
  }

  void _loadForecastAssumption() {
    WeatherService.loadAssumption().then((a) {
      if (mounted) setState(() => _forecastAssumption = a);
    });
  }

  // 테스트 도구(개발·시연 확인용) — 돌아오면 예보 가정 표시를 다시 읽는다.
  Future<void> _openTestTools() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TestToolsScreen()));
    _loadForecastAssumption();
  }

  String get _testToolsSub => _forecastAssumption == ForecastAssumption.none
      ? '알림 테스트, 백그라운드 실행, 예보 가정'
      : '예보 가정 켜짐: ${_assumptionLabels[_forecastAssumption]}';

  Future<void> _loadProfile() async {
    final uid = settingsCurrentUser()?.uid;
    if (uid == null) return;
    final profile = await FirestoreService.getUserProfileSilently(uid);
    if (mounted) setState(() => _profile = profile);
  }

  String _bodyInfoSummary() {
    final profile = _profile;
    if (profile == null || !profile.hasAnyData) return '체형 정보 입력하기';
    final parts = <String>[];
    if (profile.heightCm != null) parts.add('${profile.heightCm}cm');
    if (profile.weightKg != null) parts.add('${profile.weightKg}kg');
    if (profile.personalColor != null) parts.add(profile.personalColor!);
    return parts.isEmpty ? '체형 정보 보기' : parts.join(' · ');
  }

  void _openBodyProfile() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BodyProfileScreen()),
    );
    _loadProfile();
  }

  // 지역 선택 — 지오코딩 없이 광역시도 17개 프리셋 중 고른다(날씨
  // 조회 좌표용, 옷차림 판단엔 시도 단위 해상도면 충분하다는 판단).
  // saveUserProfile은 문서 전체를 덮어쓰므로(merge 아님) 반드시
  // copyWith로 기존 체형/취향 필드를 보존한 채 지역만 바꿔서 저장한다
  // — 안 그러면 지역 하나 바꿨다고 체형 정보가 날아간다.
  Future<void> _openRegionPicker() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final selected = await showModalBottomSheet<RegionPreset>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RegionPickerSheet(current: _profile?.regionName),
    );
    if (selected == null || !mounted) return;

    final updated = (_profile ?? const UserProfile()).copyWith(
      regionName: selected.name,
      regionLatitude: selected.latitude,
      regionLongitude: selected.longitude,
    );
    try {
      await FirestoreService.saveUserProfile(uid, updated);
      if (mounted) setState(() => _profile = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('지역 저장 실패: $e'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.red,
      ));
    }
  }

  void _openScraps() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ScrapScreen()),
    );
  }

  void _openAgentLog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AgentLogScreen()),
    );
  }

  void _comingSoon(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label은(는) 준비 중입니다'), behavior: SnackBarBehavior.floating),
    );
  }

  // 데모 진입점 상시 노출 — 기존엔 wardrobe_screen.dart의 빈 상태
  // 화면(items.isEmpty)에만 있어 옷을 한 벌이라도 등록하면 사라졌다
  // (handoff_2026-08-07.md §6 "(A) 온보딩" 참고). 여기 "데모 옷장
  // 비우기"와 대칭으로 추가 — 노출 조건(uid != null)도 대칭이다.
  // 빈 상태 버튼은 그대로 둔다(제거하면 첫 실행 경험이 오히려 나빠짐).
  // wardrobe_screen.dart의 _seedDemoWardrobe와 동일하게 확인 다이얼로그
  // 없음(추가만 하는 작업이라 삭제와 달리 되돌리기 위험이 없음 —
  // 데모 아이템은 "데모 옷장 비우기"로 언제든 도로 지울 수 있다).
  bool _seedingDemo = false;

  Future<void> _seedDemoWardrobe() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _seedingDemo) return;
    setState(() => _seedingDemo = true);
    try {
      final count = await FirestoreService.seedDemoWardrobe(uid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데모 옷장 $count벌을 불러왔습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데모 옷장을 불러오지 못했습니다: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _seedingDemo = false);
    }
  }

  // F'.1.5 — isDemo:true인 문서만 골라 지운다(FirestoreService.clearDemoWardrobe
  // 가 그 조건으로 쿼리). 직접 등록한 옷까지 날아가는 사고를 막기 위해
  // 확인 다이얼로그 없이는 삭제하지 않는다.
  Future<void> _clearDemoWardrobe() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('데모 옷장 비우기'),
        content: const Text(
          '데모로 불러온 옷과 예시 일정, 그 일정용 추천만 삭제됩니다.\n직접 등록한 옷과 일정은 그대로 남습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final count = await FirestoreService.clearDemoWardrobe(uid);
      // 예시 일정(docs/task_demo_flow_v1.md 부분 B-2)과 그 추천도 함께 — 옷만 지우면
      // 홈에 빈 조합 카드와 일정이 남는다.
      final plans = await FirestoreService.clearDemoPlans(uid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데모 옷장 $count벌${plans > 0 ? '과 예시 일정 $plans건' : ''}을 삭제했습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('삭제 실패: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }

  void _openLicensePage() {
    showLicensePage(
      context: context,
      applicationName: 'DOT',
      applicationVersion: '1.0.0',
    );
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('로그아웃 하시겠어요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('로그아웃', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // 사용 가이드의 "이번 실행에서 띄웠음"은 계정 단위 — 로그아웃하면 지운다(§4-1).
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) UsageGuide.forgetLaunch(uid);
      await FirebaseAuth.instance.signOut();
      try {
        await GoogleAuthService.signOut();
      } catch (e) {
        debugPrint('[Auth] 구글 세션 로그아웃 실패(무시): $e');
      }
    }
  }

  // 이미 연동된 구글 계정 이메일. 없으면 null(미연동).
  String? _linkedGoogleEmail() {
    final user = settingsCurrentUser();
    if (user == null) return null;
    for (final info in user.providerData) {
      if (info.providerId == 'google.com') return info.email;
    }
    return null;
  }

  // E.2 — 교체가 아니라 승격: 지금 세션(익명 uid 포함)에 구글 계정을
  // 연결한다. linkWithCredential은 uid를 바꾸지 않으므로 옷장/이력이
  // 그대로 유지된다(signInWithCredential을 쓰면 새 uid로 전환돼 기존
  // 데이터가 고아가 되므로 여기서는 절대 쓰지 않는다).
  Future<void> _linkGoogleAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _linkingGoogle = true);
    try {
      final credential = await GoogleAuthService.pickCredential();
      if (credential == null) return; // 계정 선택 취소

      try {
        await user.linkWithCredential(credential);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Google 계정이 연동되었습니다.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } on FirebaseAuthException catch (e) {
        if (e.code == 'provider-already-linked') {
          // 이미 연결됨 — 조용히 성공 처리.
        } else if (e.code == 'credential-already-in-use') {
          // 이 구글 계정이 이미 다른 uid에 연결돼 있다(예: 재설치 후 다시
          // 연동을 시도하는 경우). 묻지 않고 전환하면 지금 기기의 데이터가
          // 고아가 되므로, 사용자 동의를 받은 뒤에만 그 기존 계정으로
          // signInWithCredential 전환한다.
          await _handleCredentialAlreadyInUse(credential);
        } else {
          rethrow;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('연동 실패: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _linkingGoogle = false);
    }
  }

  Future<void> _handleCredentialAlreadyInUse(AuthCredential credential) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이미 연결된 계정'),
        content: const Text(
          '이 Google 계정은 이미 다른 계정에 연결되어 있습니다.\n'
          '기존 계정으로 로그인하시겠습니까? 현재 기기의 데이터는 유지되지 않습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('로그인', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await FirebaseAuth.instance.signInWithCredential(credential);
      // uid가 바뀌므로 main.dart의 authStateChanges StreamBuilder가 이 화면을
      // 포함해 앱 전체를 그 기존 계정 상태로 다시 그린다.
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = settingsCurrentUser()?.uid;
    final linkedGoogleEmail = _linkedGoogleEmail();
    return Container(
      color: Colors.white,
      child: SingleChildScrollView(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 마이페이지 카드 ──
                _MyPageCard(
                  title: '마이페이지',
                  subtitle: _bodyInfoSummary(),
                  onTap: _openBodyProfile,
                ),
                const SizedBox(height: 12),
                // ── AI 비서 활동 내역 카드 ──
                _MyPageCard(
                  title: 'AI 비서 활동 내역',
                  subtitle: '에이전트가 한 일 타임라인',
                  icon: Icons.smart_toy_outlined,
                  onTap: _openAgentLog,
                ),
                // ── 체험(데모 옷장) ──
                if (uid != null) ...[
                  const SizedBox(height: 28),
                  const _SectionLabel('체험'),
                  _SettingsRow(
                    label: '데모 옷장 불러오기',
                    sub: _seedingDemo ? '불러오는 중...' : '심사·시연용 데모 옷장을 내 옷장으로 복사합니다',
                    onTap: _seedingDemo ? null : _seedDemoWardrobe,
                  ),
                  _SettingsRow(
                    label: '데모 옷장 비우기',
                    sub: '데모로 불러온 옷과 예시 일정만 삭제됩니다',
                    onTap: _clearDemoWardrobe,
                  ),
                ],
                const SizedBox(height: 28),
                const _SectionLabel('설정'),
                _SettingsRow(label: '내 스크랩', onTap: _openScraps),
                _SettingsRow(label: '사용 가이드 다시 보기', onTap: () => UsageGuide.open(context)),
                _SettingsRow(
                  label: '푸시 알림',
                  trailing: Switch.adaptive(
                    value: _pushEnabled,
                    activeThumbColor: Colors.black,
                    onChanged: (v) => setState(() => _pushEnabled = v),
                  ),
                ),
                _SettingsRow(
                  label: '마케팅 정보 수신',
                  trailing: Switch.adaptive(
                    value: _marketingEnabled,
                    activeThumbColor: Colors.black,
                    onChanged: (v) => setState(() => _marketingEnabled = v),
                  ),
                ),
                _SettingsRow(
                  label: '지역',
                  sub: '날씨 기반 코디 추천에 사용됩니다',
                  trailingText: _profile?.regionName ?? '미설정(서울)',
                  onTap: _openRegionPicker,
                ),
                const SizedBox(height: 28),
                const _SectionLabel('정보'),
                _SettingsRow(label: '이용약관', onTap: () => _comingSoon('이용약관')),
                _SettingsRow(
                    label: '개인정보처리방침',
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const PrivacyInfoScreen()))),
                _SettingsRow(label: '오픈소스 라이선스', onTap: _openLicensePage),
                const _SettingsRow(label: '앱 버전', trailingText: '1.0.0'),
                _SettingsRow(label: '테스트 도구', sub: _testToolsSub, onTap: _openTestTools),
                const SizedBox(height: 28),
                const _SectionLabel('계정'),
                _SettingsRow(
                  label: '계정 연동',
                  trailingText: linkedGoogleEmail ??
                      (_linkingGoogle ? '연동 중...' : 'Google 계정 연동'),
                  onTap: linkedGoogleEmail == null && !_linkingGoogle
                      ? _linkGoogleAccount
                      : null,
                ),
                const SizedBox(height: 32),
                GestureDetector(
                  onTap: _signOut,
                  child: const Text(
                    '로그아웃',
                    style: TextStyle(
                      color: AppColors.red,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 마이페이지 카드 ────────────────────────────────────────
class _MyPageCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData? icon; // 없으면 기본 "DOT" 뱃지, 있으면 해당 아이콘을 뱃지로 사용

  const _MyPageCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
              ),
              child: icon != null
                  ? Icon(icon, color: Colors.white, size: 20)
                  : const Text(
                      'DOT',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textDisabled, size: 18),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── 단순 리스트 행: 라벨 + (스위치 | 텍스트 | 화살표) ─────
class _SettingsRow extends StatelessWidget {
  final String label;
  final String? sub;
  final String? trailingText;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.label,
    this.sub,
    this.trailingText,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14)),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub!, style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11)),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (trailingText != null) ...[
              Text(trailingText!, style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: AppColors.textDisabled, size: 16),
              ],
            ] else if (onTap != null)
              const Icon(Icons.chevron_right, color: AppColors.textDisabled, size: 16),
          ],
        ),
      ),
    );
  }
}

// 지역 선택 시트 — 광역시도 17개 프리셋 목록. 지오코딩 검색 없음(범위
// 밖), 목록에서 고르기만 한다.
class _RegionPickerSheet extends StatelessWidget {
  final String? current;

  const _RegionPickerSheet({this.current});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                            color: AppColors.border, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text('지역 선택',
                            style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                                color: AppColors.background, borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.close, color: AppColors.textMuted, size: 18),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('날씨 기반 코디 추천에 쓰일 지역이에요',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.divider),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: regionPresets.length,
                  itemBuilder: (context, index) {
                    final preset = regionPresets[index];
                    final isSelected = preset.name == current;
                    return ListTile(
                      title: Text(preset.name,
                          style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500)),
                      trailing:
                          isSelected ? const Icon(Icons.check, color: AppColors.blue, size: 18) : null,
                      onTap: () => Navigator.pop(context, preset),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
