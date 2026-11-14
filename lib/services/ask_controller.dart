// AI에게 부탁하기 — 앱 수준 진행 컨트롤러(docs/task_agent_ask_v1.md §10 B, task_agent_ask_v2.md §2-D).
// 가상 피팅의 FittingJobController처럼 AppShell이 갖고 있어서, 전용 화면을 닫아도 대화는 계속 진행된다.
// 화면과 떠 있는 버튼은 이 컨트롤러를 구독만 한다.
//  · 대화 하나 = 여러 턴(사용자 말 → 단계들 → 답). 답이 나온 뒤에도 이어서 말할 수 있다(10턴까지).
//    대화 안의 옷 번호는 AskTools 하나가 갖고, 이전 턴은 사용자 말·답과 [현재 코디]만 다음 턴에 넘긴다.
//  · 한 번에 턴 하나만 진행한다(start는 진행 중이면 false).
//  · add_plan은 확인 카드에서 [등록]을 눌러야만 실행된다 — 화면이 닫혀 있으면 확인을 기다린다.
//  · [멈추기]만 진행을 멈춘다(뒤로 나가기는 멈추지 않는다).
//  · 턴이 끝나면(답·멈춤·실패) 대화 내역(대화 전체)과 활동 내역 끝 줄을 남긴다.
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/agent_log_entry.dart';
import '../models/wardrobe_item.dart';
import 'ask_activity_log.dart';
import 'ask_data_source.dart';
import 'ask_engine.dart';
import 'ask_history.dart';
import 'ask_prompt.dart';
import 'ask_tools.dart';
import 'firestore_service.dart';
import 'gemini_service.dart';

// 떠 있는 버튼의 모양 — 평소 / 진행 중(고리) / 사용자 차례·새 답(점).
enum AskButtonState { idle, running, attention }

// 대화 하나의 턴 상한(v2 §2-D).
const askMaxTurns = 10;

// 답 카드의 사진·"피팅룸에서 입어 보기"·대화 내역의 사진 — 이번 턴에 정해진 조합만(v2.1 A-3의 1~3: finish의
// outfit → 성공한 try_on → 옷이 붙은 마지막 단계). 이전 [현재 코디]를 이어받는 4)는 다음 턴의 [현재 코디]
// (outcome.outfit)에만 쓰고, 이번 턴에 조합이 없는 답에는 사진을 붙이지 않는다.
List<WardrobeItem> askCombo(AskOutcome o) => askOutfitOf(o.steps)?.items ?? const [];

// 이 턴의 가상 피팅 결과 사진(마지막 것).
AskFittingShot? askFittingOf(List<AskStep> steps) =>
    [for (final s in steps) if (s.fitting != null) s.fitting!].lastOrNull;

// 대화의 턴 하나.
class AskTurn {
  final String request;
  final DateTime createdAt;
  List<AskStep> steps = const [];
  AskOutcome? outcome;
  AskTurn(this.request, this.createdAt);
}

class AskController extends ChangeNotifier {
  final String? Function() _uid;
  // 테스트용 주입 — 없으면 로그인한 사용자의 Firestore 자료·GeminiService·활동 내역·기록 저장소.
  final AskTools Function(String uid)? toolsFor;
  final AskModelCall? callModel;
  final void Function(AgentLogEntry entry)? logSink;
  final AskHistoryStore Function(String uid)? historyFor;
  final DateTime Function() _now;
  // 앱의 가상 피팅 경로(AppShell이 넘긴다) — try_on이 쓴다.
  final AskFittingPort? fitting;

  AskController({
    String? Function()? currentUid,
    this.toolsFor,
    this.callModel,
    this.logSink,
    this.historyFor,
    this.fitting,
    DateTime Function()? now,
  })  : _uid = currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _now = now ?? DateTime.now;

  // 대화
  final List<AskTurn> _turns = [];
  AskTools? _tools;
  String? _conversationId;
  AskOutfit? _outfit; // 다음 턴의 [현재 코디]

  (DateTime, String)? _confirmArgs;
  String? _question;
  Completer<bool>? _confirm;
  Completer<String?>? _answer;
  AskEngine? _engine;
  bool _stopping = false;
  bool _seen = true;
  int _viewers = 0;
  int _runId = 0;
  List<AskRecord>? _history;
  bool _disposed = false;

  List<AskTurn> get turns => List.unmodifiable(_turns);
  AskTurn? get _last => _turns.isEmpty ? null : _turns.last;
  // 지금(마지막) 턴.
  String? get request => _last?.request;
  List<AskStep> get steps => _last?.steps ?? const [];
  AskOutcome? get outcome => _last?.outcome;
  AskOutfit? get currentOutfit => _outfit;
  (DateTime, String)? get confirmArgs => _confirmArgs;
  String? get question => _question;
  bool get isRunning => _last != null && _last!.outcome == null;
  bool get isStopping => _stopping;
  bool get userTurn => isRunning && (_confirmArgs != null || _question != null);
  bool get hasConversation => _turns.isNotEmpty;
  // 이어서 말할 수 있는가 — 진행 중이 아니고 10턴 전.
  bool get canContinue => !isRunning && _turns.length < askMaxTurns;
  bool get turnLimitReached => _turns.length >= askMaxTurns && !isRunning;
  List<AskRecord>? get history => _history;
  DateTime get today => _now();

  AskButtonState get buttonState {
    if (userTurn) return AskButtonState.attention;
    if (isRunning) return AskButtonState.running;
    if (outcome != null && !_seen) return AskButtonState.attention;
    return AskButtonState.idle;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // 전용 화면이 열려 있는 동안 — 그 사이에 나온 답은 본 것으로 친다.
  void attach() {
    _viewers++;
    if (outcome != null) _seen = true;
    _changed();
  }

  void detach() {
    if (_viewers > 0) _viewers--;
  }

  AskHistoryStore _store(String uid) => historyFor?.call(uid) ?? FirestoreAskHistoryStore(uid);

  Future<void> loadHistory() async {
    final uid = _uid();
    if (uid == null) return;
    try {
      _history = await _store(uid).recent();
    } catch (e) {
      debugPrint('[ASK] 대화 내역을 불러오지 못함(무시): $e');
      _history ??= const [];
    }
    _changed();
  }

  // 사용자 말 — 대화가 없으면 새 대화를, 있으면 다음 턴을 시작한다. 진행 중이거나 10턴을 채웠으면 false.
  bool start(String text) {
    final request = text.trim();
    if (request.isEmpty || isRunning || _turns.length >= askMaxTurns) return false;
    final uid = _uid();
    final id = ++_runId;
    final history = [
      for (final t in _turns)
        if (t.outcome != null) AskTurnBrief(t.request, t.outcome!.answer),
    ];
    final turn = AskTurn(request, _now());
    _conversationId ??= 'ask_${turn.createdAt.millisecondsSinceEpoch}';
    _turns.add(turn);
    _confirmArgs = null;
    _question = null;
    _stopping = false;
    _seen = false;
    _changed();
    if (uid == null) {
      turn.outcome = const AskOutcome(AskEnd.error, '로그인한 뒤에 부탁할 수 있어요', [], 0);
      _seen = _viewers > 0;
      _changed();
      return true;
    }
    _tools ??= toolsFor?.call(uid) ?? AskTools(FirestoreAskDataSource(uid));
    unawaited(_run(uid, turn, history, id));
    return true;
  }

  Future<void> _run(String uid, AskTurn turn, List<AskTurnBrief> history, int id) async {
    bool current() => id == _runId && !_disposed;
    final conversationId = _conversationId!;
    final log = AskActivityLog(
      write: logSink ?? (e) => unawaited(FirestoreService.addAgentLogSilently(uid, e)),
      relatedId: 'ask_${_now().millisecondsSinceEpoch}',
    );
    log.started(turn.request);
    final engine = AskEngine(
      tools: _tools!,
      callModel: callModel ??
          (prompt) async {
            final r = await GeminiService.callAgentStep(prompt);
            return AskModelReply(r.json, r.model);
          },
      buildPrompt: buildAskPrompt,
      fitting: fitting,
      confirmPlan: (date, tpo) {
        if (!current()) return Future.value(false);
        final c = Completer<bool>();
        _confirm = c;
        _confirmArgs = (date, tpo);
        _changed();
        return c.future;
      },
      askUser: (q) {
        if (!current()) return Future.value(null);
        final c = Completer<String?>();
        _answer = c;
        _question = q;
        _changed();
        return c.future;
      },
      onUpdate: (steps) {
        log.steps(steps);
        if (!current()) return;
        turn.steps = List.of(steps);
        _changed();
      },
    );
    _engine = engine;
    final outcome = await engine.run(turn.request, history: history, current: _outfit);
    log.ended(outcome);
    turn.steps = List.of(outcome.steps);
    turn.outcome = outcome;
    // 대화 내역 — 대화 전체를 같은 id로 갈아 끼운다(멈춘 대화도 남긴다).
    final record = AskRecord(id: conversationId, turns: [
      for (final t in (current() ? _turns : [turn]))
        if (t.outcome != null)
          AskRecordTurn.fromOutcome(t.request, t.outcome!, askCombo(t.outcome!), t.createdAt,
              fittingImageUrl: askFittingOf(t.outcome!.steps)?.url,
              fittingCacheKey: askFittingOf(t.outcome!.steps)?.cacheKey),
    ]);
    unawaited(_save(uid, record));
    if (!current()) return;
    _engine = null;
    if (outcome.outfit != null) _outfit = outcome.outfit;
    _confirmArgs = null;
    _question = null;
    _stopping = false;
    _seen = _viewers > 0;
    _changed();
  }

  Future<void> _save(String uid, AskRecord record) async {
    _history = [record, for (final r in _history ?? const <AskRecord>[]) if (r.id != record.id) r]
        .take(askHistoryMax)
        .toList();
    _changed();
    try {
      await _store(uid).save(record);
    } catch (e) {
      debugPrint('[ASK] 대화 내역 저장 실패(무시): $e');
    }
  }

  // 대화 내역 한 건 삭제 / 모두 삭제(v2 §2-G — 화면이 먼저 묻는다).
  Future<void> deleteRecord(String id) async {
    final uid = _uid();
    _history = [for (final r in _history ?? const <AskRecord>[]) if (r.id != id) r];
    _changed();
    if (uid == null) return;
    try {
      await _store(uid).delete(id);
    } catch (e) {
      debugPrint('[ASK] 대화 내역 삭제 실패(무시): $e');
    }
  }

  Future<void> clearHistory() async {
    final uid = _uid();
    _history = const [];
    _changed();
    if (uid == null) return;
    try {
      await _store(uid).clear();
    } catch (e) {
      debugPrint('[ASK] 대화 내역 모두 삭제 실패(무시): $e');
    }
  }

  void answerConfirm(bool ok) {
    final c = _confirm;
    _confirm = null;
    _confirmArgs = null;
    _changed();
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void answerQuestion(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final c = _answer;
    _answer = null;
    _question = null;
    _changed();
    if (c != null && !c.isCompleted) c.complete(t);
  }

  // [멈추기] — 엔진을 멈추고 기다리던 확인은 "등록 안 함", 질문은 "답 없음"으로 닫는다.
  void stop() {
    if (!isRunning) return;
    _engine?.cancel();
    _stopping = true;
    final c = _confirm;
    final a = _answer;
    _confirm = null;
    _answer = null;
    _confirmArgs = null;
    _question = null;
    _changed();
    if (c != null && !c.isCompleted) c.complete(false);
    if (a != null && !a.isCompleted) a.complete(null);
  }

  // [새 대화] — 진행 중이면 멈추고(기록은 멈춤으로 남는다) 처음부터. 대화 사이의 기억은 없다.
  void clear() {
    stop();
    _runId++;
    _engine = null;
    _turns.clear();
    _tools = null;
    _conversationId = null;
    _outfit = null;
    _stopping = false;
    _seen = true;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _engine?.cancel();
    if (_confirm != null && !_confirm!.isCompleted) _confirm!.complete(false);
    if (_answer != null && !_answer!.isCompleted) _answer!.complete(null);
    super.dispose();
  }
}
