import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';

// 첫 실행 사용 가이드 — docs/task_demo_flow_v1.md 부분 C. 처음 앱을 여는 심사위원이
// 어떤 순서로 써야 하는지 아무 설명 없이 알 수 있게, 로그인 뒤 홈에 들어오면 옆으로
// 넘기는 전체 화면 가이드를 띄운다.
//  · "닫기": 이번만 닫는다 — 앱을 다시 열면 또 뜬다(프로세스 안에서만 기억).
//  · "다시 보지 않기": 기기 파일에 남기고 다시 띄우지 않는다.
// 설정의 "사용 가이드 다시 보기"는 이 표시와 무관하게 언제든 연다.
// 탭·버튼 이름은 실제 화면과 똑같이 쓴다(하단 탭은 글자 없이 아이콘뿐이라 아이콘으로
// 부르고, 화면 제목을 함께 적는다).
class UsageGuidePage {
  final IconData icon;
  final String title;
  final String body;
  const UsageGuidePage(this.icon, this.title, this.body);
}

class UsageGuide {
  static const pages = <UsageGuidePage>[
    UsageGuidePage(
      Icons.smart_toy_outlined,
      '내 옷장을 아는 AI 비서',
      '옷장을 등록하면 AI가 상황과 날씨에 맞춰 코디를 준비합니다.\n\n'
          '옷걸이 탭(내 옷장)에서 "데모 옷장 불러오기"를 누르면 바로 시작할 수 있어요. '
          '데모 옷장을 불러오면 내일 예시 일정이 함께 들어가요. AI 비서가 곧바로 그 일정의 코디를 준비합니다.',
    ),
    UsageGuidePage(
      Icons.auto_awesome_outlined,
      '코디 분석',
      '반짝이 탭(AI 피팅룸)에서 옷을 고르고 "AI 코디 분석하기"(전신 사진이 선택돼 있으면 '
          '"AI 코디 분석 + 가상 피팅")를 누르면, '
          'AI가 내 옷장에서 어울리는 옷을 골라 "내 스타일에 맞는 추천 옷" 맨 앞에 "AI 추천"으로 보여 줍니다.\n\n'
          '전신 사진이 선택돼 있거나 마이페이지에 체형 정보가 있을 때 옷장에서 골라 줘요. '
          '데모 옷장을 불러오면 데모 전신 사진이 자동으로 선택돼요. '
          '추천 옷을 누르면 코디보드의 그 칸에 들어가요.',
    ),
    UsageGuidePage(
      Icons.accessibility_new,
      '가상 피팅',
      'AI 피팅룸에 전신 사진이 선택돼 있으면 "AI 코디 분석 + 가상 피팅"으로 고른 옷을 사진에 입혀 봅니다. 10~20초 걸려요.\n\n'
          '데모 옷장을 불러오면 데모 전신 사진이 미리 선택돼 있어요. 다른 사진은 전신 사진 칸을 눌러 바꿀 수 있어요.',
    ),
    UsageGuidePage(
      Icons.calendar_month_outlined,
      '일정을 넣으면 미리 준비',
      '달력 탭(착장 캘린더)에 일정을 넣으면 AI 비서가 예보를 확인하고 코디를 준비합니다. 앱을 닫아 둔 사이 준비하면 알림을 보내요. '
          '예보가 바뀌면 다시 준비해요.\n\n'
          '준비한 코디는 홈에 "내일 [상황] 추천 코디"처럼 나옵니다. '
          '화면의 AI 비서 버튼을 눌러 말로 부탁할 수도 있어요.',
    ),
    UsageGuidePage(
      Icons.history,
      'AI가 한 일 보기',
      '톱니바퀴 탭(설정)의 "AI 비서 활동 내역"에서 무엇을 확인하고 왜 그렇게 골랐는지 볼 수 있어요.\n\n'
          '설정 "정보"의 "테스트 도구"에서 "예보 가정(테스트용)"을 바꾸고 '
          '"즉시 실행 (테스트)"를 누르면 날씨를 바꿔 볼 수도 있습니다.',
    ),
  ];

  // 계정 단위(docs/task_demo_flow_v1.md §4-1) — 예전엔 "다시 보지 않기"가 기기 단위 파일
  // (usage_guide_dismissed.txt)이고 "이번 실행에서 띄웠음"이 계정과 무관한 bool이라, 같은
  // 폰에서 한 계정이 닫거나 다시 보지 않기를 누르면 새 계정에도 뜨지 않았다. 옛 기기 단위
  // 파일은 더 이상 읽지 않는다.
  static String dismissFileNameFor(String uid) => 'usage_guide_dismissed_$uid.txt';
  // 이번 실행(앱 프로세스)에서 이미 띄운 계정 — 로그아웃하면 그 계정을 지운다.
  static final Set<String> _shownThisLaunch = {};

  static Future<File> _dismissFile(String uid) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/${dismissFileNameFor(uid)}');
  }

  static Future<bool> isDismissed(String uid) async {
    try {
      return await (await _dismissFile(uid)).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> dismissForever(String uid) async {
    final file = await _dismissFile(uid);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('1');
    await tmp.rename(file.path);
  }

  // 띄울지 판정(순수 함수) — 이 계정이 "다시 보지 않기"를 눌렀거나 이번 실행에서 이미
  // 띄웠으면 안 띄운다. 다른 계정의 선택은 보지 않는다.
  @visibleForTesting
  static bool shouldShow({
    required String uid,
    required Set<String> dismissedUids,
    required Set<String> shownThisLaunch,
  }) =>
      !dismissedUids.contains(uid) && !shownThisLaunch.contains(uid);

  // 로그인해 홈에 들어올 때(AppShell.initState — 로그인·새 계정 가입 모두 이 경로) 호출.
  static Future<void> maybeShow(BuildContext context, String uid) async {
    final dismissed = await isDismissed(uid);
    if (!shouldShow(uid: uid, dismissedUids: {if (dismissed) uid}, shownThisLaunch: _shownThisLaunch)) return;
    if (!context.mounted) return;
    _shownThisLaunch.add(uid); // 이 실행에서는 계정마다 한 번만
    await open(context);
  }

  // 로그아웃 시 — 같은 실행에서 같은 계정으로 다시 로그인하면 다시 띄운다.
  static void forgetLaunch(String uid) => _shownThisLaunch.remove(uid);

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => const UsageGuideScreen()),
      );
}

class UsageGuideScreen extends StatefulWidget {
  const UsageGuideScreen({super.key});

  @override
  State<UsageGuideScreen> createState() => _UsageGuideScreenState();
}

class _UsageGuideScreenState extends State<UsageGuideScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismissForever() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) await UsageGuide.dismissForever(uid);
    } catch (e) {
      debugPrint('[GUIDE] 다시 보지 않기 저장 실패(무시): $e');
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pages = UsageGuide.pages;
    final isLast = _page == pages.length - 1;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _GuidePageView(page: pages[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < pages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _page ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i == _page ? Colors.black : AppColors.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
            // 글자 크기를 키운 기기에서도 가려지지 않도록 두 버튼이 각자 절반 안에서
            // 줄바꿈한다(고정 높이 없음).
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _dismissForever,
                        child: const Text('다시 보지 않기',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.black),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(isLast ? '시작하기' : '닫기',
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
                      ),
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

class _GuidePageView extends StatelessWidget {
  final UsageGuidePage page;
  const _GuidePageView({required this.page});

  @override
  Widget build(BuildContext context) {
    // 글자를 키우면 본문이 화면을 넘을 수 있어 쪽 안에서 스크롤한다.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 56, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(18)),
            child: Icon(page.icon, size: 32, color: Colors.black),
          ),
          const SizedBox(height: 28),
          Text(page.title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
          const SizedBox(height: 16),
          Text(page.body,
              style: const TextStyle(fontSize: 15, height: 1.6, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
