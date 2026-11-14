import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/agent_log_entry.dart';
import '../models/wardrobe_item.dart';
import '../services/ask_activity_log.dart';
import '../services/ask_data_source.dart';
import '../services/ask_engine.dart';
import '../services/ask_prompt.dart';
import '../services/ask_tools.dart';
import '../services/firestore_service.dart';
import '../services/gemini_service.dart';
import '../widgets/agent_mascot.dart';
import '../widgets/signed_network_image.dart';

// AI에게 부탁하기 전용 화면(docs/task_agent_ask_v1.md §2-5). 열리면 바로 요청을 시작하고,
// 단계마다 도구 이름·생각·결과를 보여 준다. 일정 등록은 확인 카드에서 사용자가 누른 뒤에만
// 실행된다. 뒤로 나가면 진행 중인 요청을 멈춘다(확인 대기 중이면 등록하지 않음).
class AskScreen extends StatefulWidget {
  final String request;
  final ValueChanged<List<WardrobeItem>>? onOpenFittingRoom;
  final ValueChanged<int>? onNavigate;
  // 테스트용 주입 — 없으면 로그인한 사용자의 Firestore 자료와 GeminiService.callAgentStep을 쓴다.
  final AskTools? tools;
  final AskModelCall? callModel;
  final void Function(AgentLogEntry entry)? logSink;
  const AskScreen(
      {super.key,
      required this.request,
      this.onOpenFittingRoom,
      this.onNavigate,
      this.tools,
      this.callModel,
      this.logSink});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

const _calendarTab = 3;

const _toolNames = {
  'get_calendar': '일정 확인',
  'get_weather': '예보 확인',
  'search_wardrobe': '옷장 조회',
  'preview_outfit': '코디 미리 보기',
  'add_plan': '일정 등록',
  'ask_user': '질문',
  '-': '답 읽기 실패',
};

const _toolIcons = {
  'get_calendar': Icons.event_outlined,
  'get_weather': Icons.wb_cloudy_outlined,
  'search_wardrobe': Icons.checkroom_outlined,
  'preview_outfit': Icons.style_outlined,
  'add_plan': Icons.event_available_outlined,
  'ask_user': Icons.help_outline,
};

class _AskScreenState extends State<AskScreen> {
  late String _request;
  AskEngine? _engine;
  int _runId = 0;
  List<AskStep> _steps = const [];
  AskOutcome? _outcome;

  Completer<bool>? _confirm;
  (DateTime, String)? _confirmArgs;
  Completer<String?>? _question;
  String? _questionText;
  final _answerCtl = TextEditingController();

  bool _composing = false;
  final _newCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _start(_request);
  }

  @override
  void dispose() {
    _stop();
    _answerCtl.dispose();
    _newCtl.dispose();
    super.dispose();
  }

  // 진행 중인 요청을 멈춘다 — 먼저 엔진을 멈춘 뒤 대기 중인 확인·질문을 "안 함"으로 닫는다.
  void _stop() {
    _engine?.cancel();
    if (_confirm != null && !_confirm!.isCompleted) _confirm!.complete(false);
    if (_question != null && !_question!.isCompleted) _question!.complete(null);
    _confirm = null;
    _question = null;
  }

  Future<void> _start(String request) async {
    _stop();
    final id = ++_runId;
    setState(() {
      _request = request;
      _steps = const [];
      _outcome = null;
      _confirmArgs = null;
      _questionText = null;
      _composing = false;
    });
    final uid = widget.tools != null ? null : FirebaseAuth.instance.currentUser?.uid;
    if (widget.tools == null && uid == null) {
      setState(() => _outcome = const AskOutcome(AskEnd.error, '로그인한 뒤에 부탁할 수 있어요', [], 0));
      return;
    }
    // 활동 내역 — 한 요청은 같은 relatedDocId로 묶는다.
    final log = AskActivityLog(
      write: widget.logSink ??
          (uid == null ? (_) {} : (e) => unawaited(FirestoreService.addAgentLogSilently(uid, e))),
      relatedId: 'ask_${DateTime.now().millisecondsSinceEpoch}',
    );
    log.started(request);
    final engine = AskEngine(
      tools: widget.tools ?? AskTools(FirestoreAskDataSource(uid!)),
      callModel: widget.callModel ??
          (prompt) async {
            final r = await GeminiService.callAgentStep(prompt);
            return AskModelReply(r.json, r.model);
          },
      buildPrompt: buildAskPrompt,
      confirmPlan: (date, tpo) {
        final c = Completer<bool>();
        if (!mounted || id != _runId) return Future.value(false);
        setState(() {
          _confirm = c;
          _confirmArgs = (date, tpo);
        });
        return c.future;
      },
      askUser: (question) {
        final c = Completer<String?>();
        if (!mounted || id != _runId) return Future.value(null);
        setState(() {
          _question = c;
          _questionText = question;
          _answerCtl.clear();
        });
        return c.future;
      },
      onUpdate: (steps) {
        log.steps(steps);
        if (mounted && id == _runId) setState(() => _steps = List.of(steps));
      },
    );
    _engine = engine;
    final outcome = await engine.run(request);
    log.ended(outcome); // 화면을 떠나 멈춘 요청도 "멈춤"으로 남긴다
    if (!mounted || id != _runId) return;
    setState(() {
      _outcome = outcome;
      _steps = List.of(outcome.steps);
      _confirmArgs = null;
      _questionText = null;
    });
  }

  void _answerConfirm(bool ok) {
    final c = _confirm;
    setState(() {
      _confirm = null;
      _confirmArgs = null;
    });
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _answerQuestion() {
    final text = _answerCtl.text.trim();
    if (text.isEmpty) return;
    final c = _question;
    setState(() {
      _question = null;
      _questionText = null;
    });
    if (c != null && !c.isCompleted) c.complete(text);
  }

  // 답 카드의 사진 — 마지막으로 나온 조합(등록·미리 보기, 하루짜리 일정 확인의 준비된 추천).
  List<WardrobeItem> get _combo {
    for (final s in _steps.reversed) {
      if (s.items.isEmpty) continue;
      if (s.action == 'add_plan' || s.action == 'preview_outfit') return s.items;
      if (s.action == 'get_calendar' && s.args['from'] == s.args['to']) return s.items;
    }
    return const [];
  }

  bool get _waiting =>
      _outcome == null &&
      _confirmArgs == null &&
      _questionText == null &&
      (_steps.isEmpty || _steps.last.status != AskStepStatus.running);

  @override
  Widget build(BuildContext context) {
    final visible = [for (final s in _steps) if (s.action != 'finish') s];
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text('AI에게 부탁하기', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AgentMascot(size: 56),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_request,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // 확인·질문을 기다리는 동안은 진행 표시를 멈춘다(사용자 차례).
            for (final s in visible) _StepTile(step: s, userTurn: _confirmArgs != null || _questionText != null),
            if (_waiting) const _ThinkingRow(),
            if (_confirmArgs != null) _confirmCard(_confirmArgs!),
            if (_questionText != null) _questionCard(_questionText!),
            if (_outcome != null) _answerCard(_outcome!),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child, Color color = AppColors.blueVeryPale}) => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );

  Widget _confirmCard((DateTime, String) args) {
    final (date, tpo) = args;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${askDateLabel(date)} [$tpo] 일정을 등록할까요?',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('등록하면 캘린더에 예정으로 들어가고, 예보가 있으면 코디도 준비해요.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: () => _answerConfirm(false), child: const Text('취소')),
            FilledButton(onPressed: () => _answerConfirm(true), child: const Text('등록하기')),
          ]),
        ],
      ),
    );
  }

  Widget _questionCard(String question) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          TextField(
            controller: _answerCtl,
            autofocus: true,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _answerQuestion(),
            decoration: const InputDecoration(hintText: '답을 적어 주세요', isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _answerQuestion, child: const Text('보내기')),
        ],
      ),
    );
  }

  Widget _answerCard(AskOutcome o) {
    final combo = o.end == AskEnd.finished ? _combo : const <WardrobeItem>[];
    final stopped = o.end != AskEnd.finished;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _card(
          color: stopped ? AppColors.background : AppColors.bluePale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const AgentMascot(size: 24),
                const SizedBox(width: 8),
                Text(stopped ? '여기서 멈췄어요' : '답',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
              ]),
              const SizedBox(height: 8),
              Text(o.answer, style: const TextStyle(fontSize: 15, height: 1.45, color: AppColors.textPrimary)),
              if (combo.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final i in combo) _ItemThumb(item: i)]),
              ],
            ],
          ),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: widget.onNavigate == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    widget.onNavigate!(_calendarTab);
                  },
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            label: const Text('캘린더에서 보기'),
          ),
          if (combo.isNotEmpty && widget.onOpenFittingRoom != null)
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onOpenFittingRoom!(combo);
              },
              icon: const Icon(Icons.checkroom_outlined, size: 18),
              label: const Text('피팅룸에서 입어 보기'),
            ),
          FilledButton.icon(
            onPressed: () => setState(() => _composing = true),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('새로 부탁하기'),
          ),
        ]),
        if (_composing) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _newCtl,
            autofocus: true,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submitNew(),
            decoration: InputDecoration(
              hintText: '무엇을 부탁할까요?',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _submitNew),
            ),
          ),
        ],
      ],
    );
  }

  void _submitNew() {
    final text = _newCtl.text.trim();
    if (text.isEmpty) return;
    _newCtl.clear();
    _start(text);
  }
}

class _StepTile extends StatelessWidget {
  final AskStep step;
  final bool userTurn;
  const _StepTile({required this.step, this.userTurn = false});

  @override
  Widget build(BuildContext context) {
    final failed = step.status == AskStepStatus.failed;
    final running = step.status == AskStepStatus.running && !userTurn;
    final obs = step.observation;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(failed ? Icons.error_outline : _toolIcons[step.action] ?? Icons.smart_toy_outlined,
                size: 18, color: failed ? AppColors.textMuted : AppColors.blue),
            const SizedBox(width: 6),
            Flexible(
              child: Text(_toolNames[step.action] ?? step.action,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: failed ? AppColors.textMuted : AppColors.textPrimary)),
            ),
            if (running) ...[
              const SizedBox(width: 8),
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const AgentMascot(size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(step.thought, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
            ),
          ]),
          if (obs != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(obs.split('\n').first,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 14),
      child: Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 10),
        Flexible(child: Text('다음 단계를 고르는 중', style: TextStyle(fontSize: 13, color: AppColors.textMuted))),
      ]),
    );
  }
}

class _ItemThumb extends StatelessWidget {
  final WardrobeItem item;
  const _ItemThumb({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: SignedNetworkImage(
        collection: 'wardrobe',
        id: item.id,
        urlIndex: item.cutoutImageUrl != null ? 1 : 0,
        fallbackUrl: item.cutoutImageUrl ?? item.imageUrl,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => const Icon(Icons.image_not_supported_outlined, color: AppColors.textDisabled),
      ),
    );
  }
}
