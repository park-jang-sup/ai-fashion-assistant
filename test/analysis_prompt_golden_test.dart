// 분석 프롬프트 골든 테스트 — docs/task_agent_grounding_v1.md §3-3.
// - 자기평가용 프롬프트(_buildAttributeAnalysisPrompt)는 한 글자도 바뀌면 안 된다
//   (텍스트 모델 프로브로 검증한 점수 분포가 이 프롬프트에 묶여 있다).
// - 사용자용 프롬프트(사진·프로필)는 옷장 후보가 0개면 지금과 한 글자도 달라지면 안 된다.
// 골든은 부분 B 변경 전 출력(커밋 2c4987b 기준)이다. 다시 만들려면
//   UPDATE_GOLDENS=1 flutter test test/analysis_prompt_golden_test.dart
// (의도한 변경이 아니면 다시 만들지 않는다.)
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/user_profile.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _items = [
  (category: '상의', attributes: ClothingAttributes(color: '블랙', style: '미니멀', pattern: '무지', formality: '세미포멀', fit: '레귤러', tags: ['니트', '반팔'])),
  (category: '하의', attributes: ClothingAttributes(color: '차콜', style: '포멀', pattern: '스트라이프', formality: '세미포멀', fit: '오버사이즈', tags: ['슬랙스'])),
  (category: '신발', attributes: ClothingAttributes(color: '아이보리', style: '캐주얼', pattern: '무지', formality: '캐주얼', fit: '레귤러', tags: [])),
];
const _profile = UserProfile(heightCm: 178, bodyType: '보통 체형', personalColor: '겨울쿨', preferredStyles: ['미니멀']);
const _history = '- 11/10 [출근] 네이비 블레이저 + 그레이 슬랙스 (82점)\n- 11/08 [일상] 화이트 티 + 데님 (75점)';

void _golden(String name, String actual) {
  final file = File('test/goldens/$name.txt');
  if (Platform.environment['UPDATE_GOLDENS'] == '1') {
    file.writeAsStringSync(actual);
    return;
  }
  // CRLF 체크아웃(Windows autocrlf)에서도 비교가 깨지지 않게 줄바꿈을 맞춘다.
  expect(actual, file.readAsStringSync().replaceAll('\r\n', '\n'), reason: 'test/goldens/$name.txt와 다르다');
}

String _p(String kind, {String? history, bool relevance = false}) =>
    GeminiService.analysisPromptsForGoldenTest(_items,
        kind: kind, profile: _profile, recentHistoryText: history, isRelevanceRanked: relevance);

void main() {
  test('자기평가용 프롬프트 — 이력 없음', () => _golden('self_eval_no_history', _p('selfEval')));
  test('자기평가용 프롬프트 — 이력 있음(관련도)', () =>
      _golden('self_eval_history', _p('selfEval', history: _history, relevance: true)));
  test('사진용 프롬프트(후보 0개) — 이력 없음', () => _golden('photo_no_history', _p('photo')));
  test('사진용 프롬프트(후보 0개) — 이력 있음', () => _golden('photo_history', _p('photo', history: _history)));
  test('프로필용 프롬프트(후보 0개) — 이력 없음', () => _golden('profile_no_history', _p('profile')));
  test('프로필용 프롬프트(후보 0개) — 이력 있음(관련도)', () =>
      _golden('profile_history', _p('profile', history: _history, relevance: true)));
}
