// AI에게 부탁하기 — 루프 엔진(docs/task_agent_ask_v1.md §2-1).
//
// 모델이 매 단계 {"thought", "action", "args"} JSON 하나로 다음 도구를 말하면, 앱이 그 도구를
// 실행하고(ask_tools.dart) 결과를 다음 요청의 글에 붙인다. 서버의 도구 호출 차단은 그대로다.
//  · 모델 호출은 요청 하나에 최대 6회. 6회에 finish가 없으면 "여기까지 확인했어요"로 끝낸다.
//  · 출력이 규약에 어긋나면(JSON 아님, 모르는 도구, 인자 형식) 그 사실을 관찰로 돌려주고 한 번
//    더 기회를 준다. 두 번 연속 어긋나면 끝낸다.
//  · 단계당 시한 20초, 요청 전체 90초. 호출량 초과는 재시도하지 않고 안내하고 끝낸다.
//  · add_plan(유일한 쓰기)은 확인 콜백이 true를 돌려줄 때만 실행한다. 취소하면 같은 요청
//    안에서는 다시 실행하지 않는다. ask_user는 요청 하나에 1회.
//  · cancel()(뒤로 나가기)하면 진행 중인 단계의 결과를 버리고 끝낸다 — 확인을 받지 않은
//    쓰기는 실행되지 않는다.
// 모델 호출·프롬프트·확인·되묻기를 모두 주입받아 가짜 모델로 테스트한다.
import 'dart:async';

import '../models/wardrobe_item.dart';
import 'ask_registry.dart';
import 'ask_tools.dart';

export 'ask_registry.dart' show askMaxWardrobeSearches, askRepeatMessage, askWardrobeSearchLimitMessage;
import 'gemini_api_exception.dart';

// 도구 이름 목록 — 도구 등록부(ask_registry.dart)의 순서 그대로.
final askActions = [for (final t in askToolRegistry) t.name];
const askMaxModelCalls = 6;
const askStepTimeout = Duration(seconds: 20);
const askTotalTimeout = Duration(seconds: 90);

class AskModelReply {
  final Map<String, dynamic> json;
  final String model; // 응답한 모델(주 모델 / 대체 모델)
  const AskModelReply(this.json, this.model);
}

typedef AskModelCall = Future<AskModelReply> Function(String prompt);
typedef AskPromptBuilder = String Function({
  required String request,
  required List<AskStep> steps,
  required DateTime today,
  int? remainingCalls,
  String? profile,
});

// 이 횟수만큼 부른 뒤부터 프롬프트 단계 기록 끝에 남은 호출 수를 알린다(프로브 T6 다시 실행).
const askRemainingNoticeAfter = 4;

enum AskStepStatus { running, done, failed }

class AskStep {
  final String thought;
  final String action;
  final Map<String, dynamic> args;
  String? observation;
  List<WardrobeItem> items; // 화면용 옷(마지막 답 카드의 사진)
  // 화면·대화 내역·활동 내역에 보일 한 줄(v2 §2-B-1). 관찰(observation)은 모델용이다.
  String? display;
  // 형식 오류처럼 사용자에게 보이지 않는 단계.
  final bool hidden;
  AskStepStatus status;
  final String? model;
  final Duration? latency;
  AskStep({
    required this.thought,
    required this.action,
    required this.args,
    this.observation,
    this.items = const [],
    this.display,
    this.hidden = false,
    this.status = AskStepStatus.running,
    this.model,
    this.latency,
  });
}

enum AskEnd { finished, maxSteps, invalidOutput, rateLimited, timeout, cancelled, error }

class AskOutcome {
  final AskEnd end;
  final String answer; // 사용자에게 보일 마지막 글
  final List<AskStep> steps;
  final int modelCalls;
  final DateTime? plannedDate; // add_plan이 실제로 쓴 날짜
  const AskOutcome(this.end, this.answer, this.steps, this.modelCalls, {this.plannedDate});
}

// 출력 규약 검증(순수) — 맞으면 null, 아니면 모델에 돌려줄 오류 글. knownItem이 있으면 옷 번호 인자가
// 이 대화에서 보여 준 번호인지도 본다(v2 §2-C).
String? validateAskReply(Map<String, dynamic> json, {bool Function(int number)? knownItem}) {
  final thought = json['thought'];
  final action = json['action'];
  final args = json['args'] ?? const <String, dynamic>{};
  if (thought is! String || thought.trim().isEmpty) return '출력 오류: thought(한 문장)가 없어요';
  if (action is! String || !askActions.contains(action)) {
    return '출력 오류: action은 ${askActions.join('·')} 중 하나여야 해요(받은 값: $action)';
  }
  if (args is! Map) return '출력 오류: args는 객체여야 해요';
  final spec = askToolSpec(action)!;
  final error = spec.validate(args);
  if (error != null || knownItem == null) return error;
  for (final k in spec.itemArgs) {
    for (final n in askNumberList(args[k])) {
      if (!knownItem(n)) return '출력 오류: 이 대화에서 보여 준 적 없는 옷 번호예요(#$n)';
    }
  }
  return null;
}

class AskEngine {
  final AskTools tools;
  final AskModelCall callModel;
  final AskPromptBuilder buildPrompt;
  // add_plan 확인 — true면 실행. 화면이 확인 카드를 띄운다.
  final Future<bool> Function(DateTime date, String tpo) confirmPlan;
  // ask_user — 사용자의 답. null이면 답하지 않음(화면을 떠남 등).
  final Future<String?> Function(String question) askUser;
  final void Function(List<AskStep> steps)? onUpdate;
  final Duration stepTimeout;
  final Duration totalTimeout;

  AskEngine({
    required this.tools,
    required this.callModel,
    required this.buildPrompt,
    required this.confirmPlan,
    required this.askUser,
    this.onUpdate,
    this.stepTimeout = askStepTimeout,
    this.totalTimeout = askTotalTimeout,
  });

  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;

  Future<AskOutcome> run(String request) async {
    final steps = <AskStep>[];
    final watch = Stopwatch()..start();
    var calls = 0;
    var invalidStreak = 0;
    final executed = <String, int>{}; // 도구별 실행 횟수(등록부의 요청당 상한과 비교)
    final seenArgs = <String>{}; // 같은 인자 반복 막기(등록부의 dedupe)
    DateTime? plannedDate;
    final profile = await tools.profileLine(); // 프롬프트용 한 줄(있는 항목만)
    final ctx = AskRunContext(
      tools: tools,
      confirmPlan: confirmPlan,
      askUser: askUser,
      // 사용자 차례에서 기다리는 시간은 요청 전체 시한에 세지 않는다(v1 §10).
      waitForUser: <T>(Future<T> Function() wait) async {
        watch.stop();
        try {
          return await wait();
        } finally {
          watch.start();
        }
      },
      isCancelled: () => _cancelled,
    );

    AskOutcome end(AskEnd e, String answer) => AskOutcome(e, answer, steps, calls, plannedDate: plannedDate);
    String lastObservation() =>
        steps.reversed.map((s) => s.observation).whereType<String>().firstWhere((_) => true, orElse: () => '');

    while (calls < askMaxModelCalls) {
      if (_cancelled) return end(AskEnd.cancelled, '요청을 멈췄어요');
      final remaining = totalTimeout - watch.elapsed;
      if (remaining <= Duration.zero) return end(AskEnd.timeout, '시간이 오래 걸려 여기서 멈췄어요');
      final prompt = buildPrompt(
          request: request,
          steps: steps,
          today: tools.today,
          remainingCalls: calls >= askRemainingNoticeAfter ? askMaxModelCalls - calls : null,
          profile: profile);
      calls++;
      final t0 = watch.elapsed;
      AskModelReply reply;
      try {
        reply = await callModel(prompt).timeout(remaining < stepTimeout ? remaining : stepTimeout);
      } on RateLimitExceededException {
        return end(AskEnd.rateLimited, '요청이 많아 잠시 뒤에 다시 부탁해 주세요');
      } on TimeoutException {
        return end(AskEnd.timeout, '응답이 늦어 여기서 멈췄어요');
      } on FormatException catch (e) {
        if (_cancelled) return end(AskEnd.cancelled, '요청을 멈췄어요');
        invalidStreak++;
        if (invalidStreak >= 2) return end(AskEnd.invalidOutput, '답을 정리하지 못했어요. 다시 부탁해 주세요');
        steps.add(AskStep(
            thought: '(출력을 읽지 못함)',
            action: '-',
            args: const {},
            observation: '출력 오류: JSON 하나로만 답해 주세요(${e.message})',
            hidden: true,
            status: AskStepStatus.failed));
        onUpdate?.call(steps);
        continue;
      } catch (e) {
        return end(AskEnd.error, '문제가 생겨 멈췄어요: $e');
      }
      if (_cancelled) return end(AskEnd.cancelled, '요청을 멈췄어요');
      final latency = watch.elapsed - t0;

      final error = validateAskReply(reply.json, knownItem: tools.book.has);
      if (error != null) {
        invalidStreak++;
        steps.add(AskStep(
            thought: (reply.json['thought'] as Object?)?.toString() ?? '(생각 없음)',
            action: (reply.json['action'] as Object?)?.toString() ?? '-',
            args: reply.json['args'] is Map ? Map<String, dynamic>.from(reply.json['args'] as Map) : const {},
            observation: error,
            hidden: true,
            status: AskStepStatus.failed,
            model: reply.model,
            latency: latency));
        onUpdate?.call(steps);
        if (invalidStreak >= 2) return end(AskEnd.invalidOutput, '답을 정리하지 못했어요. 다시 부탁해 주세요');
        continue;
      }
      invalidStreak = 0;
      final action = reply.json['action'] as String;
      final args = Map<String, dynamic>.from((reply.json['args'] ?? const {}) as Map);
      final step = AskStep(
          thought: (reply.json['thought'] as String).trim(),
          action: action,
          args: args,
          model: reply.model,
          latency: latency);
      steps.add(step);
      onUpdate?.call(steps);

      if (action == 'finish') {
        step.status = AskStepStatus.done;
        onUpdate?.call(steps);
        return end(AskEnd.finished, (args['answer'] as String).trim());
      }

      // 도구 실행 — 등록부의 요청당 상한을 엔진이 강제한다(모델의 말이 아니라).
      final spec = askToolSpec(action)!;
      final AskToolResult result;
      final limit = spec.limitPerRequest;
      final argsKey = '$action ${_canonical(args)}';
      if (spec.dedupe && seenArgs.contains(argsKey)) {
        result = AskToolResult(spec.dedupeMessage!, display: askDisplayBlocked, ok: false);
      } else if (limit != null && (executed[action] ?? 0) >= limit) {
        result = AskToolResult(spec.limitMessage!, display: askDisplayBlocked, ok: false);
      } else {
        if (spec.dedupe) seenArgs.add(argsKey);
        final AskRunResult r;
        try {
          r = await spec.run!(ctx, args);
        } on AskCancelled {
          return end(AskEnd.cancelled, '요청을 멈췄어요');
        }
        if (r.counted) executed[action] = (executed[action] ?? 0) + 1;
        result = r.result;
        if (spec.writes) plannedDate = result.plannedDate ?? plannedDate;
      }
      if (_cancelled) return end(AskEnd.cancelled, '요청을 멈췄어요');
      step.observation = result.observation;
      step.display = result.display ?? (result.ok ? null : askDisplayFailed);
      step.items = result.items;
      step.status = result.ok ? AskStepStatus.done : AskStepStatus.failed;
      onUpdate?.call(steps);
    }
    final last = lastObservation();
    return end(AskEnd.maxSteps, last.isEmpty ? '여기까지 확인했어요' : '여기까지 확인했어요 — $last');
  }

  // 인자 비교용 — 키 순서와 공백에 상관없이 같은 인자는 같은 글.
  static String _canonical(Map<String, dynamic> args) {
    final keys = args.keys.toList()..sort();
    return keys.map((k) => '$k=${args[k]}').join('&');
  }
}
