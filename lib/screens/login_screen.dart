import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_colors.dart';
import '../services/google_auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;

  // 이 화면은 currentUser가 없을 때만 보인다(main.dart의 authStateChanges
  // 라우팅) — 연결할 기존 세션이 없으므로 link가 아니라 signIn이다.
  // 이 Google 계정이 이미 다른 uid에 연결돼 있었다면(재설치 케이스) 그
  // uid로 그대로 로그인되어 옷장/이력이 복원된다 — E단계 관문 2가 바로
  // 이 경로다.
  Future<void> _continueWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final credential = await GoogleAuthService.pickCredential();
      if (credential == null) return; // 사용자가 계정 선택을 취소함
      await FirebaseAuth.instance.signInWithCredential(credential);
      // 성공 시 StreamBuilder가 AppShell로 자동 전환
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('로그인 실패: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _snsComingSoon(String provider) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$provider 로그인은 준비 중입니다'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 3),
              // 로고 영역
              _buildLogo(),
              const Spacer(flex: 4),
              // 로그인 버튼 영역
              _buildLoginButtons(),
              const SizedBox(height: 20),
              // 하단 안내
              _buildFooter(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return const Column(
      children: [
        Text(
          'DOT.',
          style: TextStyle(
            color: Colors.black,
            fontSize: 36,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.0,
          ),
        ),
        SizedBox(height: 10),
        Text(
          '당신의 취향을 아는\n가장 쉬운 스타일링',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildLoginButtons() {
    return Column(
      children: [
        _SnsButton(
          label: 'Google로 계속하기',
          color: Colors.white,
          textColor: AppColors.textSecondary,
          borderColor: AppColors.border,
          icon: Icons.g_mobiledata,
          iconColor: const Color(0xFF4285F4),
          loading: _isLoading,
          onTap: _isLoading ? null : _continueWithGoogle,
        ),
        const SizedBox(height: 12),
        _SnsButton(
          label: '카카오로 계속하기',
          color: const Color(0xFFFEE500),
          textColor: const Color(0xFF3C1E1E),
          icon: Icons.chat_bubble,
          iconColor: const Color(0xFF3C1E1E),
          onTap: () => _snsComingSoon('카카오'),
        ),
        const SizedBox(height: 12),
        _SnsButton(
          label: '네이버로 계속하기',
          color: const Color(0xFF03C75A),
          textColor: Colors.white,
          icon: Icons.circle,
          iconColor: Colors.white,
          onTap: () => _snsComingSoon('네이버'),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Text(
      '계속 진행하면 이용약관 및 개인정보처리방침에\n동의하는 것으로 간주됩니다',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppColors.textPlaceholder,
        fontSize: 11,
        height: 1.5,
      ),
    );
  }
}

// ── SNS 로그인 버튼 (전체 폭, 아이콘 + 텍스트) ───────────────────────
class _SnsButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final Color? borderColor;
  final IconData icon;
  final Color iconColor;
  final VoidCallback? onTap;
  final bool loading;

  const _SnsButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.icon,
    required this.iconColor,
    this.borderColor,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: borderColor != null ? Border.all(color: borderColor!) : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              left: 16,
              child: loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: textColor, strokeWidth: 2),
                    )
                  : Icon(icon, color: iconColor, size: 22),
            ),
            Text(
              loading ? '로그인 중...' : label,
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
