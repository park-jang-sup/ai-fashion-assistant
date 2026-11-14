import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/wardrobe_item.dart';
import '../services/ask_controller.dart';
import '../services/ask_engine.dart';
import '../services/ask_history.dart';
import '../services/ask_registry.dart';
import '../services/ask_tools.dart';
import '../widgets/agent_mascot.dart';
import '../widgets/signed_network_image.dart';

// AI에게 부탁하기 전용 화면(docs/task_agent_ask_v1.md §2-5·§10). 진행 상태는 앱 수준의
// AskController가 갖고, 이 화면은 그것을 보여 주기만 한다 — 닫아도 부탁은 이어지고, 떠 있는 버튼을
// 누르면 같은 대화가 다시 열린다. 첫 상태는 인사말 + 예시 + 입력 + 지난 부탁.
class AskScreen extends StatefulWidget {
  final AskController controller;
  final ValueChanged<List<WardrobeItem>>? onOpenFittingRoom;
  final ValueChanged<int>? onNavigate;
  const AskScreen({super.key, required this.controller, this.onOpenFittingRoom, this.onNavigate});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

const _calendarTab = 3;

const askExamples = [
  '금요일 저녁 모임에 입을 옷 준비해줘',
  '내일 비 오면 뭐 입지?',
  '겨울 아우터 뭐 있는지 보고 가장 추운 날 입을 것 골라줘',
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

  @override
  void initState() {
    super.initState();
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
    if (_attached) _c.detach();
    _input.dispose();
    _answerCtl.dispose();
    super.dispose();
  }

  Future<void> _submit(String text) async {
    if (text.trim().isEmpty) return;
    if (_c.isRunning) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('진행 중인 부탁이 있어요. 멈추고 새로 부탁할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('계속 진행')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('멈추고 새로 부탁')),
          ],
        ),
      );
      if (stop != true || !mounted) return;
    }
    _c.clear();
    _input.clear();
    _c.start(text);
  }

  // [새로 부탁하기] — 진행 중이면 멈출지 묻고 첫 상태로.
  Future<void> _newRequest() async {
    if (_c.isRunning) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('진행 중인 부탁을 멈추고 새로 부탁할까요?'),
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

  @override
  Widget build(BuildContext context) {
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
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => _c.request == null ? _home() : _conversation(),
        ),
      ),
    );
  }

  // 첫 상태 — 인사말, 예시 3개, 입력, 지난 부탁(최근 20건).
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
        TextField(
          controller: _input,
          textInputAction: TextInputAction.send,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: '말로 부탁해 보세요',
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
                tooltip: '부탁하기', icon: const Icon(Icons.send), onPressed: () => _submit(_input.text)),
          ),
        ),
        const SizedBox(height: 28),
        const Text('지난 부탁', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
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
              subtitle: Text('${_timeLabel(r.createdAt)} · ${_endLabels[r.end] ?? r.end}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              trailing: const Icon(Icons.chevron_right, color: AppColors.textDisabled),
              onTap: () => _openRecord(r),
            ),
      ],
    );
  }

  Widget _conversation() {
    final visible = [for (final s in _c.steps) if (s.action != 'finish') s];
    final waiting = _c.isRunning &&
        !_c.userTurn &&
        !_c.isStopping &&
        (_c.steps.isEmpty || _c.steps.last.status != AskStepStatus.running);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _RequestHeader(request: _c.request!),
        const SizedBox(height: 20),
        // 진행 표시는 실제로 진행 중일 때만 — 사용자 차례(확인·질문), 멈추는 중, 끝난 뒤에는 멈춘다
        // (멈춘 요청의 마지막 단계는 실행 중 상태로 남을 수 있다).
        for (final s in visible)
          AskStepTile(step: s, showProgress: _c.isRunning && !_c.userTurn && !_c.isStopping),
        if (waiting) const _ThinkingRow(text: '다음 단계를 고르는 중'),
        if (_c.isStopping) const _ThinkingRow(text: '멈추는 중'),
        if (_c.confirmArgs != null) _confirmCard(_c.confirmArgs!),
        if (_c.question != null) _questionCard(_c.question!),
        if (_c.outcome != null) _answerCard(_c.outcome!),
        if (_c.isRunning) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: _c.isStopping ? null : _c.stop,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('멈추기'),
            ),
            TextButton(onPressed: _c.isStopping ? null : _newRequest, child: const Text('새로 부탁하기')),
          ]),
        ],
      ],
    );
  }

  Widget _confirmCard((DateTime, String) args) {
    final (date, tpo) = args;
    return _AskCard(
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
            decoration: const InputDecoration(hintText: '답을 적어 주세요', isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: send, child: const Text('보내기')),
        ],
      ),
    );
  }

  Widget _answerCard(AskOutcome o) {
    final combo = o.end == AskEnd.finished ? askCombo(_c.steps) : const <WardrobeItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AskAnswerBox(
          answer: o.answer,
          stopped: o.end != AskEnd.finished,
          thumbs: [
            for (final i in combo)
              AskItemThumb(id: i.id, imageUrl: i.imageUrl, cutoutImageUrl: i.cutoutImageUrl),
          ],
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
            onPressed: _newRequest,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('새로 부탁하기'),
          ),
        ]),
      ],
    );
  }
}

// 지난 부탁 다시 보기(읽기 전용).
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
        title: Text('지난 부탁 · ${_timeLabel(record.createdAt)}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _RequestHeader(request: record.request),
            const SizedBox(height: 20),
            for (final s in record.steps)
              AskStepTile(
                step: AskStep(
                    thought: s.thought,
                    action: s.action,
                    args: const {},
                    observation: s.summary.isEmpty ? null : s.summary,
                    status: s.action == '-' ? AskStepStatus.failed : AskStepStatus.done),
              ),
            AskAnswerBox(
              answer: record.answer,
              stopped: !record.finished,
              thumbs: [
                for (final i in record.items)
                  AskItemThumb(id: i.id, imageUrl: i.imageUrl, cutoutImageUrl: i.cutoutImageUrl),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestHeader extends StatelessWidget {
  final String request;
  const _RequestHeader({required this.request});

  @override
  Widget build(BuildContext context) {
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

class AskAnswerBox extends StatelessWidget {
  final String answer;
  final bool stopped;
  final List<Widget> thumbs;
  const AskAnswerBox({super.key, required this.answer, required this.stopped, this.thumbs = const []});

  @override
  Widget build(BuildContext context) {
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
          Text(answer, style: const TextStyle(fontSize: 15, height: 1.45, color: AppColors.textPrimary)),
          if (thumbs.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: thumbs),
          ],
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
  const AskItemThumb({super.key, required this.id, required this.imageUrl, this.cutoutImageUrl});

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
