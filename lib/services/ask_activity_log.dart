// AI에게 부탁하기 — 활동 내역(docs/task_agent_ask_v1.md §2-5). 요청 시작("AI에게 부탁: …"),
// 도구마다 한 줄, 끝난 답의 첫 문장을 남긴다. 한 요청은 같은 relatedDocId로 묶는다.
// add_plan이 부르는 기존 준비 경로의 로그는 그 형식(일정 id로 묶음)을 그대로 둔다 — 그래서
// 화면에서 묶음이 나뉠 수 있다(§1-9, 사용자 결정). 쓰기는 기존 addAgentLogSilently(실패 무시).
import '../models/agent_log_entry.dart';
import 'ask_engine.dart';
import 'ask_registry.dart';

const _lineMax = 100;

String _clipLine(String s) {
  final line = s.split('\n').first.trim();
  return line.length <= _lineMax ? line : '${line.substring(0, _lineMax - 1)}…';
}

// 답의 첫 문장 — 마침표·물음표·느낌표 뒤 공백이나 줄바꿈에서 자른다.
String askFirstSentence(String answer) {
  final t = answer.trim();
  final m = RegExp(r'^.*?[.!?](?=\s|$)', dotAll: true).firstMatch(t);
  return _clipLine(m?.group(0) ?? t);
}

class AskActivityLog {
  final void Function(AgentLogEntry entry) write;
  final String relatedId;
  final _logged = <int>{};

  AskActivityLog({required this.write, required this.relatedId});

  AgentLogEntry _entry(String type, String message) =>
      AgentLogEntry(id: '', eventType: type, message: message, relatedDocId: relatedId);

  void started(String request) => write(_entry(AgentLogEntry.typeAskRequested, 'AI에게 부탁: ${_clipLine(request)}'));

  // 결과가 나온 도구 단계마다 한 번씩. 읽지 못한 출력과 finish는 남기지 않는다.
  void steps(List<AskStep> steps) {
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final name = askToolDisplayName(s.action);
      if (name == null || s.observation == null || _logged.contains(i)) continue;
      _logged.add(i);
      final detail = s.action == 'ask_user' ? '${s.args['question'] ?? ''}' : s.observation!;
      write(_entry(AgentLogEntry.typeAskStep, '$name — ${_clipLine(detail)}'));
    }
  }

  void ended(AskOutcome o) {
    steps(o.steps);
    final head = o.end == AskEnd.finished ? 'AI 답' : 'AI에게 부탁 멈춤';
    write(_entry(AgentLogEntry.typeAskAnswered, '$head: ${askFirstSentence(o.answer)}'));
  }
}
