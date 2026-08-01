import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';
import '../constants/app_colors.dart';
import '../models/user_profile.dart';
import '../services/background_agent.dart';
import '../services/fcm_service.dart';
import '../services/firestore_service.dart';
import '../services/google_auth_service.dart';
import '../services/notification_service.dart';
import 'agent_log_screen.dart';
import 'body_profile_screen.dart';
import 'scrap_screen.dart';

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

  // agent_meta 스트림과 별개로 관리한다 — D 케이스(로그아웃 상태에서 조기
  // 반환)처럼 agent_meta를 건드리지 않는 실행은 스트림이 emit하지 않아
  // 이 값이 그 안에 있으면 영영 안 바뀐다(2026-07-31 실기기 관측). 화면
  // 진입 시 한 번 읽고, 수동 새로고침으로만 갱신한다.
  ({String path, bool exists, int value, String? lastError})? _localCounterDiag;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _refreshLocalCounterDiagnostics();
  }

  Future<void> _refreshLocalCounterDiagnostics() async {
    final diag = await BackgroundAgent.readLocalCounterDiagnostics();
    if (mounted) setState(() => _localCounterDiag = diag);
  }

  Future<void> _loadProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
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

  // B단계 검증용 — 3시간 주기를 기다리지 않고 즉시 확인한다. force: true로
  // 빈도 가드를 우회한다.
  void _triggerBackgroundNow() {
    Workmanager().registerOneOffTask(
      'dot-bg-manual-${DateTime.now().millisecondsSinceEpoch}',
      'proactiveCheck',
      inputData: {'force': true},
    );
  }

  // 시연용 — 버튼 → 앱 완전 종료 → 잠금화면 알림 순서로 촬영하기 위해 30초
  // 지연을 둔다. 즉시 실행은 앱이 열린 상태에서 알림이 뜨므로 "앱을 안
  // 켜도 준비된다"의 증명이 되지 못한다.
  void _triggerBackgroundDelayed() {
    Workmanager().registerOneOffTask(
      'dot-bg-delayed-${DateTime.now().millisecondsSinceEpoch}',
      'proactiveCheck',
      initialDelay: const Duration(seconds: 30),
      inputData: {'force': true},
    );
  }

  // F'.3 계측 검증용 — inputData 없이 등록한다. backgroundCallbackDispatcher가
  // `inputData?['force'] == true`로 읽으므로 이 경로는 force:false로
  // run()에 들어가 실제 빈도 가드(shouldRunNow)를 그대로 태운다. 위 두
  // 버튼은 force:true라 가드를 항상 우회해 skipped:true를 온디맨드로 만들
  // 수 없었다 — 이 버튼이 그 결핍을 메운다. 직전에 위 버튼 중 하나를 눌러
  // lastRunAt이 10시간 이내로 갱신된 상태라면, 이 실행은 invocationLog에
  // skipped:true로 기록된다.
  void _triggerBackgroundNaturalCadence() {
    Workmanager().registerOneOffTask(
      'dot-bg-natural-${DateTime.now().millisecondsSinceEpoch}',
      'proactiveCheck',
    );
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
          '데모로 불러온 옷만 삭제됩니다.\n직접 등록한 옷은 그대로 남습니다.',
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데모 옷장 $count벌을 삭제했습니다.'),
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

  // B단계 진단용 — 이 uid에 등록된 모든 기기로 서버가 실제로 푸시를
  // 보낼 수 있는지 확인한다. 토큰이 0건이면 "아직 등록 안 됨"과 발송
  // 실패를 구분해서 안내한다.
  Future<void> _sendTestPush() async {
    try {
      final result = await FcmService.sendTestPush();
      if (!mounted) return;
      final message = result.tokenCount == 0
          ? '등록된 기기가 없습니다. 잠시 후 다시 시도해주세요.'
          : '${result.tokenCount}개 기기 중 ${result.sentCount}개로 발송했습니다.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('FCM 테스트 푸시 실패: $e'),
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
    final user = FirebaseAuth.instance.currentUser;
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

  // agent_meta/background 문서를 실시간 표시 — "백그라운드가 안 돌고
  // 있는데 모르는" 상황을 막는 유일한 장치(B.5).
  Widget _buildBackgroundStatus(String uid) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: FirestoreService.backgroundAgentMetaStream(uid),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('아직 실행 기록 없음',
                style: TextStyle(color: AppColors.textPlaceholder, fontSize: 11)),
          );
        }
        final fmt = DateFormat('MM/dd HH:mm:ss');
        final startedAt = (data['startedAt'] as Timestamp?)?.toDate();
        final lastRunAt = (data['lastRunAt'] as Timestamp?)?.toDate();
        final lastError = data['lastError'] as String?;
        final incomplete = startedAt != null &&
            (lastRunAt == null || startedAt.isAfter(lastRunAt));
        final invokeCount = data['invokeCount'] as int?;
        final skipCount = data['skipCount'] as int?;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '마지막 완료: ${lastRunAt != null ? fmt.format(lastRunAt) : '없음'}',
                style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
              ),
              if (incomplete)
                const Text('⚠ 마지막 실행이 완료되지 않음',
                    style: TextStyle(color: AppColors.red, fontSize: 11)),
              if (lastError != null)
                Text('오류: $lastError',
                    style: const TextStyle(color: AppColors.red, fontSize: 11)),
              // F'.3 발화 계측 — invokeCount는 "uid+meta 읽기 성공까지 도달한
              // 실행 수"(agent_meta), 아래 로컬 카운터는 Firestore·auth와
              // 무관한 "OS가 콜백을 부른 수"(기기 로컬 파일). 둘의 차이가
              // 곧 인증/초기화 단계에서 죽은 실행 수다.
              if (invokeCount != null)
                Text(
                  'invokeCount: $invokeCount'
                  '${skipCount != null ? ' (skip $skipCount)' : ''}',
                  style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
                ),
            ],
          ),
        );
      },
    );
  }

  // agent_meta 스트림과 무관하게(위 _buildBackgroundStatus와 별도) 항상 그릴
  // 수 있어야 한다 — data == null(실행 기록 없음) 상태에서도 로컬 카운터는
  // 기기 단위로 이미 존재할 수 있다. 오른쪽 새로고침 아이콘으로 언제든 다시
  // 읽는다(D처럼 agent_meta를 안 건드리는 실행 뒤에도 값을 확인하려면
  // 스트림 emit을 기다릴 수 없다).
  Widget _buildLocalCounterDiagnostics() {
    final diag = _localCounterDiag;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: diag == null
                ? const Text(
                    '로컬 카운터 읽는 중...',
                    style: TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
                  )
                : Text(
                    '로컬 발화 카운터: ${diag.value}'
                    '${diag.exists ? '' : ' (파일 없음)'}'
                    '${diag.lastError != null ? '\n오류: ${diag.lastError}' : ''}'
                    '\n경로: ${diag.path}',
                    style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            tooltip: '다시 읽기',
            onPressed: _refreshLocalCounterDiagnostics,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final showBackgroundDiagnostics =
        defaultTargetPlatform == TargetPlatform.android && uid != null;
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
                const SizedBox(height: 28),
                const _SectionLabel('설정'),
                _SettingsRow(label: '내 스크랩', onTap: _openScraps),
                _SettingsRow(
                  label: '테스트 알림 보내기',
                  onTap: () =>
                      NotificationService.showRecommendationReady('내일 [결혼식]'),
                ),
                _SettingsRow(
                  label: 'FCM 테스트 푸시',
                  sub: '서버가 이 계정의 등록 기기로 직접 보냅니다',
                  onTap: _sendTestPush,
                ),
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
                if (uid != null)
                  _SettingsRow(
                    label: '데모 옷장 비우기',
                    sub: '데모로 불러온 옷만 삭제됩니다',
                    onTap: _clearDemoWardrobe,
                  ),
                if (showBackgroundDiagnostics) ...[
                  const SizedBox(height: 28),
                  const _SectionLabel('백그라운드 에이전트(진단)'),
                  // seed.py --owner-uid / report.py가 둘 다 uid를 요구하는데
                  // 앱에 노출되는 곳이 없어 여기 붙인다. 탭하면 복사.
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: uid));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('uid를 복사했습니다'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'uid: $uid (탭하여 복사)',
                        style: const TextStyle(
                          color: AppColors.textPlaceholder,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  _buildLocalCounterDiagnostics(),
                  _buildBackgroundStatus(uid),
                  _SettingsRow(label: '즉시 실행 (테스트)', onTap: _triggerBackgroundNow),
                  _SettingsRow(
                    label: '지연 실행 30초 (시연용)',
                    sub: '누른 뒤 앱을 완전히 종료해도 실행됩니다',
                    onTap: _triggerBackgroundDelayed,
                  ),
                  _SettingsRow(
                    label: '주기 실행 시뮬레이션 (가드 적용)',
                    sub: 'force 없이 등록 — 최근 실행이 있으면 skipped로 기록됩니다',
                    onTap: _triggerBackgroundNaturalCadence,
                  ),
                ],
                const SizedBox(height: 28),
                const _SectionLabel('정보'),
                _SettingsRow(label: '이용약관', onTap: () => _comingSoon('이용약관')),
                _SettingsRow(label: '개인정보처리방침', onTap: () => _comingSoon('개인정보처리방침')),
                _SettingsRow(label: '오픈소스 라이선스', onTap: _openLicensePage),
                const _SettingsRow(label: '앱 버전', trailingText: '1.0.0'),
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
