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
// 프롬프트 생성과 무관하다. [정정 2026-08-12] 인자 전수 대조까지
// 마쳤다 - run()이 evalOne 경유로 넘기는 7개 매개변수(items·
// userPhotoId·userPhotoUrl·userProfile·recentHistoryText·
// isRelevanceRanked·model) 중 model을 뺀 6개 전부가 이 하네스의
// 호출값과 정확히 일치함을 확인했다(§6-가 문서의 "인자 전수 대조"
// 절 참고, 불일치 0건). 총점 파싱도 OutfitSelfEvaluator.parseScore()
// (공개 static)를 그대로 재사용한다.
//
// 요청 본문 동일성(정적 코드 대조, API 호출로 확인하지 않음 - 낭비
// 금지): model은 analyzeOutfitFromAttributes 안에서 _callProxyText의
// requestBody와 나란한 별도 인자로만 쓰이고 prompt/requestBody 구성
// 어디에도 안 들어간다 - 코드에 그런 분기가 없다.
//
// [2026-08-12, 두 번째 개정] 블록 교차 실행 + 실행 순서 이유: 업스트림
// 상태가 5분 창 안에서 폴백률을 12.9배로 흔든 사례가 이미 있다(§6-가
// 프록시 로그 대조) - 조건 F 20회를 전부 돌고 조건 L 20회를 돈다면
// 두 블록이 10분 안팎 떨어져 서로 다른 업스트림 상태에서 측정될
// 수 있고, 그러면 "모델 차이"로 잰 것이 실은 "시간대 차이"일 수
// 있다. F10 -> L10 -> F10 -> L10 순서로 교차 실행해 이 교란을 줄인다.
// **분석 방법(N=20/조건, α=0.05, Welch, SD 문턱 5, 2×2 판정표)은
// 하나도 안 바뀐다 - 바뀌는 것은 수집 순서뿐이다.**
//
// 정지 규칙(조건 단위로 유지, 블록으로 쪼개되 합계 상한은 그대로):
// 조건 F는 누적 호출 50건, 조건 L은 누적 호출 25건을 넘지 않는다.
// 각 블록은 그 조건이 아직 못 채운 성공 개수(최대 10)를 목표로 돌되,
// 조건의 누적 호출이 상한에 닿으면 그 블록에서 바로 멈춘다.
// [정정] 이전 판(커밋 a097d51)은 회차 시작 전에 최악(재시도 포함
// 2회)을 미리 예약하는 방식(`callsUsed + 2 <= maxCalls`)이라, 누적
// 호출이 상한보다 홀수 차이로 모자란 지점에서 1회 더 들어갈 여유가
// 있어도 멈추는 경우가 있었다(예: maxCalls=25일 때 callsUsed=24면
// 24+2=26>25로 멈춤 - 그런데 다음 회차가 1차 시도에서 바로 성공하면
// 25에 정확히 닿을 수 있었다). 이번 판은 **회차 시작 전에는
// `callsUsed < maxCalls`만 확인하고, 재시도로 넘어가기 직전에
// `callsUsed(1차 소비 후) < maxCalls`를 한 번 더 확인**하는 방식으로
// 바꿔, 상한을 절대 안 넘기면서도 상한까지 정확히 채울 수 있게
// 했다(더 이상 최대 1회 미만 여유를 남기지 않는다).
//
// 버킷 분리: 블록마다 새 익명 uid를 받는다(signOut 후
// signInAnonymously) - 이번 실행으로 uid 4개가 새로 생긴다(정리
// 목록에 추가, 삭제는 안 함). 각 uid의 호출은 25건 안팎으로
// rate_limit.textLimit=60/시간에 한참 못 미친다.
//
// 타임스탬프: 모든 시도(1차·재시도 각각)의 시작·종료 시각을
// ISO8601로 기록한다 - 사후에 블록 간·시간대 드리프트를 확인할 수
// 있어야 한다.
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

// §6-가 2차 측정 설계 - 결과를 보기 전에 고정. 조건 단위 상한(F=50,
// L=25)과 조건 단위 목표(20)는 그대로다 - 블록은 이 값을 나눠 채울
// 뿐 새 상한이 아니다.
const int _kTargetSuccessesPerCondition = 20;
const int _kBlockTargetSuccesses = 10; // 블록 1개가 노리는 성공 개수
const int _kMaxCallsF = 50; // 조건 F 누적 상한
const int _kMaxCallsL = 25; // 조건 L 누적 상한
const String _kModelF = 'gemini-3.5-flash';
const String _kModelL = 'gemini-3.1-flash-lite';

String _nowIso() => DateTime.now().toUtc().toIso8601String();

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

// 한 회차 = 1차 시도 + (재시도 가능하고 예산이 남았으면) 같은 모델로
// 최대 1회 재시도. callsUsedBefore/maxCalls를 받아 재시도 여부를
// 정확히 상한 안에서만 판단한다(위 파일 헤더 "정지 규칙" 정정 참고).
class _TrialResult {
  final bool success;
  final String? text;
  final String errorKind;
  final int callsUsed;
  final String startedAt;
  final String endedAt;
  const _TrialResult({
    required this.success,
    this.text,
    this.errorKind = '',
    required this.callsUsed,
    required this.startedAt,
    required this.endedAt,
  });
}

Future<_TrialResult> _runTrial(String model, int callsUsedBefore, int maxCalls) async {
  final startedAt = _nowIso();
  final first = await _attemptOnce(model);
  if (first.success) {
    return _TrialResult(
      success: true,
      text: first.text,
      callsUsed: 1,
      startedAt: startedAt,
      endedAt: _nowIso(),
    );
  }
  if (!_isRetryableKind(first.errorKind)) {
    return _TrialResult(
      success: false,
      errorKind: first.errorKind,
      callsUsed: 1,
      startedAt: startedAt,
      endedAt: _nowIso(),
    );
  }
  // 재시도가 상한을 넘기지 않는지 확인한 뒤에만 시도한다 - 1차 시도로
  // 이미 1회를 썼으므로 여기서 여유가 없으면 재시도 없이 실패로 끝낸다.
  if (callsUsedBefore + 1 >= maxCalls) {
    return _TrialResult(
      success: false,
      errorKind: '${first.errorKind}(재시도 생략 - 호출 예산 소진)',
      callsUsed: 1,
      startedAt: startedAt,
      endedAt: _nowIso(),
    );
  }
  final retry = await _attemptOnce(model);
  if (retry.success) {
    return _TrialResult(
      success: true,
      text: retry.text,
      callsUsed: 2,
      startedAt: startedAt,
      endedAt: _nowIso(),
    );
  }
  return _TrialResult(
    success: false,
    errorKind: '1차=${first.errorKind}, 재시도=${retry.errorKind}',
    callsUsed: 2,
    startedAt: startedAt,
    endedAt: _nowIso(),
  );
}

// 조건(F/L)의 누적 상태 - 두 블록에 걸쳐 이어받는다.
class _ConditionState {
  final String label;
  final String model;
  final int maxCalls;
  final List<int> successScores = [];
  final List<String> failureReasons = [];
  int callsUsed = 0;
  _ConditionState(this.label, this.model, this.maxCalls);
}

// 블록 하나 실행 - 새 익명 uid를 받고, 그 조건이 아직 못 채운 만큼을
// (최대 _kBlockTargetSuccesses) 목표로 돈다. state를 직접 갱신한다.
Future<void> _runBlock(_ConditionState state, int blockIndex) async {
  await FirebaseAuth.instance.signOut();
  final cred = await FirebaseAuth.instance.signInAnonymously();
  final uid = cred.user?.uid;
  // ignore: avoid_print
  print('[MODELFIX] 블록 ${state.label}$blockIndex 익명 로그인 uid: $uid '
      '(model=${state.model}, 조건 누적 호출=${state.callsUsed}/${state.maxCalls})');
  expect(uid, isNotNull,
      reason: '블록 ${state.label}$blockIndex: signInAnonymously가 uid를 발급하지 못했습니다.');

  final blockTarget = (_kTargetSuccessesPerCondition - state.successScores.length)
      .clamp(0, _kBlockTargetSuccesses);
  var blockSuccessCount = 0;
  var trialIndex = 0;

  while (blockSuccessCount < blockTarget && state.callsUsed < state.maxCalls) {
    final trial = await _runTrial(state.model, state.callsUsed, state.maxCalls);
    state.callsUsed += trial.callsUsed;
    if (trial.success) {
      final score = OutfitSelfEvaluator.parseScore(trial.text!);
      state.successScores.add(score ?? 0);
      blockSuccessCount++;
      _printResult({
        'condition': state.label,
        'block': blockIndex,
        'model': state.model,
        'uid': uid,
        'trialIndexInBlock': trialIndex,
        'score': score,
        'callsUsedThisTrial': trial.callsUsed,
        'callsUsedConditionCumulative': state.callsUsed,
        'startedAt': trial.startedAt,
        'endedAt': trial.endedAt,
      });
    } else {
      state.failureReasons.add(trial.errorKind);
      _printResult({
        'condition': state.label,
        'block': blockIndex,
        'model': state.model,
        'uid': uid,
        'trialIndexInBlock': trialIndex,
        'error': trial.errorKind,
        'callsUsedThisTrial': trial.callsUsed,
        'callsUsedConditionCumulative': state.callsUsed,
        'startedAt': trial.startedAt,
        'endedAt': trial.endedAt,
      });
    }
    trialIndex++;
  }

  // ignore: avoid_print
  print('[MODELFIX_BLOCK_SUMMARY] ${jsonEncode({
        'condition': state.label,
        'block': blockIndex,
        'uid': uid,
        'blockSuccessCount': blockSuccessCount,
        'blockTarget': blockTarget,
        'conditionSuccessCumulative': state.successScores.length,
        'conditionCallsCumulative': state.callsUsed,
        'conditionMaxCalls': state.maxCalls,
      })}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('self-eval 2차 측정 하네스 (모델 고정, 블록 교차 F10-L10-F10-L10)',
      (tester) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    // ignore: avoid_print
    print('[MODELFIX] 고정 조합(하드코딩, self_eval_repeat_probe.dart와 동일): '
        '${kFixedCombo.map((it) => '${it.category}:${it.id}').toList()}');

    final stateF = _ConditionState('F', _kModelF, _kMaxCallsF);
    final stateL = _ConditionState('L', _kModelL, _kMaxCallsL);

    // F10 -> L10 -> F10 -> L10 - 시간대 교란을 상쇄하기 위한 순서
    // (파일 헤더 "블록 교차 실행" 참고). 각 호출이 실제로 그 블록의
    // 목표(최대 10)를 못 채우면(예산 소진) 다음 조건의 블록으로 그냥
    // 넘어간다 - 블록 간 시간을 억지로 맞추지 않는다(자연 진행).
    await _runBlock(stateF, 1);
    await _runBlock(stateL, 1);
    await _runBlock(stateF, 2);
    await _runBlock(stateL, 2);

    for (final state in [stateF, stateL]) {
      // ignore: avoid_print
      print('[MODELFIX_SUMMARY] ${jsonEncode({
            'condition': state.label,
            'model': state.model,
            'successCount': state.successScores.length,
            'targetSuccesses': _kTargetSuccessesPerCondition,
            'callsUsed': state.callsUsed,
            'maxCalls': state.maxCalls,
            'capReached': state.successScores.length < _kTargetSuccessesPerCondition,
            'failureCount': state.failureReasons.length,
            'failureReasons': state.failureReasons,
            'scores': state.successScores,
          })}');
    }

    // ignore: avoid_print
    print('[MODELFIX] 완료');
  }, timeout: const Timeout(Duration(minutes: 75)));
}
