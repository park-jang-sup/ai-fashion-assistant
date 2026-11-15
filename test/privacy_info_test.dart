// 설정 "개인정보처리방침" → 개인정보 안내 화면(사실 요약).
import 'package:ai_fashion_assistant/screens/privacy_info_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('제목과 일곱 항목, 음성 입력 문장', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacyInfoScreen()));
    expect(find.text('개인정보 안내'), findsOneWidget);
    expect(find.textContaining('대회 출품용'), findsOneWidget);
    expect(privacyInfoSections.length, 7);
    final all = privacyInfoSections.map((s) => s.$2).join('\n');
    expect(all, contains('음성 입력은 기기의 음성 인식 기능으로 글자로 바뀌며, 앱은 음성을 저장하지 않습니다.'));
    expect(all, contains('추천을 위해 입력한 체형 정보(키·몸무게 등)도 이 글에 포함됩니다.'));
    expect(all, contains('데모 사진은 로그인한 사용자 모두가 볼 수 있습니다.'));
    expect(all, isNot(contains('@')));
  });
}
