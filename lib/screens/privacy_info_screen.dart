import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

// 설정 "개인정보처리방침" — 법률 문서가 아니라 앱이 실제로 다루는 정보의 사실 요약.
// 코드와 서버 설정으로 확인되는 것만 쓴다(근거는 docs 작업 기록). 바꿀 때는 근거부터 다시 본다.
const privacyInfoTitle = '개인정보 안내';

const privacyInfoIntro = 'DOT는 대회 출품용으로 만든 앱입니다. 아래는 앱이 실제로 다루는 정보를 요약한 것입니다.';

const privacyInfoSections = <(String, String)>[
  (
    '저장하는 정보',
    '로그인한 Google 계정, 올린 옷 사진·전신 사진, 배경을 지운 사진, 가상 피팅 결과 사진을 저장합니다. '
        '옷장 정보(옷 분석 결과), 일정, 추천 코디와 코디 기록, 스크랩, AI 비서 대화 내역과 활동 내역, '
        '입력한 체형 정보(키·몸무게 등), 알림용 기기 토큰도 저장합니다.',
  ),
  (
    '저장하는 곳',
    'Google Firebase(Firestore 데이터베이스, Cloud Storage)에 저장합니다.',
  ),
  (
    'AI 처리를 위해 보내는 것',
    '옷 분석, 코디 추천, AI 비서 답변을 위해 글과 옷 사진을 앱 서버를 거쳐 Anthropic(Claude)과 '
        'Google(Gemini)의 AI 서비스로 보냅니다. 추천을 위해 입력한 체형 정보(키·몸무게 등)도 이 글에 포함됩니다. '
        '가상 피팅을 위해 전신 사진과 옷 사진을 Google(Gemini)로 보냅니다.',
  ),
  (
    '날씨 조회',
    '설정에서 고른 지역(시·도)의 대표 좌표로, 고르지 않았으면 서울 좌표로 Open-Meteo에서 날씨를 받아 옵니다. '
        '기기 위치(GPS)는 쓰지 않습니다.',
  ),
  (
    '음성 입력',
    '음성 입력은 기기의 음성 인식 기능으로 글자로 바뀌며, 앱은 음성을 저장하지 않습니다. '
        '기기에 따라 음성 인식을 제공하는 회사(예: Google)의 서버에서 처리될 수 있습니다.',
  ),
  (
    '사진을 볼 수 있는 사람',
    '사진 파일은 본인이 올린 것과 데모 사진만 볼 수 있습니다. 데모 사진은 로그인한 사용자 모두가 볼 수 있습니다. '
        '이 제한을 넣기 전에 만들어진 개발용 예전 피팅 결과 일부는 예외입니다.',
  ),
  (
    '옷을 지울 때',
    '옷장에서 옷을 지우면 옷 정보는 지워지지만 사진 파일은 서버에 남습니다.',
  ),
];

class PrivacyInfoScreen extends StatelessWidget {
  const PrivacyInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text(privacyInfoTitle, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            const Text(privacyInfoIntro,
                style: TextStyle(fontSize: 14, height: 1.5, color: AppColors.textSecondary)),
            for (final (title, body) in privacyInfoSections) ...[
              const SizedBox(height: 20),
              Text(title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              const SizedBox(height: 6),
              Text(body, style: const TextStyle(fontSize: 14, height: 1.5, color: AppColors.textPrimary)),
            ],
          ],
        ),
      ),
    );
  }
}
