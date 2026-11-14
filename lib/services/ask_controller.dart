// AI에게 부탁하기 — 앱 수준 진행 컨트롤러(docs/task_agent_ask_v1.md §10 B). 가상 피팅의
// FittingJobController처럼 AppShell이 갖고 있어서, 전용 화면을 닫아도 부탁은 계속 진행된다.
// 화면과 떠 있는 버튼은 이 컨트롤러를 구독만 한다.
//  · 한 번에 부탁 하나만 진행한다(start는 진행 중이면 false).
//  · add_plan은 확인 카드에서 [등록]을 눌러야만 실행된다 — 화면이 닫혀 있으면 확인을 기다린다.
//  · [멈추기]만 부탁을 멈춘다(뒤로 나가기는 멈추지 않는다).
//  · 끝나면(답·멈춤·실패) 지난 부탁 기록과 활동 내역 끝 줄을 남긴다.
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

// 답 카드의 사진 — 마지막으로 나온 조합(등록·미리 보기, 하루짜리 일정 확인의 준비된 추천).
List<WardrobeItem> askCombo(List<AskStep> steps) {
  for (final s in steps.reversed) {
    if (s.items.isEmpty) continue;
    if (s.action == 'add_plan' || s.action == 'preview_outfit') return s.items;
    if (s.action == 'get_calendar' && s.args['from'] == s.args['to']) return s.items;
  }
  return const [];
}

class AskController extends ChangeNotifier {
  final String? Function() _uid;
  // 테스트용 주입 — 없으면 로그인한 사용자의 Firestore 자료·GeminiService·활동 내역·기록 저장소.
  final AskTools Function(String uid)? toolsFor;
  final AskModelCall? callModel;
  final void Function(AgentLogEntry entry)? logSink;
  final AskHistoryStore Function(String uid)? historyFor;
  final DateTime Function() _now;

  AskController({
    String? Function()? currentUid,
    this.toolsFor,
    this.callModel,
    this.logSink,
    this.historyFor,
    DateTime Function()? now,
  })  : _uid = currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _now = now ?? DateTime.now;

  String? _request;
  List<AskStep> _steps = const [];
  AskOutcome? _outcome;
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

  String? get request => _request;
  List<AskStep> get steps => _steps;
  AskOutcome? get outcome => _outcome;
  (DateTime, String)? get confirmArgs => _confirmArgs;
  String? get question => _question;
  bool get isRunning => _request != null && _outcome == null;
  bool get isStopping => _stopping;
  bool get userTurn => isRunning && (_confirmArgs != null || _question != null);
  List<AskRecord>? get history => _history;

  AskButtonState get buttonState {
    if (userTurn) return AskButtonState.attention;
    if (isRunning) return AskButtonState.running;
    if (_outcome != null && !_seen) return AskButtonState.attention;
    return AskButtonState.idle;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // 전용 화면이 열려 있는 동안 — 그 사이에 나온 답은 본 것으로 친다.
  void attach() {
    _viewers++;
    if (_outcome != null) _seen = true;
    _changed();
  }

  void detach() {
    if (_viewers > 0) _viewers--;
  }

  Future<void> loadHistory() async {
    final uid = _uid();
    if (uid == null) return;
    try {
      _history = await (historyFor?.call(uid) ?? FirestoreAskHistoryStore(uid)).recent();
    } catch (e) {
      debugPrint('[ASK] 지난 부탁을 불러오지 못함(무시): $e');
      _history ??= const [];
    }
    _changed();
  }

  // 새 부탁 — 진행 중이면 시작하지 않고 false(화면이 먼저 멈출지 묻는다).
  bool start(String text) {
    final request = text.trim();
    if (request.isEmpty || isRunning) return false;
    final uid = _uid();
    final id = ++_runId;
    _request = request;
    _steps = const [];
    _outcome = null;
    _confirmArgs = null;
    _question = null;
    _stopping = false;
    _seen = false;
    _changed();
    if (uid == null) {
      _outcome = const AskOutcome(AskEnd.error, '로그인한 뒤에 부탁할 수 있어요', [], 0);
      _seen = _viewers > 0;
      _changed();
      return true;
    }
    unawaited(_run(uid, request, id));
    return true;
  }

  Future<void> _run(String uid, String request, int id) async {
    bool current() => id == _runId && !_disposed;
    final log = AskActivityLog(
      write: logSink ?? (e) => unawaited(FirestoreService.addAgentLogSilently(uid, e)),
      relatedId: 'ask_${_now().millisecondsSinceEpoch}',
    );
    log.started(request);
    final engine = AskEngine(
      tools: toolsFor?.call(uid) ?? AskTools(FirestoreAskDataSource(uid)),
      callModel: callModel ??
          (prompt) async {
            final r = await GeminiService.callAgentStep(prompt);
            return AskModelReply(r.json, r.model);
          },
      buildPrompt: buildAskPrompt,
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
        _steps = List.of(steps);
        _changed();
      },
    );
    _engine = engine;
    final outcome = await engine.run(request);
    log.ended(outcome);
    final record = AskRecord.fromOutcome(request, outcome, askCombo(outcome.steps), _now());
    unawaited(_save(uid, record));
    if (!current()) return;
    _engine = null;
    _outcome = outcome;
    _steps = List.of(outcome.steps);
    _confirmArgs = null;
    _question = null;
    _stopping = false;
    _seen = _viewers > 0;
    _changed();
  }

  Future<void> _save(String uid, AskRecord record) async {
    _history = [record, ...?_history].take(askHistoryMax).toList();
    _changed();
    try {
      await (historyFor?.call(uid) ?? FirestoreAskHistoryStore(uid)).add(record);
    } catch (e) {
      debugPrint('[ASK] 지난 부탁 저장 실패(무시): $e');
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

  // 첫 상태로 — 진행 중이면 멈추고(기록은 멈춤으로 남는다) 화면은 바로 비운다.
  void clear() {
    stop();
    _runId++;
    _engine = null;
    _request = null;
    _steps = const [];
    _outcome = null;
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
