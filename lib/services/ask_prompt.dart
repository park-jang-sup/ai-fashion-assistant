// AI에게 부탁하기 — 단계 프롬프트(docs/task_agent_ask_v1.md §2-4). 순수 함수 + 골든
// (test/goldens/ask_prompt_*.txt). 요청 하나 = contents 1개·text part 1개에 지침·도구 설명·
// 오늘 날짜·사용자 요청·지금까지의 단계 기록을 모두 담는다. 서버 상한(전체 30,000자)을 넘지
// 않게, 넘으면 오래된 관찰부터 줄인다.
import '../constants/tpo_tags.dart';
import 'ask_dates.dart';
import 'ask_engine.dart';
import 'ask_registry.dart';
import 'ask_tools.dart';

// 서버 request_shape.ts의 maxTotalTextChars(30,000)보다 여유를 둔다.
const askPromptMaxChars = 28000;

// [도구] 절은 도구 등록부(ask_registry.dart)에서 만든다.
String _toolsSection() => askToolsPromptSection();

String _rulesSection() => '''
[규칙]
- 출력은 아래 형식의 JSON 하나뿐이다. 다른 글, 코드 블록, 설명을 붙이지 않는다.
  {"thought":"사용자에게 보일 한 문장","action":"도구 이름","args":{...}}
- 한국어로 쓴다. thought는 지금 무엇을 왜 하는지 한 문장이다.
- 옷은 도구 결과에 나온 것만 말한다. 도구 결과에 없는 옷을 지어내지 않는다.
- add_plan은 사용자가 일정 등록이나 코디 준비를 부탁했을 때만 쓴다. 묻기만 한 요청에는 쓰지 않는다.
- 준비·등록 요청에는 add_plan 전에 get_calendar(그 날짜에 일정이 이미 있는지)와 get_weather를 둘 다 확인한다. 날짜와 상황이 요청에 분명히 있어도 확인한다.
- "사용자가 취소함" 결과가 나오면 add_plan을 다시 쓰지 않고 finish한다.
- 날짜 표현("내일", "모레", "다음 주 월요일", "금요일" 등)은 직접 계산하지 말고 [날짜표]에서 찾아 그 줄의 날짜를 쓴다. 주를 말하지 않은 요일은 표에서 오늘부터 가장 가까운 그 요일이다.
- 표에 없는 날짜(14일 밖, 기념일 이름 등)는 표를 기준으로 세고, 확실하지 않으면 ask_user로 날짜를 묻는다.
- 날짜나 상황을 알 수 없으면 ask_user를 한 번 쓴다.
- 옷·일정·날씨와 무관한 요청은 도구를 쓰지 않고 finish로 할 수 있는 일을 안내한다.
- 같은 도구를 같은 목적으로 두 번 넘게 부르지 않는다. 결과가 부족해도 얻은 것으로 답한다.
- 확인할 것이 끝나면 바로 finish한다. finish의 answer는 확인한 결과를 바탕으로 두세 문장이다.''';

String _tpoSection() =>
    '[상황 태그와 격식] ${TpoTags.all.map((t) => '${t.label}(${t.formalityHint})').join(', ')}';

String _stepLine(int i, AskStep s, {String? observationOverride}) {
  final args = s.args.entries.map((e) => '"${e.key}":"${e.value}"').join(',');
  final obs = observationOverride ?? s.observation ?? '(결과 없음)';
  return '${i + 1}. 생각: ${s.thought}\n   도구: ${s.action} {$args}\n   결과: $obs';
}

// remainingCalls가 있으면 단계 기록 끝에 "남은 호출 N회"를 붙인다(엔진이 4회 호출 뒤부터 넘긴다).
String buildAskPrompt(
    {required String request, required List<AskStep> steps, required DateTime today, int? remainingCalls}) {
  String assemble(List<String> stepLines) => [
        '너는 사용자의 옷장·일정·날씨 예보를 도구로 확인해 코디를 돕는 비서다.',
        '[오늘] ${askDateLabel(today)}',
        '[날짜표] 오늘부터 $askDateTableDays일. 한 주는 월요일부터 일요일까지다.\n${buildAskDateTable(today)}',
        _tpoSection(),
        _toolsSection(),
        _rulesSection(),
        '[사용자 요청] ${request.trim()}',
        (stepLines.isEmpty ? '[지금까지의 단계] 아직 없음' : '[지금까지의 단계]\n${stepLines.join('\n')}') +
            (remainingCalls == null ? '' : '\n남은 호출 $remainingCalls회'),
        '[다음] 위 규칙에 맞는 JSON 하나로 다음 단계를 답한다.',
      ].join('\n\n');

  var lines = [for (var i = 0; i < steps.length; i++) _stepLine(i, steps[i])];
  var prompt = assemble(lines);
  // 상한을 넘으면 오래된 관찰부터 짧게 줄인다(마지막 단계의 관찰은 남긴다).
  for (var i = 0; i < steps.length - 1 && prompt.length > askPromptMaxChars; i++) {
    final obs = steps[i].observation ?? '';
    lines[i] = _stepLine(i, steps[i],
        observationOverride: obs.length <= 200 ? obs : '${obs.substring(0, 200)}… (줄임)');
    prompt = assemble(lines);
  }
  return prompt;
}
