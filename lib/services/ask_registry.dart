// AI에게 부탁하기 — 도구 등록부(docs/task_agent_ask_v2.md §2-0). 도구마다 이름, 인자 형식과 검증,
// 실행 함수, 화면용 이름, 요청당 횟수 상한, 쓰기 여부와 확인 필요 여부를 이 한 곳에 정의한다.
// 프롬프트의 [도구] 절(ask_prompt.dart), 출력 검증(validateAskReply), 엔진의 한도·확인 처리
// (ask_engine.dart), 화면·활동 내역의 도구 이름이 모두 여기서 나온다 — 도구를 더하거나 고칠 때 이
// 파일만 바꾼다.
import 'ask_tools.dart';

// 엔진이 도구 실행에 넘기는 것. 사용자 차례(확인·질문)를 기다리는 동안은 waitForUser로 감싸 요청
// 전체 시한의 시계를 멈춘다.
class AskRunContext {
  final AskTools tools;
  final Future<bool> Function(DateTime date, String tpo) confirmPlan;
  final Future<String?> Function(String question) askUser;
  final Future<T> Function<T>(Future<T> Function() wait) waitForUser;
  final bool Function() isCancelled;
  const AskRunContext({
    required this.tools,
    required this.confirmPlan,
    required this.askUser,
    required this.waitForUser,
    required this.isCancelled,
  });
}

// 실행 도중 사용자가 멈췄거나 답하지 않고 떠났다 — 엔진은 요청을 멈춤으로 끝낸다.
class AskCancelled implements Exception {
  const AskCancelled();
}

// counted: 요청당 횟수 상한에 셀지(인자 검증에서 막힌 실행은 세지 않는다).
class AskRunResult {
  final AskToolResult result;
  final bool counted;
  const AskRunResult(this.result, {this.counted = true});
}

typedef AskToolRun = Future<AskRunResult> Function(AskRunContext ctx, Map<String, dynamic> args);

class AskToolSpec {
  final String name;
  final String signature; // 프롬프트에 보일 인자 형식
  final String description; // 프롬프트에 보일 설명
  final String displayName; // 화면·활동 내역의 한국어 이름
  final String? Function(Map args) validate; // 출력 규약 검증 — 맞으면 null
  final int? limitPerRequest; // 한 턴(사용자 말 하나)에서 실행 상한(null = 없음)
  final String? limitMessage; // 상한에 걸렸을 때 관찰(모델용 — 화면에는 askDisplayBlocked)
  final bool dedupe; // 같은 인자의 반복은 실행하지 않는다
  final String? dedupeMessage;
  final bool writes; // 데이터를 쓰는가
  final bool needsConfirm; // 쓰기 전에 사용자 확인을 받는가
  final AskToolRun? run; // null = 엔진이 직접 처리(finish)
  const AskToolSpec({
    required this.name,
    required this.signature,
    required this.description,
    required this.displayName,
    required this.validate,
    this.limitPerRequest,
    this.limitMessage,
    this.dedupe = false,
    this.dedupeMessage,
    this.writes = false,
    this.needsConfirm = false,
    this.run,
  });

  String get promptLine => '- $name $signature — $description';
}

// 한 턴에서 search_wardrobe를 실행하는 상한(v2 §2-B-3). 같은 인자의 반복은 따로 막는다.
const askMaxWardrobeSearches = 3;
const askWardrobeSearchLimitMessage = '옷장 조회는 한 번의 요청에 세 번까지예요. 이미 얻은 결과로 답하세요';
const askRepeatMessage = '같은 조건으로 이미 조회했어요. 위 결과를 쓰세요';

const _range = '{"from":"YYYY-MM-DD","to":"YYYY-MM-DD"}';
const _dateTpo = '{"date":"YYYY-MM-DD","tpo":"상황 태그"}';

String? _needDate(Map args, String key) =>
    parseAskDate(args[key]) == null ? '출력 오류: $key는 YYYY-MM-DD 형식이어야 해요' : null;
String? _validRange(Map args) => _needDate(args, 'from') ?? _needDate(args, 'to');
String? _validDateTpo(Map args) =>
    _needDate(args, 'date') ?? (isAskTpo(args['tpo']) ? null : '출력 오류: tpo는 상황 태그 9개 중 하나여야 해요');

AskRunResult _done(AskToolResult r) => AskRunResult(r);

final List<AskToolSpec> askToolRegistry = [
  AskToolSpec(
    name: 'get_calendar',
    signature: _range,
    description: '일정 조회(최대 14일). 날짜별 일정(상황, 예정/기록)과 그 날짜에 준비된 추천의 요약.',
    displayName: '일정 확인',
    validate: _validRange,
    run: (ctx, args) async => _done(await ctx.tools.getCalendar(args)),
  ),
  AskToolSpec(
    name: 'get_weather',
    signature: _range,
    description: '예보 조회. 날짜별 최고·최저·강수확률, 기온대(더움/온화/선선/추움), 비 여부. 오늘 포함 7일 밖은 "예보 범위 밖".',
    displayName: '예보 확인',
    validate: _validRange,
    run: (ctx, args) async => _done(await ctx.tools.getWeather(args)),
  ),
  AskToolSpec(
    name: 'search_wardrobe',
    signature: '{"category":"상의|하의|아우터|신발|액세서리"(선택), "keyword":"글자"(선택)}',
    description: '옷장 조회. 인자가 없으면 종류별 벌수, 있으면 일치 벌수와 최대 8벌(종류·색·태그·격식). '
        'category만 주면 그 종류 전체의 태그별 벌수와 한겨울용 옷 목록도 준다. 요청 하나에 세 번까지, 같은 조건은 다시 조회하지 않는다.',
    displayName: '옷장 조회',
    validate: (args) {
      final c = args['category'];
      final k = args['keyword'];
      if (c != null && !isAskCategory(c)) return '출력 오류: category는 ${askCategories.join('·')} 중 하나예요';
      if (k != null && (k is! String || k.trim().isEmpty)) return '출력 오류: keyword는 글자여야 해요';
      return null;
    },
    // 한 턴에 3회까지, 같은 인자는 다시 실행하지 않는다(막힌 호출도 모델 호출 횟수에는 들어간다).
    limitPerRequest: askMaxWardrobeSearches,
    limitMessage: askWardrobeSearchLimitMessage,
    dedupe: true,
    dedupeMessage: askRepeatMessage,
    run: (ctx, args) async => _done(await ctx.tools.searchWardrobe(args)),
  ),
  AskToolSpec(
    name: 'get_wardrobe_profile',
    signature: '{}',
    description: '옷장 전체 요약. 종류별 벌수, 종류마다 계절(여름/간절기/가을·겨울/한겨울용)과 격식 분포, 많은 색과 스타일, '
        '한겨울용 아우터, 빈 부분(오늘 기온대에 맞는 옷이 부족한 종류, 격식별로 없는 종류). 옷장 전체를 볼 때 먼저 쓴다.',
    displayName: '옷장 요약',
    validate: (args) => null,
    dedupe: true,
    dedupeMessage: askRepeatMessage,
    run: (ctx, args) async => _done(await ctx.tools.getWardrobeProfile(args)),
  ),
  AskToolSpec(
    name: 'preview_outfit',
    signature: _dateTpo,
    description: '그날 예보와 상황에 맞춘 코디 미리 보기. 저장하지 않는다.',
    displayName: '코디 미리 보기',
    validate: _validDateTpo,
    run: (ctx, args) async => _done(await ctx.tools.previewOutfit(args)),
  ),
  AskToolSpec(
    name: 'add_plan',
    signature: _dateTpo,
    description: '예정 일정을 등록하고 그 일정의 코디를 준비한다(앱이 사용자에게 확인을 받은 뒤 실행). 오늘부터 60일 안만.',
    displayName: '일정 등록',
    validate: _validDateTpo,
    // 확인 카드까지 간 실행(등록·취소 모두)만 센다 — 같은 요청에서 다시 내도 실행하지 않는다.
    limitPerRequest: 1,
    limitMessage: '이 요청에서는 일정 등록을 다시 실행하지 않아요',
    writes: true,
    needsConfirm: true,
    run: (ctx, args) async {
      final invalid = ctx.tools.validatePlan(args);
      if (invalid != null) return AskRunResult(AskToolResult(invalid, ok: false), counted: false);
      final date = parseAskDate(args['date'])!;
      final confirmed = await ctx.waitForUser(() => ctx.confirmPlan(date, args['tpo'] as String));
      if (ctx.isCancelled()) throw const AskCancelled(); // 확인 없이 떠나면 쓰지 않는다
      if (!confirmed) {
        return const AskRunResult(AskToolResult('사용자가 취소함 — 일정을 등록하지 않았어요', display: '등록하지 않았어요', ok: false));
      }
      return AskRunResult(await ctx.tools.addPlan(args));
    },
  ),
  AskToolSpec(
    name: 'ask_user',
    signature: '{"question":"한 문장"}',
    description: '사용자에게 되묻는다. 요청 하나에 한 번까지.',
    displayName: '질문',
    validate: (args) {
      final q = args['question'];
      return q is String && q.trim().isNotEmpty ? null : '출력 오류: ask_user에는 question이 필요해요';
    },
    limitPerRequest: 1,
    limitMessage: '질문은 요청 하나에 한 번만 할 수 있어요 — 지금까지 확인한 것으로 답해 주세요',
    run: (ctx, args) async {
      final answer = await ctx.waitForUser(() => ctx.askUser((args['question'] as String).trim()));
      if (ctx.isCancelled() || answer == null) throw const AskCancelled();
      return AskRunResult(AskToolResult('사용자의 답: $answer', display: '답: $answer'));
    },
  ),
  AskToolSpec(
    name: 'finish',
    signature: '{"answer":"사용자에게 보일 답"}',
    description: '끝낸다.',
    displayName: '답',
    validate: (args) {
      final a = args['answer'];
      return a is String && a.trim().isNotEmpty ? null : '출력 오류: finish에는 answer가 필요해요';
    },
  ),
];

final Map<String, AskToolSpec> _byName = {for (final t in askToolRegistry) t.name: t};

AskToolSpec? askToolSpec(String name) => _byName[name];

// 화면·활동 내역의 도구 이름. 등록부에 없으면 null.
String? askToolDisplayName(String action) => action == 'finish' ? null : _byName[action]?.displayName;

// 프롬프트의 [도구] 절.
String askToolsPromptSection() =>
    '[도구] 한 단계에 하나만 고른다.\n${[for (final t in askToolRegistry) t.promptLine].join('\n')}';
