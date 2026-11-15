import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/wardrobe_item.dart';
import '../services/ask_controller.dart';
import '../services/ask_dates.dart';
import '../services/ask_engine.dart';
import '../services/ask_finish.dart';
import '../services/ask_history.dart';
import '../services/ask_registry.dart';
import '../services/voice_input.dart';
import '../widgets/agent_mascot.dart';
import '../widgets/full_screen_image_viewer.dart';
import '../widgets/signed_network_image.dart';

// AI에게 부탁하기 전용 화면(docs/task_agent_ask_v1.md §2-5·§10). 진행 상태는 앱 수준의
// AskController가 갖고, 이 화면은 그것을 보여 주기만 한다 — 닫아도 부탁은 이어지고, 떠 있는 버튼을
// 누르면 같은 대화가 다시 열린다. 첫 상태는 인사말 + 예시 + 입력 + 대화 내역.
class AskScreen extends StatefulWidget {
  final AskController controller;
  final ValueChanged<List<WardrobeItem>>? onOpenFittingRoom;
  final ValueChanged<int>? onNavigate;
  // 전신 사진 바꾸기(채팅 안) — 등록된 전신 사진 목록과, 하나를 고르면 그것을 선택 상태로.
  final Future<List<WardrobeItem>> Function()? loadFullBodies;
  final ValueChanged<WardrobeItem>? onPickFullBody;
  // 음성 입력 — 없으면 기기의 음성 인식(speech_to_text). 테스트는 가짜를 넣는다.
  final VoiceEngine? voiceEngine;
  const AskScreen(
      {super.key,
      required this.controller,
      this.onOpenFittingRoom,
      this.onNavigate,
      this.loadFullBodies,
      this.onPickFullBody,
      this.voiceEngine});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

const _calendarTab = 3;
const _wardrobeTab = 1;

// 전신 사진(화면에만 — 모델에게 가는 글에는 없다).
const askAutoPickedNote = '전신 사진은 자동으로 골랐어요';
const askNoFullBodyTitle = '등록된 전신 사진이 없어요';
const askOtherFullBodyLabel = '다른 전신 사진으로';
const askRetryWithFullBody = '이 전신 사진으로 다시 입혀 줘';
// try_on이 전신 사진이 없어 실패했을 때의 관찰 글 앞부분(ask_registry.dart의 문장 그대로).
const _noFullBodyObservation = '전신 사진이 선택돼 있지 않아';

bool askNoFullBody(List<AskStep> steps) => steps.any((s) =>
    s.action == 'try_on' && s.status == AskStepStatus.failed && (s.observation ?? '').startsWith(_noFullBodyObservation));

// 입력창 안내 — 첫 화면은 고정, 이어서 말하기는 음성 입력을 쓸 수 있는지에 따라.
const askHomeHint = '무엇이든 부탁해 보세요';
const askContinueHintVoice = '글로 쓰거나 마이크를 눌러 말해 보세요';
const askContinueHintText = '글로 부탁해 보세요';

// 첫 상태의 예시(v2 §2-G).
const askExamples = [
  '금요일 저녁 모임 옷 골라서 입혀 봐줘',
  '내일 뭐 입지?',
  '내 옷장에 부족한 옷 알려줘',
  '요즘 안 입은 옷으로 코디해줘',
];

// 도구의 화면 이름은 도구 등록부에서 — 읽지 못한 출력만 여기서 이름을 붙인다.
String _toolName(String action) => action == '-' ? '답 읽기 실패' : askToolDisplayName(action) ?? action;

const _toolIcons = {
  'get_calendar': Icons.event_outlined,
  'get_weather': Icons.wb_cloudy_outlined,
  'search_wardrobe': Icons.checkroom_outlined,
  'preview_outfit': Icons.style_outlined,
  'add_plan': Icons.event_available_outlined,
  'ask_user': Icons.help_outline,
};

String _timeLabel(DateTime t) =>
    '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const _endLabels = {
  'finished': '답',
  'cancelled': '멈춤',
  'maxSteps': '여기까지 확인',
  'invalidOutput': '실패',
  'rateLimited': '실패',
  'timeout': '시간 초과',
  'error': '실패',
};

class _AskScreenState extends State<AskScreen> {
  final _input = TextEditingController();
  final _answerCtl = TextEditingController();

  AskController get _c => widget.controller;
  late final VoiceInput _voice = VoiceInput(widget.voiceEngine ?? SpeechToTextEngine.instance);

  List<WardrobeItem> _fullBodies = const [];
  bool _bodyPickerOpen = false;
  AskTurn? _bodyPickedFor; // "다른 전신 사진으로"로 이미 다시 입혀 달라고 보낸 턴(한 번만)

  Future<void> _loadFullBodies() async {
    final load = widget.loadFullBodies;
    if (load == null) return;
    final items = await load();
    if (mounted) setState(() => _fullBodies = items);
  }

  void _pickFullBody(AskTurn t, WardrobeItem item) {
    if (_bodyPickedFor == t || !_c.canContinue || _c.isRunning) return;
    setState(() {
      _bodyPickedFor = t;
      _bodyPickerOpen = false;
    });
    widget.onPickFullBody?.call(item);
    _c.start(askRetryWithFullBody);
  }

  @override
  void initState() {
    super.initState();
    _loadFullBodies();
    _c.addListener(_stopVoiceIfHidden);
    _voice.prepare();
    // 첫 프레임 뒤에 — attach가 알리는 변경이 떠 있는 버튼의 빌드 중에 닿지 않게.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attached = true;
      _c.attach();
      if (_c.history == null) _c.loadHistory();
    });
  }

  bool _attached = false;

  @override
  void dispose() {
    _c.removeListener(_stopVoiceIfHidden);
    _voice.dispose();
    if (_attached) _c.detach();
    _input.dispose();
    _answerCtl.dispose();
    super.dispose();
  }

  // 듣고 있는 입력창이 화면에서 빠지면(턴 진행 중, 질문이 끝남) 듣기를 멈춘다.
  void _stopVoiceIfHidden() {
    final t = _voice.target;
    if (t == null) return;
    if ((t == _input && !_c.canContinue) || (t == _answerCtl && _c.question == null)) _voice.stop();
  }

  Future<void> _toggleVoice(TextEditingController target) async {
    final r = await _voice.toggle(target);
    if (r == VoiceToggle.denied && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text(voiceDeniedMessage), behavior: SnackBarBehavior.floating));
    }
  }

  Widget _micButton(TextEditingController target, Key key) {
    final on = _voice.listening && _voice.target == target;
    return IconButton(
      key: key,
      tooltip: on ? '듣기 멈추기' : '말로 입력',
      isSelected: on,
      style: on ? IconButton.styleFrom(backgroundColor: Colors.red.shade50) : null,
      icon: Icon(on ? Icons.mic : Icons.mic_none, color: on ? Colors.red : null),
      onPressed: () => _toggleVoice(target),
    );
  }

  // 사용자 말 보내기 — 대화가 있으면 다음 턴, 없으면 새 대화.
  void _submit(String text) {
    if (text.trim().isEmpty || !_c.canContinue) return;
    _voice.stop();
    _input.clear();
    _c.start(text);
  }

  // [새 대화] — 진행 중이면 멈출지 묻고 처음부터.
  Future<void> _newConversation() async {
    if (_c.isRunning) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('진행 중인 부탁을 멈추고 새 대화를 시작할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('계속 진행')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('멈추기')),
          ],
        ),
      );
      if (stop != true || !mounted) return;
    }
    _c.clear();
  }

  void _openRecord(AskRecord r) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AskRecordScreen(record: r)));
  }

  // 대화 내역 지우기 — 지우기 전에 한 번 묻는다(v2 §2-G).
  Future<bool> _confirmDelete(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('지우기')),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _deleteRecord(AskRecord r) async {
    if (await _confirmDelete('이 대화를 대화 내역에서 지울까요?')) await _c.deleteRecord(r.id);
  }

  Future<void> _clearHistory() async {
    if (await _confirmDelete('대화 내역을 모두 지울까요?')) await _c.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_c, _voice]),
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
          title: const Text('AI에게 부탁하기', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          actions: [
            if (_c.hasConversation)
              TextButton.icon(
                onPressed: _newConversation,
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                label: const Text('새 대화'),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _c.hasConversation ? _conversation() : _home(),
        ),
      ),
    );
  }

  // 첫 상태 — 인사말, 예시, 입력, 지난 대화.
  Widget _home() {
    final history = _c.history;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AgentMascot(size: 56),
          SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('무엇을 도와드릴까요?\n옷장·일정·날씨를 확인해 코디를 도와드려요.',
                  style: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in askExamples)
            ActionChip(
              label: Text(e, style: const TextStyle(fontSize: 12.5)),
              backgroundColor: AppColors.blueVeryPale,
              side: const BorderSide(color: AppColors.border),
              onPressed: () => _submit(e),
            ),
        ]),
        const SizedBox(height: 12),
        _inputField(),
        const SizedBox(height: 28),
        Row(children: [
          const Expanded(
            child: Text('대화 내역',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          ),
          if (history != null && history.isNotEmpty)
            TextButton(onPressed: _clearHistory, child: const Text('모두 삭제')),
        ]),
        const SizedBox(height: 4),
        if (history == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('불러오는 중', style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
          )
        else if (history.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('아직 없어요', style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
          )
        else
          for (final r in history)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.request, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                  '${_timeLabel(r.createdAt)} · ${r.turns.length > 1 ? '${r.turns.length}턴 · ' : ''}${_endLabels[r.end] ?? r.end}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              trailing: IconButton(
                tooltip: '삭제',
                icon: const Icon(Icons.delete_outline, color: AppColors.textMuted),
                onPressed: () => _deleteRecord(r),
              ),
              onTap: () => _openRecord(r),
            ),
      ],
    );
  }

  Widget _inputField() => TextField(
        controller: _input,
        textInputAction: TextInputAction.send,
        onSubmitted: _submit,
        decoration: InputDecoration(
          hintText: !_c.hasConversation
              ? askHomeHint
              : (_voice.available ? askContinueHintVoice : askContinueHintText),
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_voice.available) _micButton(_input, const Key('ask-mic')),
            IconButton(tooltip: '보내기', icon: const Icon(Icons.send), onPressed: () => _submit(_input.text)),
          ]),
        ),
      );

  // 대화 — 턴이 위에서 아래로 쌓이고, 입력창은 아래에 남는다.
  Widget _conversation() {
    final turns = _c.turns;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              for (var i = 0; i < turns.length; i++) ..._turn(turns[i], last: i == turns.length - 1, first: i == 0),
              if (_c.isRunning) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: _c.isStopping ? null : _c.stop,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('멈추기'),
                  ),
                ]),
              ],
              if (_c.turnLimitReached)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('대화가 길어졌어요. 이어서 부탁하려면 [새 대화]를 시작해 주세요.',
                      style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
                ),
            ],
          ),
        ),
        if (_c.canContinue)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _inputField(),
          ),
      ],
    );
  }

  List<Widget> _turn(AskTurn t, {required bool last, required bool first}) {
    // 화면에는 사용자용 단계만 — finish와 형식 오류(숨김)는 뺀다.
    // finish는 돌려보낸 것만("답을 다듬고 있어요" 한 줄) 보인다.
    final visible = [
      for (final s in t.steps)
        if (!s.hidden && (s.action != 'finish' || s.display == askDisplayRevising)) s,
    ];
    final running = last && _c.isRunning;
    final waiting = running &&
        !_c.userTurn &&
        !_c.isStopping &&
        (t.steps.isEmpty || t.steps.last.status != AskStepStatus.running);
    return [
      if (!first) const Divider(height: 32, color: AppColors.divider),
      _RequestHeader(request: t.request, compact: !first),
      const SizedBox(height: 16),
      // 진행 표시는 실제로 진행 중일 때만 — 사용자 차례(확인·질문), 멈추는 중, 끝난 뒤에는 멈춘다
      // (멈춘 요청의 마지막 단계는 실행 중 상태로 남을 수 있다).
      for (final s in visible) ...[
        if (s.action == 'finish')
          const _RevisingRow()
        else
          AskStepTile(step: s, showProgress: running && !_c.userTurn && !_c.isStopping),
        if (s.action == 'try_on' && s.fitting?.autoPicked == true) const _AutoPickedNote(),
        if (s.fitting != null) AskFittingView(bytes: s.fitting!.bytes, url: s.fitting!.url, cacheKey: s.fitting!.cacheKey),
        if (s.fitting != null && _fullBodies.length >= 2) ..._otherFullBody(t, last: last),
      ],
      if (waiting) const _ThinkingRow(text: '다음 단계를 고르는 중'),
      if (running && _c.isStopping) const _ThinkingRow(text: '멈추는 중'),
      if (running && _c.confirmArgs != null) _confirmCard(_c.confirmArgs!),
      if (running && _c.question != null) _questionCard(_c.question!),
      if (t.outcome != null) _answerCard(t, last: last),
    ];
  }

  Widget _confirmCard((DateTime, String) args) {
    final (date, tpo) = args;
    return _AskCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${askDateCardLabel(date, _c.today)} [$tpo] 일정을 등록할까요?',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('등록하면 캘린더에 예정으로 들어가고, 예보가 있으면 코디도 준비해요.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: () => _c.answerConfirm(false), child: const Text('취소')),
            FilledButton(onPressed: () => _c.answerConfirm(true), child: const Text('등록하기')),
          ]),
        ],
      ),
    );
  }

  Widget _questionCard(String question) {
    void send() {
      final t = _answerCtl.text;
      if (t.trim().isEmpty) return;
      _voice.stop();
      _answerCtl.clear();
      _c.answerQuestion(t);
    }

    return _AskCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          TextField(
            controller: _answerCtl,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => send(),
            decoration: InputDecoration(
              hintText: '답을 적어 주세요',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _voice.available ? _micButton(_answerCtl, const Key('ask-answer-mic')) : null,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: send, child: const Text('보내기')),
        ],
      ),
    );
  }

  // 입혀 본 결과 아래 "다른 전신 사진으로" — 마지막 턴에서만 동작하고, 고르면 한 번만 보낸다.
  List<Widget> _otherFullBody(AskTurn t, {required bool last}) {
    final active = last && !_c.isRunning && _c.canContinue && _bodyPickedFor != t;
    return [
      Padding(
        padding: const EdgeInsets.only(left: 24, bottom: 8),
        child: OutlinedButton.icon(
          key: const Key('ask-other-full-body'),
          onPressed: active ? () => setState(() => _bodyPickerOpen = !_bodyPickerOpen) : null,
          icon: const Icon(Icons.accessibility_new, size: 18),
          label: const Text(askOtherFullBodyLabel),
        ),
      ),
      if (active && _bodyPickerOpen)
        Padding(
          padding: const EdgeInsets.only(left: 24, bottom: 14),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in _fullBodies)
              GestureDetector(
                key: Key('ask-full-body-${b.id}'),
                onTap: () => _pickFullBody(t, b),
                child: AskItemThumb(id: b.id, imageUrl: b.imageUrl, cutoutImageUrl: b.cutoutImageUrl),
              ),
          ]),
        ),
    ];
  }

  Widget _noFullBodyCard() => _AskCard(
        child: Column(
          key: const Key('ask-no-full-body'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(askNoFullBodyTitle,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            const Text('옷장에 전신 사진을 올리면 입혀 볼 수 있어요.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: widget.onNavigate == null
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      widget.onNavigate!(_wardrobeTab);
                    },
              icon: const Icon(Icons.checkroom_outlined, size: 18),
              label: const Text('옷장으로'),
            ),
          ],
        ),
      );

  Widget _answerCard(AskTurn t, {required bool last}) {
    final o = t.outcome!;
    final combo = o.end == AskEnd.finished ? askCombo(o) : const <WardrobeItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (askNoFullBody(t.steps)) _noFullBodyCard(),
        AskAnswerBox(
          answer: o.answer,
          stopped: o.end != AskEnd.finished,
          thumbs: [
            for (final i in combo)
              AskItemThumb(id: i.id, imageUrl: i.imageUrl, cutoutImageUrl: i.cutoutImageUrl),
          ],
          lineItems: {for (final e in _c.askLineItems(o.answer).entries) e.key: AskRecordItem.of(e.value)},
          recommendedIds: {for (final i in combo) i.id},
        ),
        if (last)
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
          ]),
      ],
    );
  }
}

// 대화 내역 다시 보기(읽기 전용) — 모든 턴.
class AskRecordScreen extends StatelessWidget {
  final AskRecord record;
  const AskRecordScreen({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: Text('대화 내역 · ${_timeLabel(record.createdAt)}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            for (var i = 0; i < record.turns.length; i++) ...[
              if (i > 0) const Divider(height: 32, color: AppColors.divider),
              _RequestHeader(request: record.turns[i].request, compact: i > 0),
              const SizedBox(height: 16),
              for (final s in record.turns[i].steps)
                AskStepTile(
                  step: AskStep(
                      thought: s.thought,
                      action: s.action,
                      args: const {},
                      observation: s.summary.isEmpty ? null : s.summary,
                      status: s.action == '-' ? AskStepStatus.failed : AskStepStatus.done),
                ),
              if (record.turns[i].fittingCacheKey != null || record.turns[i].fittingImageUrl != null)
                AskFittingView(url: record.turns[i].fittingImageUrl, cacheKey: record.turns[i].fittingCacheKey),
              AskAnswerBox(
                answer: record.turns[i].answer,
                stopped: !record.turns[i].finished,
                thumbs: [
                  for (final it in record.turns[i].items)
                    AskItemThumb(id: it.id, imageUrl: it.imageUrl, cutoutImageUrl: it.cutoutImageUrl),
                ],
                lineItems: record.turns[i].lineItems,
                recommendedIds: {for (final it in record.turns[i].items) it.id},
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RequestHeader extends StatelessWidget {
  final String request;
  final bool compact; // 이어지는 턴의 사용자 말 — 마스코트 없이 작게
  const _RequestHeader({required this.request, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(12)),
          child: Text(request,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AgentMascot(size: 56),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(request,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ),
        ),
      ],
    );
  }
}

class _AskCard extends StatelessWidget {
  final Widget child;
  final Color color;
  const _AskCard({required this.child, this.color = AppColors.blueVeryPale});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );
}

// 답의 "구매 제안:" 줄(앞에 "- "가 붙은 것 포함)을 본문에서 떼어 낸다 — 화면에 그릴 때만.
// 저장되는 대화 내역, 다음 턴에 모델에게 주는 글, 프롬프트는 "구매 제안:" 그대로다.
const askExtrasTitle = '옷장에 더하면 좋은 옷';
const askExtrasNote = '지금 옷장에는 없는 옷이에요';

({String body, List<String> extras}) askSplitExtras(String answer) {
  final body = <String>[];
  final extras = <String>[];
  for (final line in answer.split('\n')) {
    final t = line.trim();
    final bare = t.startsWith('- ') ? t.substring(2).trimLeft() : t;
    if (bare.startsWith(askBuyLabel)) {
      final item = bare.substring(askBuyLabel.length).trim();
      if (item.isNotEmpty) extras.add(item);
    } else {
      body.add(line);
    }
  }
  return (body: body.join('\n').trim(), extras: extras);
}

// 답 카드. 번호를 붙인 조합 줄("- 1. …(#n) + …")이 둘 이상이면 줄마다 그 줄의 옷 사진을 작게 한 줄로
// 그리고(lineItems — 이 대화의 번호표로 찾은 옷, 없는 번호는 건너뛴다), 고른 조합(recommendedIds)과
// 같은 줄에는 "추천"을 붙인다. 이때 맨 아래 사진 한 줄(thumbs)은 겹치므로 그리지 않는다.
class AskAnswerBox extends StatelessWidget {
  final String answer;
  final bool stopped;
  final List<Widget> thumbs;
  final Map<int, AskRecordItem> lineItems;
  final Set<String> recommendedIds;
  const AskAnswerBox(
      {super.key,
      required this.answer,
      required this.stopped,
      this.thumbs = const [],
      this.lineItems = const {},
      this.recommendedIds = const {}});

  static const _textStyle = TextStyle(fontSize: 15, height: 1.45, color: AppColors.textPrimary);

  List<Widget> _perLine(String body, List<({int line, List<int> numbers})> combos) {
    final byLine = {for (final c in combos) c.line: c.numbers};
    final lines = body.split('\n');
    final out = <Widget>[];
    final plain = <String>[];
    void flush() {
      if (plain.isEmpty) return;
      out.add(Text(plain.join('\n'), style: _textStyle));
      plain.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final numbers = byLine[i];
      if (numbers == null) {
        plain.add(lines[i]);
        continue;
      }
      flush();
      out.add(Text(lines[i], style: _textStyle));
      final seen = <String>{};
      final items = [
        for (final n in numbers)
          if (lineItems[n] case final it? when seen.add(it.id)) it,
      ];
      if (items.isEmpty) continue;
      final recommended = recommendedIds.isNotEmpty &&
          seen.length == recommendedIds.length &&
          seen.containsAll(recommendedIds);
      out.add(Padding(
        key: Key('ask-line-thumbs-$i'),
        padding: const EdgeInsets.only(top: 4, bottom: 8, left: 12),
        child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final it in items)
            AskItemThumb(id: it.id, imageUrl: it.imageUrl, cutoutImageUrl: it.cutoutImageUrl, size: 44),
          if (recommended)
            Container(
              key: const Key('ask-line-recommended'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppColors.blue, borderRadius: BorderRadius.circular(10)),
              child: const Text('추천', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
        ]),
      ));
    }
    flush();
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final (:body, :extras) = askSplitExtras(answer);
    final combos = askNumberedComboLines(body);
    final perLine = combos.isNotEmpty;
    return _AskCard(
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
          if (perLine) ..._perLine(body, combos) else Text(body, style: _textStyle),
          if (thumbs.isNotEmpty && !perLine) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: thumbs),
          ],
          if (extras.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ExtrasBox(items: extras),
          ],
        ],
      ),
    );
  }
}

// 옷장에 없지만 가진 옷과 어울리는 옷 종류 — 답 아래 한 묶음.
class _ExtrasBox extends StatelessWidget {
  final List<String> items;
  const _ExtrasBox({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('ask-extras'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(askExtrasTitle,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 2),
          const Text(askExtrasNote, style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.add_circle_outline, size: 16, color: AppColors.blue),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(item, style: const TextStyle(fontSize: 14, height: 1.4, color: AppColors.textPrimary)),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

class AskStepTile extends StatelessWidget {
  final AskStep step;
  final bool showProgress;
  const AskStepTile({super.key, required this.step, this.showProgress = false});

  @override
  Widget build(BuildContext context) {
    final failed = step.status == AskStepStatus.failed;
    final running = step.status == AskStepStatus.running && showProgress;
    // 화면용 한 줄(v2). 그 이전 기록(v1)은 관찰의 첫 줄을 그대로 쓴다.
    final obs = step.display ?? step.observation?.split('\n').first;
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
              child: Text(_toolName(step.action),
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
              child: Text(obs,
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

// try_on이 기본 전신 사진으로 입혔을 때 단계 아래 한 줄(화면에만).
class _AutoPickedNote extends StatelessWidget {
  const _AutoPickedNote();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(left: 24, bottom: 8),
        child: Text(askAutoPickedNote, style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
      );
}

// 엔진이 finish를 한 번 돌려보낸 단계 — 모델의 생각 문장 없이 한 줄만.
class _RevisingRow extends StatelessWidget {
  const _RevisingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 14),
      child: Row(children: [
        Icon(Icons.edit_note, size: 18, color: AppColors.textMuted),
        SizedBox(width: 6),
        Flexible(child: Text(askDisplayRevising, style: TextStyle(fontSize: 13, color: AppColors.textMuted))),
      ]),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  final String text;
  const _ThinkingRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Flexible(child: Text(text, style: const TextStyle(fontSize: 13, color: AppColors.textMuted))),
      ]),
    );
  }
}

class AskItemThumb extends StatelessWidget {
  final String id;
  final String imageUrl;
  final String? cutoutImageUrl;
  final double size;
  const AskItemThumb({super.key, required this.id, required this.imageUrl, this.cutoutImageUrl, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: SignedNetworkImage(
        collection: 'wardrobe',
        id: id,
        urlIndex: cutoutImageUrl != null ? 1 : 0,
        fallbackUrl: cutoutImageUrl ?? imageUrl,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => const Icon(Icons.image_not_supported_outlined, color: AppColors.textDisabled),
      ),
    );
  }
}

// 가상 피팅 결과 사진(v2 §2-E) — 대화 안에 보여 주고, 누르면 크게 본다. 새로 만든 것은 bytes,
// 캐시·기록에서 온 것은 서명 URL(fitting_cache)로 그린다.
class AskFittingView extends StatelessWidget {
  final Uint8List? bytes;
  final String? url;
  final String? cacheKey;
  const AskFittingView({super.key, this.bytes, this.url, this.cacheKey});

  @override
  Widget build(BuildContext context) {
    final Widget image = bytes != null
        ? Image.memory(bytes!, fit: BoxFit.cover)
        : SignedNetworkImage(
            collection: 'fitting_cache',
            id: cacheKey ?? '',
            fallbackUrl: url ?? '',
            fit: BoxFit.cover,
            placeholder: (_, __) => const ColoredBox(color: AppColors.background),
            errorWidget: (_, __, ___) =>
                const Center(child: Icon(Icons.image_not_supported_outlined, color: AppColors.textDisabled)),
          );
    return Padding(
      padding: const EdgeInsets.only(left: 24, bottom: 14),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FullScreenImageViewer(
            imageBytes: bytes,
            imageUrl: url,
            label: '입혀 본 모습',
            signedCollection: bytes == null && cacheKey != null ? 'fitting_cache' : null,
            signedId: bytes == null ? cacheKey : null,
          ),
        )),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 160, height: 220, child: image),
        ),
      ),
    );
  }
}
