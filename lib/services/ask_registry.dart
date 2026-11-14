// AI에게 부탁하기 — 도구 등록부(docs/task_agent_ask_v2.md §2-0). 도구마다 이름, 인자 형식과 검증,
// 실행 함수, 화면용 이름, 요청당 횟수 상한, 쓰기 여부와 확인 필요 여부를 이 한 곳에 정의한다.
// 프롬프트의 [도구] 절(ask_prompt.dart), 출력 검증(validateAskReply), 엔진의 한도·확인 처리
// (ask_engine.dart), 화면·활동 내역의 도구 이름이 모두 여기서 나온다 — 도구를 더하거나 고칠 때 이
// 파일만 바꾼다.
import 'dart:async';

import '../models/wardrobe_item.dart';
import 'ask_tools.dart';

// 엔진이 도구 실행에 넘기는 것. 사용자 차례(확인·질문)를 기다리는 동안은 waitForUser로 감싸 요청
// 전체 시한의 시계를 멈춘다.
class AskRunContext {
  final AskTools tools;
  final Future<bool> Function(DateTime date, String tpo) confirmPlan;
  final Future<String?> Function(String question) askUser;
  final Future<T> Function<T>(Future<T> Function() wait) waitForUser;
  final bool Function() isCancelled;
  final AskFittingPort? fitting; // 가상 피팅 경로(없으면 try_on을 쓸 수 없다)
  const AskRunContext({
    this.fitting,
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
  final List<String> itemArgs; // 옷 번호 목록을 받는 인자 — 엔진이 대화에 있는 번호인지 본다
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
    this.itemArgs = const [],
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
    signature: '{"date":"YYYY-MM-DD","tpo":"상황 태그","count":1~5(선택),"style":"글자"(선택),'
        '"keep":[옷 번호](선택),"exclude":[옷 번호](선택),"adjust":"더 따뜻하게|더 가볍게"(선택),"unworn_first":true(선택)}',
    description: '그날 예보와 상황에 맞춘 코디 미리 보기. 저장하지 않는다. count는 서로 다른 조합 수(앞 조합의 상의·아우터를 빼고 다시 고른다). '
        'style은 상의·하의·아우터를 태그에 그 글자가 든 옷으로 좁힌다. keep은 그 종류를 그 옷으로 고정, exclude는 빼고 고른다. '
        'adjust는 기온대를 한 단계 옮겨 고른다. unworn_first가 참이면 종류마다 최근 60일 착장 기록에 없는 옷으로 좁힌다. '
        '예보 범위 밖 날짜는 오늘 기온대로 고른다.',
    displayName: '코디 미리 보기',
    validate: (args) {
      final base = _validDateTpo(args);
      if (base != null) return base;
      final c = args['count'];
      if (c != null && (c is! int || c < 1 || c > askPreviewMaxCount)) return '출력 오류: count는 1~$askPreviewMaxCount의 정수예요';
      final st = args['style'];
      if (st != null && (st is! String || st.trim().isEmpty)) return '출력 오류: style은 글자여야 해요';
      for (final k in const ['keep', 'exclude']) {
        final v = args[k];
        if (v == null) continue;
        if (v is! List || v.any((x) => parseAskItemNumber(x) == null)) return '출력 오류: $k는 옷 번호 목록이에요(예: [12, 31])';
      }
      final uw = args['unworn_first'];
      if (uw != null && uw is! bool) return '출력 오류: unworn_first는 true 또는 false예요';
      final ad = args['adjust'];
      if (ad != null && ad != askAdjustWarmer && ad != askAdjustLighter) {
        return '출력 오류: adjust는 "$askAdjustWarmer" 또는 "$askAdjustLighter"예요';
      }
      return null;
    },
    itemArgs: const ['keep', 'exclude'],
    run: (ctx, args) async => _done(await ctx.tools.previewOutfit(args)),
  ),
  AskToolSpec(
    name: 'get_style_history',
    signature: '{}',
    description: '최근 60일 착장 기록과 추천 반응 요약. 자주 입은 옷 5벌, 자주 입은 색·격식, 상황별 가장 최근 착장, '
        '추천을 그대로 입은 횟수와 다르게 입은 횟수, 60일 동안 기록에 없는 옷의 수와 예시.',
    displayName: '착장 기록 확인',
    validate: (args) => null,
    dedupe: true,
    dedupeMessage: askRepeatMessage,
    run: (ctx, args) async => _done(await ctx.tools.getStyleHistory(args)),
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
    name: 'try_on',
    signature: '{"outfit":[옷 번호]}',
    description: '그 조합을 코디보드에 올리고 지금 선택된 전신 사진에 가상 피팅한다(10~20초). 사용자가 입은 모습을 보여 달라고 했을 때만 쓴다. 한 턴에 한 번.',
    displayName: '입혀 보기',
    validate: (args) {
      final v = args['outfit'];
      if (v is! List || v.isEmpty || v.any((x) => parseAskItemNumber(x) == null)) {
        return '출력 오류: outfit은 옷 번호 목록이에요(예: [12, 31, 7])';
      }
      return null;
    },
    itemArgs: const ['outfit'],
    limitPerRequest: 1,
    limitMessage: '입혀 보기는 한 턴에 한 번이에요. 이미 한 결과로 답하세요',
    writes: true, // 가상 피팅의 기존 저장(캐시·히스토리) — 확인 카드는 띄우지 않는다(사용자가 직접 부탁, 되돌릴 수 없는 변경 아님)
    run: (ctx, args) async {
      final port = ctx.fitting;
      if (port == null) {
        return const AskRunResult(AskToolResult('이 기기에서는 입혀 보기를 쓸 수 없어요', display: '입혀 보기를 쓸 수 없어요', ok: false));
      }
      final items = [for (final n in askNumberList(args['outfit'])) ctx.tools.book.item(n)].whereType<WardrobeItem>().toList();
      if (!port.hasUserPhoto()) {
        return const AskRunResult(AskToolResult(
            '전신 사진이 선택돼 있지 않아 입혀 보지 못했어요 — 피팅룸에서 전신 사진을 고르면 입혀 볼 수 있어요',
            display: '전신 사진이 없어 입혀 보지 못했어요',
            ok: false));
      }
      if (port.busy()) {
        return const AskRunResult(AskToolResult('다른 가상 피팅이 진행 중이라 실행하지 않았어요 — 끝난 뒤에 다시 부탁할 수 있어요',
            display: '다른 피팅이 진행 중이라 기다리지 않았어요', ok: false));
      }
      final AskFittingOutcome out;
      try {
        // 피팅을 기다리는 시간(최대 120초)은 단계·전체 시한에 세지 않는다.
        out = await ctx.waitForUser(() => port.run(items).timeout(askTryOnWait));
      } on TimeoutException {
        return const AskRunResult(AskToolResult('입혀 보기가 오래 걸려 기다리지 않고 넘어갔어요 — 코디보드에는 올려 두었어요',
            display: '입혀 보기가 오래 걸려 넘어갔어요', ok: false));
      }
      if (ctx.isCancelled()) throw const AskCancelled();
      final error = out.error;
      if (error != null || out.shot == null) {
        final limited = error != null && _looksRateLimited(error);
        return AskRunResult(AskToolResult(
            limited
                ? '가상 피팅은 시간당 6번까지라 지금은 입혀 볼 수 없어요 — 코디보드에는 올려 두었어요'
                : '입혀 보지 못했어요(${error ?? '결과 없음'}) — 코디보드에는 올려 두었어요. 다시 시도하지 않는다',
            display: limited ? '입혀 보기 한도에 걸렸어요' : '입혀 보지 못했어요',
            ok: false));
      }
      final missing = out.missingCategories.isEmpty ? '' : ' 다만 ${out.missingCategories.join('·')}는 입히지 못했어요.';
      return AskRunResult(AskToolResult(
        '입혀 봤어요: ${items.map(ctx.tools.describe).join(', ')}. 코디보드에도 올려 두었어요.$missing',
        display: '입혀 봤어요 — 코디보드에도 올렸어요',
        items: items,
        fitting: out.shot,
      ));
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
    signature: '{"answer":"사용자에게 보일 답","buy":["옷 종류 — 가진 옷 가운데 무엇과 어울리는지"](선택, 최대 3개)}',
    description: '끝낸다. 옷장에 없지만 가진 옷과 어울리는 옷 종류는 answer가 아니라 buy에 쓴다.',
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

// 피팅 실패 문구가 호출량 상한 때문인지(서버 문구가 바뀔 수 있어 넓게 본다).
bool _looksRateLimited(String error) =>
    ['호출량', '시간당', '한도', '상한', 'resource-exhausted', '429'].any(error.contains);
