import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_colors.dart';
import '../models/user_profile.dart';
import '../services/firestore_service.dart';
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

  @override
  void initState() {
    super.initState();
    _loadProfile();
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

  void _openLicensePage() {
    showLicensePage(
      context: context,
      applicationName: 'DOT.',
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
    }
  }

  @override
  Widget build(BuildContext context) {
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
                const SizedBox(height: 28),
                const _SectionLabel('정보'),
                _SettingsRow(label: '이용약관', onTap: () => _comingSoon('이용약관')),
                _SettingsRow(label: '개인정보처리방침', onTap: () => _comingSoon('개인정보처리방침')),
                _SettingsRow(label: '오픈소스 라이선스', onTap: _openLicensePage),
                const _SettingsRow(label: '앱 버전', trailingText: '1.0.0'),
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
