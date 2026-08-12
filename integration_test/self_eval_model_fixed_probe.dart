// docs/task_selfeval_validity_v1.md §6-가 - 2차 측정(모델 고정) 하네스.
//
// 목적: self_eval_repeat_probe.dart(1차, N=20 혼합)가 잰 것은 "척도의
// 반복 신뢰도"가 아니라 "척도 + withTextModelFallback 모델 라우팅"의
// 합성 분산이었다(§6-가 프록시 로그 대조). 이 하네스는 모델을 조건별로
// 고정해(F=gemini-3.5-flash, L=gemini-3.1-flash-lite) 같은 조합을 다시
// 재고, 조건 내 분산과 조건 간 평균차를 분리해서 본다.
//
// 재구현 금지 원칙(§6-가 "하네스 위치 결정"): 프롬프트를 다시 만들지
// 않는다. self_eval_repeat_probe.dart의 kFixedCombo(공개, 2026-08-12)를
// 그대로 가져다 쓰고, GeminiService.analyzeOutfitFromAttributes()(본
// 경로가 프롬프트를 만드는 바로 그 공개 함수)를 model만 고정해 직접
// 호출한다. OutfitSelfEvaluator.run()/GeminiService.withTextModelFallback을
// 우회하지만, 그 둘은 "어느 모델로 부를지 고르는 라우팅 계층"일 뿐
// 프롬프트 생성과 무관하다 - analyzeOutfitFromAttributes 안에서 model은
// _callProxyText(model:, requestBody:)의 형제 필드로만 쓰이고 prompt/
// requestBody 구성 어디에도 안 들어간다(코드 확인, 아래 "요청 본문
// 동일성" 참고) - 그래서 이 우회로 재는 대상이 달라지지 않는다.
// 총점 파싱도 OutfitSelfEvaluator.parseScore()(공개 static)를 그대로
// 재사용한다 - 재구현하지 않는다.
//
// 요청 본문 동일성(정적 코드 대조, API 호출로 확인하지 않음 - 낭비
// 금지): gemini_service.dart의 analyzeOutfitFromAttributes를 보면
// prompt/requestBody(contents/generationConfig)는 items·userPhotoUrl·
// userProfile·recentHistoryText·isRelevanceRanked에서만 만들어지고,
// model은 함수 맨 끝 `_callProxyText(model: model ?? _textModel,
// requestBody: requestBody)` 호출에서 requestBody와 나란한 별도
// 인자로만 쓰인다(RPC 페이로드 `{'model': model, 'requestBody':
// requestBody}`에서도 형제 필드). 즉 requestBody는 model 값과
// 무관하게 항상 동일하다 - 이 하네스와 OutfitSelfEvaluator.run()이
// 똑같이 items=kFixedCombo 매핑, recentHistoryText=null,
// isRelevanceRanked=false, userPhotoUrl/userProfile 미전달을 쓰므로
// (run()이 evalOne에서 이 값들을 그대로 안 넘기는 것과 동일 - §2에서
// 이미 확인된 사실), 두 경로가 만드는 requestBody는 model 필드
// 하나만 다르고 나머지는 항상 같다.
//
// 정지 규칙·버킷 분리(§6-가 2차 측정 설계 (A) 이어서, 결과 보기 전
// 고정): 조건 F는 min(성공 20건, 호출 50건), 조건 L은 min(성공 20건,
// 호출 25건)에서 멈춘다. 두 조건은 반드시 다른 익명 uid에서 돈다
// (rate_limit.textLimit=60/시간, uid당 - 조건 F+L을 한 uid에서 돌리면
// 75건으로 60을 넘을 수 있다). 이 파일은 한 번의 flutter test 실행
// 안에서 조건마다 signOut() 후 signInAnonymously()로 새 uid를 받는
// 방식을 택했다(§6-가 2차 측정 설계가 "구현 시점에 결정, 승인 대상
// 아님"으로 남겨둔 두 방식 중 하나 - 별도 실행 대신 이쪽을 골랐다,
// 빌드·설치를 한 번만 하면 되는 쪽이 절차 실수 여지가 적다는 판단).
//
// 재시도 정책(같은 모델로 최대 1회, 폴백 없음): withTextModelFallback과
// 같은 세 예외(TimeoutException/GeminiApiException.isRetryable/
// FormatException)에서만 재시도하되, 다른 모델로 바꾸지 않고 같은
// 모델로 다시 호출한다. 재시도까지 실패하면 그 회차는 실패로 기록하고
// 다음 회차로 넘어간다(폐기, 표본에서 자연 손실 - §6-가 2차 측정
// 설계 (A)가 이미 등록한 대로 실패율 자체를 성공 점수 통계와 나란히
// 보고한다).
//
// 실행 명령 예:
//   flutter test integration_test/self_eval_model_fixed_probe.dart -d <deviceId>

import 'dart:async';
import 'dart:convert';

import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:ai_fashion_assistant/firebase_options.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:ai_fashion_assistant/services/gemini_api_exception.dart';
import 'package:ai_fashion_assistant/services/outfit_self_evaluator.dart';

import 'self_eval_repeat_probe.dart' show kFixedCombo;

// §6-가 2차 측정 설계 - 결과를 보기 전에 고정.
const int _kTargetSuccesses = 20;
const int _kMaxCallsF = 50; // gemini-3.5-flash 고정
const int _kMaxCallsL = 25; // gemini-3.1-flash-lite 고정
const String _kModelF = 'gemini-3.5-flash';
const String _kModelL = 'gemini-3.1-flash-lite';

void _printResult(Map<String, dynamic> data) {
  // ignore: avoid_print
  print('[MODELFIX_RESULT] ${jsonEncode(data)}');
}

// 한 번의 API 시도 결과 - 성공/실패와 실패라면 어떤 예외였는지
// (statusCode 포함, §6-가 폴백 상태코드 규명 시도가 열어 둔 배포된
// 로깅과 나란히 클라이언트에서도 남긴다).
class _Attempt {
  final bool success;
  final String? text;
  final String errorKind;
  final int? statusCode;
  const _Attempt({required this.success, this.text, this.errorKind = '', this.statusCode});
}

Future<_Attempt> _attemptOnce(String model) async {
  try {
    final text = await GeminiService.analyzeOutfitFromAttributes(
      items: kFixedCombo.map((it) => (category: it.category, attributes: it.attributes!)).toList(),
      recentHistoryText: null,
      isRelevanceRanked: false,
      model: model,
    );
    return _Attempt(success: true, text: text);
  } on TimeoutException {
    return const _Attempt(success: false, errorKind: 'TimeoutException');
  } on GeminiApiException catch (e) {
    final kind = e.isRetryable
        ? 'GeminiApiException(재시도가능,statusCode=${e.statusCode})'
        : 'GeminiApiException(비재시도,statusCode=${e.statusCode})';
    return _Attempt(success: false, errorKind: kind, statusCode: e.statusCode);
  } on FormatException {
    return const _Attempt(success: false, errorKind: 'FormatException');
  } catch (e) {
    return _Attempt(success: false, errorKind: '기타: $e');
  }
}

bool _isRetryableKind(String errorKind) {
  return errorKind == 'TimeoutException' ||
      errorKind.startsWith('GeminiApiException(재시도가능') ||
      errorKind == 'FormatException';
}

// 한 회차 = 1차 시도 + (재시도 가능하면) 같은 모델로 최대 1회 재시도.
// 소비한 호출 수를 함께 반환해 정지 규칙(호출 예산)이 정확히 셀 수
// 있게 한다.
class _TrialResult {
  final bool success;
  final String? text;
  final String errorKind;
  final int callsUsed;
  const _TrialResult({
    required this.success,
    this.text,
    this.errorKind = '',
    required this.callsUsed,
  });
}

Future<_TrialResult> _runTrial(String model) async {
  final first = await _attemptOnce(model);
  if (first.success) {
    return _TrialResult(success: true, text: first.text, callsUsed: 1);
  }
  if (!_isRetryableKind(first.errorKind)) {
    return _TrialResult(success: false, errorKind: first.errorKind, callsUsed: 1);
  }
  final retry = await _attemptOnce(model);
  if (retry.success) {
    return _TrialResult(success: true, text: retry.text, callsUsed: 2);
  }
  return _TrialResult(
    success: false,
    errorKind: '1차=${first.errorKind}, 재시도=${retry.errorKind}',
    callsUsed: 2,
  );
}

Future<void> _runCondition(String label, String model, int maxCalls) async {
  // 조건마다 새 익명 uid를 받는다 - rate_limit 버킷 분리(§6-가 2차
  // 측정 설계 (A) 이어서). 이미 로그인돼 있어도(F 실행 직후) signOut()
  // 후 signInAnonymously()는 이전 uid를 이어받지 않고 새 uid를 만든다.
  await FirebaseAuth.instance.signOut();
  final cred = await FirebaseAuth.instance.signInAnonymously();
  final uid = cred.user?.uid;
  // ignore: avoid_print
  print('[MODELFIX] 조건 $label 익명 로그인 uid: $uid (model=$model, maxCalls=$maxCalls)');
  expect(uid, isNotNull, reason: '조건 $label: signInAnonymously가 uid를 발급하지 못했습니다.');

  final successScores = <int>[];
  final failureReasons = <String>[];
  var callsUsed = 0;
  var trialIndex = 0;

  // 회차 시작 전에 "이 회차가 최악의 경우(재시도까지) 2회를 써도
  // maxCalls를 안 넘는지"를 먼저 확인한다 - 상한을 절대 넘기지 않기
  // 위한 보수적 정지(§6-가 2차 측정 설계 (A) 이어서, "최대 +1회차
  // 초과 가능"이 아니라 아예 넘지 않도록 구현).
  while (successScores.length < _kTargetSuccesses && callsUsed + 2 <= maxCalls) {
    final trial = await _runTrial(model);
    callsUsed += trial.callsUsed;
    if (trial.success) {
      final score = OutfitSelfEvaluator.parseScore(trial.text!);
      successScores.add(score ?? 0);
      _printResult({
        'condition': label,
        'model': model,
        'trialIndex': trialIndex,
        'score': score,
        'callsUsedThisTrial': trial.callsUsed,
        'callsUsedCumulative': callsUsed,
      });
    } else {
      failureReasons.add(trial.errorKind);
      _printResult({
        'condition': label,
        'model': model,
        'trialIndex': trialIndex,
        'error': trial.errorKind,
        'callsUsedThisTrial': trial.callsUsed,
        'callsUsedCumulative': callsUsed,
      });
    }
    trialIndex++;
  }

  // ignore: avoid_print
  print('[MODELFIX_SUMMARY] ${jsonEncode({
        'condition': label,
        'model': model,
        'successCount': successScores.length,
        'targetSuccesses': _kTargetSuccesses,
        'callsUsed': callsUsed,
        'maxCalls': maxCalls,
        'capReached': successScores.length < _kTargetSuccesses,
        'failureCount': failureReasons.length,
        'failureReasons': failureReasons,
        'scores': successScores,
      })}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('self-eval 2차 측정 하네스 (모델 고정, 조건 F/L)', (tester) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    // ignore: avoid_print
    print('[MODELFIX] 고정 조합(하드코딩, self_eval_repeat_probe.dart와 동일): '
        '${kFixedCombo.map((it) => '${it.category}:${it.id}').toList()}');

    await _runCondition('F', _kModelF, _kMaxCallsF);
    await _runCondition('L', _kModelL, _kMaxCallsL);

    // ignore: avoid_print
    print('[MODELFIX] 완료');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
