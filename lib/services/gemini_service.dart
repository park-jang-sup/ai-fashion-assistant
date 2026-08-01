import 'dart:async';
import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../config/env.dart';
import '../models/clothing_attributes.dart';
import '../models/clothing_size.dart';
import '../models/user_profile.dart';
import 'gemini_api_exception.dart';

class GeminiService {
  static const _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';

  // 모델명을 한 곳에 모아서 나중에 교체하기 쉽게 관리한다.
  // gemini-3-flash-preview로 시도해봤으나 응답이 중간에 잘리는 등
  // preview 특유의 불안정함이 반복 확인돼 안정적인 gemini-3.5-flash로 되돌림.
  static const _textModel = 'gemini-3.5-flash';

  // 기본 텍스트 모델이 과부하(503)·요청 급증(429)·타임아웃으로 실패했을 때
  // 같은 모델로 다시 두드리는 대신 바꿔 타는 대체 모델.
  // gemini-2.5-flash가 "no longer available to new users" 오류로 막혀
  // gemini-3.1-flash-lite로 교체(ListModels로 모델명 확인 + generateContent
  // 실호출 성공 검증 완료 — 2026-07-12). Lite라 응답도 더 빠르다.
  static const textModelFallback = 'gemini-3.1-flash-lite';

  // extractAttributes/extractSizeFromChart/analyzeOutfitFromAttributes(Stream)
  // 등 텍스트 모델을 쓰는 모든 호출에 공통 적용하는 재시도 정책 — 기본
  // 모델이 일시적 오류로 실패하면 같은 모델이 아니라 대체 모델로 한 번만
  // 더 시도한다. action은 실제 사용할 모델명을 받아 그 모델로 호출해야 한다.
  static Future<T> withTextModelFallback<T>(
    Future<T> Function(String model) action,
  ) async {
    try {
      return await action(_textModel);
    } on TimeoutException {
      return await action(textModelFallback);
    } on GeminiApiException catch (e) {
      if (!e.isRetryable) rethrow;
      return await action(textModelFallback);
    } on FormatException {
      // 1차 모델이 JSON을 다 못 쓰고 잘리는 경우(_parseJsonObject 참고)도
      // 같은 모델로 재시도해봤자 또 잘릴 수 있으므로 대체 모델로 넘긴다.
      return await action(textModelFallback);
    }
  }

  // ── 텍스트 계열 Gemini 프록시 호출 (A-1) ────────────────────
  // 서버(functions/src/index.ts의 callGeminiText)는 requestBody를 가공 없이
  // 그대로 중계하고 원본 JSON을 그대로 돌려준다. 그래서 이 두 헬퍼 아래의
  // _extractTextFromResponse/_parseJsonObject 등 파싱 코드는 프록시 도입
  // 전과 한 글자도 다르지 않다 — 직접 호출 때의 response.body(String)
  // 자리에 프록시 결과를 문자열로 되돌려주는 것뿐이다.
  static Future<String> _callProxyText({
    required String model,
    required Map<String, dynamic> requestBody,
  }) async {
    try {
      final result = await _functions
          .httpsCallable('callGeminiText',
              options: HttpsCallableOptions(timeout: const Duration(seconds: 60)))
          .call({'model': model, 'requestBody': requestBody});
      return jsonEncode(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw _mapProxyException(e);
    }
  }

  static Stream<String> _callProxyTextStream({
    required String model,
    required Map<String, dynamic> requestBody,
  }) async* {
    final callable = _functions.httpsCallable('callGeminiText',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 60)));

    // 예전에 Accept-Encoding: identity로 gzip 버퍼링을 막아 진짜 점진적
    // 스트리밍을 확보했던 것과 같은 목적의 정체 감지 타임아웃 — 이벤트
    // 간격이 60초를 넘으면 멈춘 것으로 보고 끊는다. HttpsCallableOptions의
    // timeout은 호출 전체 1회 한도라 이걸 대체하지 않으므로 둘 다 둔다.
    final responses = callable
        .stream({'model': model, 'requestBody': requestBody}).timeout(const Duration(seconds: 60));

    try {
      await for (final response in responses) {
        switch (response) {
          case Chunk(:final partialData):
            // cloud_functions가 플랫폼 채널로 돌려주는 partialData는 런타임
            // 타입이 Map<Object?, Object?>라, as Map<String, dynamic>처럼
            // 제네릭까지 검사하는 캐스트는 여기서 항상 실패한다(실기기에서
            // "type '_Map<Object?, Object?>' is not a subtype of type
            // 'Map<String, dynamic>'"로 실제 확인됨). _callProxyText의
            // jsonEncode(result.data)가 문제없었던 건 jsonEncode가 키의
            // 런타임 타입(String인지)만 보고 Map의 정적 제네릭은 안 보기
            // 때문이다 — 같은 데이터라도 캐스트냐 인코딩이냐에 따라 결과가
            // 갈린다. A-2에서 스트리밍을 또 쓸 때 같은 실수를 반복하지 않기
            // 위해 남긴다.
            final data = Map<String, dynamic>.from(partialData as Map);
            final candidates = data['candidates'] as List?;
            if (candidates != null && candidates.isNotEmpty) {
              final content = (candidates[0] as Map)['content'] as Map?;
              final parts0 = content?['parts'] as List?;
              if (parts0 != null && parts0.isNotEmpty) {
                final text = (parts0[0] as Map)['text'] as String?;
                if (text != null && text.isNotEmpty) yield text;
              }
            }
            break;
          case Result():
            break;
        }
      }
    } on FirebaseFunctionsException catch (e) {
      throw _mapProxyException(e);
    }
  }

  // Callable 에러를 기존 withTextModelFallback이 알아듣는 예외로 되돌린다.
  // - deadline-exceeded: 직접 호출 때 .timeout()이 던지던 TimeoutException과
  //   같은 상황이다. 그냥 rethrow하면 FirebaseFunctionsException은
  //   on TimeoutException에 안 걸려 폴백 없이 그냥 실패한다.
  // - unauthenticated: 모델을 바꿔도 인증이 생기는 게 아니므로 폴백 왕복이
  //   무의미하다. GeminiApiException으로 재구성하지 않고 그대로 전파한다.
  // - data-loss: 서버가 업스트림 응답 본문을 다 읽지 못했을 때(연결 끊김)
  //   던지는 코드. 실제로 Gemini가 503을 준 것은 아니지만, 성격이 "지금은
  //   실패해도 다시 시도하면 될 수 있는 일시적 문제"로 동일하므로 기존
  //   503/429 재시도 판정(isRetryable)에 그대로 태운다.
  // - details.reason == invalid-json: 200(또는 SSE 청크)인데 본문이 유효
  //   JSON이 아니었던 경우. 직접 호출 때 _parseJsonObject가 던지던
  //   FormatException과 같은 성격이므로 동일하게 재구성한다.
  // - 그 외 details에 upstreamStatus가 있으면(Gemini가 실제로 응답한 오류)
  //   직접 호출 때와 동일하게 GeminiApiException으로 재구성해 isRetryable
  //   (503/429) 판정이 그대로 동작하게 한다.
  // - 위 어디에도 안 걸리는 나머지 실패(네트워크 등)는 그대로 전파한다.
  static Object _mapProxyException(FirebaseFunctionsException e) {
    if (e.code == 'deadline-exceeded') return TimeoutException(e.message);
    if (e.code == 'unauthenticated') return e;
    if (e.code == 'data-loss') {
      return GeminiApiException(503, e.message ?? '연결이 끊겼습니다.');
    }
    final details = e.details;
    if (details is Map) {
      if (details['reason'] == 'invalid-json') {
        return FormatException(e.message ?? '알 수 없는 오류');
      }
      final status = details['upstreamStatus'];
      if (status is int) {
        final message = details['upstreamMessage'] as String? ?? e.message ?? '알 수 없는 오류';
        return GeminiApiException(status, message);
      }
    }
    return e;
  }

  // 이미지 합성 모델 — 둘 중 하나만 주석 해제해서 사용. 필요할 때 바꿔가며
  // 비교해볼 수 있도록 나머지는 주석으로 남겨둔다.
  // 동일 조건(사람 사진 1장 + 옷 1장) 비교 결과 Nano Banana 2가 평균
  // 약 1.9배 빠르고(12.7초 vs 23.7초) 품질도 대등해 기본값으로 채택.
  // static const _imageModel = 'gemini-3-pro-image'; // Nano Banana Pro
  static const _imageModel = 'gemini-3.1-flash-image'; // Nano Banana 2

  // 커넥션을 재사용해 매 요청마다의 TLS 핸드셰이크 비용을 줄인다.
  static final http.Client _client = http.Client();

  // Storage 버킷과 같은 리전(asia-northeast3) — 배포 후 리전을 바꾸려면
  // 함수를 지우고 다시 올려야 하므로 처음부터 맞춰둔다.
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-northeast3');

  // 같은 세션에서 분석 → 가상 피팅을 연달아 실행하면 동일한 이미지 URL을
  // 반복 다운로드하게 되므로, 바이트를 캐시해 재다운로드를 피한다.
  static final Map<String, Uint8List> _imageCache = {};

  // ── 가상 피팅 이미지 생성 ────────────────────────────────
  static Future<Uint8List> generateFittingImage({
    required String userPhotoUrl,
    required List<String> clothingImageUrls,
    required List<String> clothingNames,
  }) async {
    // 이미지들을 순차 다운로드하면 N개 x 다운로드시간만큼 대기하게 되므로
    // Future.wait로 병렬 실행해 가장 느린 한 건의 시간만큼만 기다리게 한다.
    final downloaded = await Future.wait([
      _downloadImageBytesCached(userPhotoUrl),
      ...clothingImageUrls.map(_downloadImageBytesCached),
    ]);
    final userPhotoBytes = downloaded.first;
    final clothingImageBytes = downloaded.skip(1).toList();

    final parts = <Map<String, dynamic>>[
      {'text': _buildFittingPrompt(clothingNames)},
      {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(userPhotoBytes)}},
      ...clothingImageBytes.map((bytes) => {
        'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(bytes)}
      }),
    ];

    final requestBody = jsonEncode({
      'contents': [{'parts': parts}],
      'generationConfig': {'responseModalities': ['IMAGE', 'TEXT']},
    });

    final response = await _client
        .post(
          Uri.parse('$_baseUrl/models/$_imageModel:generateContent?key=${Env.geminiApiKey}'),
          headers: {'Content-Type': 'application/json'},
          body: requestBody,
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      final errorBody = jsonDecode(response.body);
      final message = (errorBody['error']?['message'] as String?) ?? '알 수 없는 오류';
      throw GeminiApiException(response.statusCode, message);
    }

    return _extractImageFromResponse(response.body);
  }

  // ── 옷 사진 1장 → 속성 추출 (등록 시점 백그라운드 / 분석 시점 폴백) ──
  static Future<ClothingAttributes> extractAttributes({
    required String imageUrl,
    required String category,
    String? model,
  }) async {
    final bytes = await _downloadImageBytesCached(imageUrl);
    final parts = <Map<String, dynamic>>[
      {'text': _buildAttributeExtractionPrompt(category)},
      {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(bytes)}},
    ];

    final requestBody = {
      'contents': [{'parts': parts}],
      'generationConfig': {
        'temperature': 0.2,
        // thinkingBudget:0으로 추론 단계를 없앴는데도 tags 배열까지 채운
        // 실측 응답이 500 경계에서 닫는 '}' 직전에 잘리는 사례가 확인돼
        // 800으로 여유를 늘렸다.
        'maxOutputTokens': 800,
        'responseMimeType': 'application/json',
        'thinkingConfig': {'thinkingBudget': 0},
      },
    };

    final responseBody =
        await _callProxyText(model: model ?? _textModel, requestBody: requestBody);

    final text = _extractTextFromResponse(responseBody);
    return ClothingAttributes.fromJson(_parseJsonObject(text));
  }

  // ── 사이즈표 사진 한 장 → 특정 사이즈 행의 치수 추출 ──
  // Storage에 업로드된 옷 사진이 아니라 사용자가 그 자리에서 찍은/고른
  // 사이즈표 사진의 바이트를 바로 받는다 — 저장할 필요 없는 1회성 OCR
  // 입력이라 URL 다운로드 경로(_downloadImageBytesCached)를 타지 않는다.
  static Future<ClothingSize> extractSizeFromChart({
    required Uint8List imageBytes,
    required String category,
    required String sizeLabel,
    String? model,
  }) async {
    final stopwatch = Stopwatch()..start();
    // 원본(종종 3000px대) 그대로 보내면 업로드+처리 시간이 1분을 넘기는
    // 경우가 확인돼, OCR 전송본만 1280px로 축소한다(원본 imageBytes는
    // 호출부에서 저장하지 않으므로 여기서만 축소해도 무방).
    final resizedBytes = await compute(_resizeForOcr, imageBytes);
    debugPrint(
        '[TIMING] extractSizeFromChart resize: ${imageBytes.length}B -> '
        '${resizedBytes.length}B in ${stopwatch.elapsedMilliseconds}ms');

    final parts = <Map<String, dynamic>>[
      {'text': _buildSizeChartExtractionPrompt(category: category, sizeLabel: sizeLabel)},
      {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(resizedBytes)}},
    ];

    final requestBody = {
      'contents': [{'parts': parts}],
      'generationConfig': {
        'temperature': 0.1,
        // extractAttributes와 동일한 이유(500 경계 잘림 확인)로 800으로 늘림.
        'maxOutputTokens': 800,
        'responseMimeType': 'application/json',
        // extractAttributes와 동일한 이유로 thinking을 꺼서 예산이
        // JSON 출력 전에 잘려나가는 것을 방지한다.
        'thinkingConfig': {'thinkingBudget': 0},
      },
    };

    final responseBody =
        await _callProxyText(model: model ?? _textModel, requestBody: requestBody);

    final text = _extractTextFromResponse(responseBody);
    final result = ClothingSize.fromJson(_parseJsonObject(text));
    debugPrint(
        '[TIMING] extractSizeFromChart total: ${stopwatch.elapsedMilliseconds}ms');
    return result;
  }

  // compute()로 별도 isolate에서 돌려 디코딩/인코딩이 메인 스레드를
  // 막지 않게 한다. 긴 변이 1280px를 넘을 때만 축소하고(작은 숫자가
  // 안 읽히지 않도록 1024px 밑으로는 절대 내리지 않음), JPEG 82%로
  // 압축해 업로드 바이트를 줄인다.
  static Uint8List _resizeForOcr(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    const maxDimension = 1280;
    final isLandscape = decoded.width >= decoded.height;
    final longestSide = isLandscape ? decoded.width : decoded.height;

    final resized = longestSide > maxDimension
        ? img.copyResize(
            decoded,
            width: isLandscape ? maxDimension : null,
            height: isLandscape ? null : maxDimension,
            interpolation: img.Interpolation.average,
          )
        : decoded;

    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  }

  static String _buildSizeChartExtractionPrompt({
    required String category,
    required String sizeLabel,
  }) {
    final fields = category == '하의'
        ? '"waistWidth": 허리단면(cm), "hipWidth": 엉덩이단면(cm), "thighWidth": 허벅지단면(cm), "pantsLength": 총장(cm)'
        : '"totalLength": 총장(cm), "shoulderWidth": 어깨너비(cm), "chestWidth": 가슴단면(cm), "sleeveLength": 소매길이(cm)';
    return '''
아래는 의류 사이즈표 이미지입니다. 이 표에서 사이즈가 정확히 "$sizeLabel"인 행 하나만 찾아
그 행의 치수 숫자만 JSON으로 추출하세요. 다른 사이즈 행의 값을 섞어 쓰지 마세요.
숫자를 읽는 것 외에 어떤 판단이나 설명, 핏 평가도 하지 마세요.
표에 "$sizeLabel" 사이즈가 없거나 특정 항목을 읽을 수 없으면 해당 값은 null로 두세요.
단위가 cm가 아니라 인치 등으로 표기되어 있다면 cm로 환산해서 반환하세요.

응답은 반드시 '{' 문자로 즉시 시작해야 합니다. "Here is the JSON" 같은 설명 문구,
마크다운, 코드블록을 절대 앞에 붙이지 마세요. 순수 JSON 객체만 출력하세요.

형식: {$fields}
''';
  }

  // responseMimeType: application/json을 지정해도 모델이 종종
  // "Here is the JSON requested: {...}" 처럼 설명을 앞에 붙이거나
  // 마크다운 코드블록으로 감싸는 경우가 있어, 첫 '{'~마지막 '}' 구간만
  // 추출해 안전하게 파싱한다.
  static Map<String, dynamic> _parseJsonObject(String text) {
    var cleaned = text.trim();
    cleaned = cleaned
        .replaceAll(RegExp(r'```json\s*'), '')
        .replaceAll(RegExp(r'```\s*'), '');
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) {
      throw FormatException('응답에서 JSON 객체를 찾을 수 없습니다: $text');
    }
    return jsonDecode(cleaned.substring(start, end + 1)) as Map<String, dynamic>;
  }

  // ── 코디 텍스트 분석 (옷 이미지 대신 캐싱된 속성 텍스트로 매칭 평가) ──
  static Future<String> analyzeOutfitFromAttributes({
    required List<({String category, ClothingAttributes attributes})> items,
    String? userPhotoUrl,
    UserProfile? userProfile,
    String? recentHistoryText,
    // true면 recentHistoryText가 relevance 기반으로 뽑힌 것 — 이력 섹션
    // 헤더가 "관련 코디 이력(상황·아이템 기준 검색됨)"으로 바뀐다. false(기본,
    // 관련 신호 없어 최신순 폴백된 경우 포함)면 기존 "최근 코디 이력" 헤더.
    bool isRelevanceRanked = false,
    String? model,
  }) async {
    // 옷 이미지는 더 이상 보내지 않는다 — 등록 시점에 뽑아둔 색상/스타일/
    // 패턴/격식/핏/태그 텍스트만으로 매칭을 평가하므로 입력이 훨씬 가볍다.
    // 사용자 체형 프로필이 입력되어 있으면 그 텍스트가 사진보다 정확하고
    // 훨씬 빠르므로 우선하고, 이 경우 전신 사진은 아예 보내지 않는다.
    final hasProfile = userProfile != null && userProfile.hasAnyData;

    final imageParts = <Map<String, dynamic>>[];
    if (!hasProfile && userPhotoUrl != null) {
      final bytes = await _downloadImageBytesCached(userPhotoUrl);
      imageParts.add({
        'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(bytes)}
      });
    }

    final prompt = hasProfile
        ? _buildAttributeAnalysisPromptWithProfile(items, userProfile,
            recentHistoryText: recentHistoryText, isRelevanceRanked: isRelevanceRanked)
        : (userPhotoUrl != null
            ? _buildAttributeAnalysisPromptWithPhoto(items,
                recentHistoryText: recentHistoryText, isRelevanceRanked: isRelevanceRanked)
            : _buildAttributeAnalysisPrompt(items,
                recentHistoryText: recentHistoryText, isRelevanceRanked: isRelevanceRanked));
    _debugLogHistoryInclusion(prompt, recentHistoryText);

    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      ...imageParts,
    ];

    // maxOutputTokens는 thinking(추론) 토큰과 같은 예산을 공유한다.
    // 스타일링 조언은 어느 정도 추론이 품질에 도움이 되므로 thinking은
    // 끄지 않되, 실제 답변이 잘리지 않도록 예산을 넉넉히 둔다.
    final requestBody = {
      'contents': [{'parts': parts}],
      'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 3000},
    };

    final responseBody =
        await _callProxyText(model: model ?? _textModel, requestBody: requestBody);

    return _extractTextFromResponse(responseBody);
  }

  // ── 주간 코디 플랜 (여러 날 일정을 한 번에 계획) ──────────
  // 개별 코디 분석과 달리 "여러 날에 걸친 배분"이 핵심이라 날짜별로 나눠
  // 부르지 않고 한 번의 호출로 전체 플랜을 받는다(중복 회피·격식 배분 같은
  // 제약은 날짜들을 동시에 봐야 지킬 수 있다). 응답은 JSON 배열 텍스트로
  // 반환하고, 파싱/검증은 호출부(AgentPlanner)가 맡는다.
  //
  // scheduleLines: "1. 2026-07-14 (월) — 출근 — 요구 격식: 세미포멀" 형태의 줄들.
  // wardrobeCatalog: "- id=xxx | 상의 | 네이비/캐주얼/무지" 형태의 줄들.
  static Future<String> planWeeklyOutfits({
    required String scheduleLines,
    required String wardrobeCatalog,
    String? recentFeedbackText, // 최근 불일치 피드백(취향 반영용, 있을 때만)
    String? model,
  }) async {
    final feedbackSection = (recentFeedbackText == null || recentFeedbackText.isEmpty)
        ? ''
        : '\n[취향 피드백 - 반영하세요]\n$recentFeedbackText\n';
    final prompt = '''
당신은 전문 패션 스타일리스트입니다. 아래 옷장 아이템만 사용해 요청된 날짜별 코디를 계획하세요.

[옷장 아이템] (반드시 이 id만 사용, 목록에 없는 id는 절대 만들지 마세요)
$wardrobeCatalog

[계획할 날짜]
$scheduleLines
$feedbackSection
[제약 조건 - 반드시 지키세요]
- 각 날짜에 상의 1개 + 하의 1개를 기본으로 배정하고, 필요하면 아우터/신발을 더하세요.
- 같은 상의 또는 같은 하의를 이틀 연속 배치하지 마세요(중복 회피).
- 격식이 높은 조합(포멀/세미포멀 아이템)은 출근·데이트·모임처럼 격식이 필요한 날에 우선 배분하세요.
- 어떤 날짜에 그 격식에 딱 맞는 아이템이 옷장에 없더라도 그 날을 건너뛰지 말고, 가장 가까운 차선 조합을 배정한 뒤 reason에 "딱 맞는 조합이 없어 가장 가까운 조합"임을 밝히세요.
- itemIds는 위 옷장에 실제로 존재하는 id만 사용하세요.

[출력 형식 - 반드시 지키세요]
순수 JSON 배열만 출력하세요. 설명 문구·마크다운·코드블록을 절대 붙이지 마세요. 응답의 첫 문자는 '[' 여야 합니다.
각 원소는 {"date":"YYYY-MM-DD","itemIds":["id1","id2"],"reason":"한 줄 이유(한국어)"} 형식입니다.
''';

    final requestBody = {
      'contents': [
        {'parts': [{'text': prompt}]}
      ],
      'generationConfig': {
        // 계획은 창의성보다 제약 준수가 중요하므로 온도를 낮춘다.
        'temperature': 0.4,
        'maxOutputTokens': 2000,
        'responseMimeType': 'application/json',
        // 다른 JSON 호출과 동일하게 thinking 예산을 꺼서 출력이 잘리지 않게 한다.
        'thinkingConfig': {'thinkingBudget': 0},
      },
    };

    final responseBody =
        await _callProxyText(model: model ?? _textModel, requestBody: requestBody);

    return _extractTextFromResponse(responseBody);
  }

  // ── 코디 텍스트 분석 (스트리밍) ──────────────────────────
  // analyzeOutfitFromAttributes와 프롬프트/설정은 동일하되, SSE로 델타
  // 텍스트를 그때그때 yield해 화면에 점진적으로 표시할 수 있게 한다.
  static Stream<String> analyzeOutfitFromAttributesStream({
    required List<({String category, ClothingAttributes attributes})> items,
    String? userPhotoUrl,
    UserProfile? userProfile,
    String? recentHistoryText,
    bool isRelevanceRanked = false,
    String? model,
  }) async* {
    final hasProfile = userProfile != null && userProfile.hasAnyData;

    final imageParts = <Map<String, dynamic>>[];
    if (!hasProfile && userPhotoUrl != null) {
      final bytes = await _downloadImageBytesCached(userPhotoUrl);
      imageParts.add({
        'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(bytes)}
      });
    }

    final prompt = hasProfile
        ? _buildAttributeAnalysisPromptWithProfile(items, userProfile,
            recentHistoryText: recentHistoryText, isRelevanceRanked: isRelevanceRanked)
        : (userPhotoUrl != null
            ? _buildAttributeAnalysisPromptWithPhoto(items,
                recentHistoryText: recentHistoryText, isRelevanceRanked: isRelevanceRanked)
            : _buildAttributeAnalysisPrompt(items,
                recentHistoryText: recentHistoryText, isRelevanceRanked: isRelevanceRanked));
    _debugLogHistoryInclusion(prompt, recentHistoryText);

    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      ...imageParts,
    ];

    final requestBody = {
      'contents': [{'parts': parts}],
      'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 3000},
    };

    yield* _callProxyTextStream(model: model ?? _textModel, requestBody: requestBody);
  }

  // ── 내부 공통 유틸 ─────────────────────────────────────────
  static Future<Uint8List> _downloadImageBytes(String url) async {
    final response = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('이미지 다운로드 실패 (${response.statusCode})');
    }
    return response.bodyBytes;
  }

  static Future<Uint8List> _downloadImageBytesCached(String url) async {
    final cached = _imageCache[url];
    if (cached != null) return cached;
    final bytes = await _downloadImageBytes(url);
    _imageCache[url] = bytes;
    return bytes;
  }

  static String _extractTextFromResponse(String body) {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Gemini 응답이 비어 있습니다. 다시 시도해 주세요.');
    }
    final content = (candidates[0] as Map)['content'] as Map?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('응답에서 텍스트를 찾을 수 없습니다.');
    }
    final text = (parts[0] as Map)['text'] as String?;
    if (text == null || text.trim().isEmpty) {
      throw Exception('분석 결과를 가져오지 못했습니다.');
    }
    return text.trim();
  }

  static Uint8List _extractImageFromResponse(String responseBody) {
    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Gemini에서 응답이 없습니다. 다시 시도해주세요.');
    }
    final content = (candidates[0] as Map)['content'] as Map?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('Gemini 응답에 이미지가 포함되지 않았습니다.');
    }
    for (final part in parts) {
      final inlineData = (part as Map)['inlineData'] as Map?;
      if (inlineData != null) {
        final imageData = inlineData['data'] as String?;
        if (imageData != null && imageData.isNotEmpty) {
          return base64Decode(imageData);
        }
      }
    }
    throw Exception('합성 이미지를 생성하지 못했습니다. 다른 옷이나 사진으로 다시 시도해주세요.');
  }

  static String _buildFittingPrompt(List<String> clothingNames) {
    final clothingList = clothingNames.map((n) => '- $n').join('\n');
    return '''
첫 번째 사진의 사람에게 이후 사진에 있는 옷을 입혀서 자연스러운 합성 이미지를 만들어주세요.

착용할 옷:
$clothingList

생성 규칙:
- 첫 번째 사진 속 사람의 얼굴, 체형, 피부톤, 헤어스타일을 그대로 유지해주세요
- 제공된 옷 이미지의 옷을 그 사람에게 자연스럽게 입혀주세요
- 전신이 보이도록 해주세요
- 자연스러운 포즈와 배경을 유지해주세요
- 실제로 그 옷을 입은 것처럼 사실적으로 표현해주세요
''';
  }

  static String _buildAttributeExtractionPrompt(String category) {
    return '''
아래 옷 사진 한 장을 분석해서 JSON 객체 하나만 출력하세요.
응답은 반드시 '{' 문자로 즉시 시작해야 합니다. "Here is the JSON" 같은 설명 문구,
마크다운, 코드블록을 절대 앞에 붙이지 마세요. 순수 JSON 객체만 출력하세요.
이 옷의 카테고리는 "$category"입니다.

형식:
{"color": "주요 색상 (한 단어, 예: 네이비)", "style": "스타일 (한 단어, 예: 캐주얼/포멀/스트릿/미니멀/스포티)", "pattern": "패턴 (한 단어, 예: 무지/스트라이프/체크/도트/그래픽)", "formality": "격식 정도 (한 단어, 예: 캐주얼/세미포멀/포멀)", "fit": "핏 (한 단어, 예: 슬림/레귤러/오버사이즈)", "tags": ["소재나 계절 등 추가 특징 키워드 2~4개"]}
''';
  }

  static String _itemsToPromptLines(
    List<({String category, ClothingAttributes attributes})> items,
  ) {
    return items
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value.category}: ${e.value.attributes.toPromptLine()}')
        .join('\n');
  }

  // 코디 이력을 프롬프트에 끼워 넣을 섹션 텍스트로 감싼다. 이력이 없으면
  // (신규 사용자, 조회 실패 등) 빈 문자열을 반환해 기존 프롬프트 형식(섹션
  // 없이 빈 줄 하나)이 그대로 유지되게 한다. isRelevanceRanked가 true면
  // relevance 기반으로 뽑힌 것이므로 헤더로 그 사실을 정직하게 밝힌다(관련
  // 신호가 없어 최신순으로 폴백된 경우는 false로 넘어와 기존 헤더를 쓴다).
  static String _buildHistorySection(String? recentHistoryText,
      {bool isRelevanceRanked = false}) {
    if (recentHistoryText == null || recentHistoryText.isEmpty) return '';
    final header = isRelevanceRanked
        ? '관련 코디 이력(상황·아이템 기준 검색됨 — 취향 파악에 참고하되 그대로 반복 추천하지는 마세요)'
        : '최근 코디 이력(참고용 — 사용자가 과거에 시도했던 조합입니다. 취향 파악에 참고하되 그대로 반복 추천하지는 마세요)';
    return '\n$header:\n$recentHistoryText\n';
  }

  // 이력 섹션이 실제로 최종 프롬프트 문자열에 포함됐는지 눈으로 바로
  // 확인할 수 있도록 남기는 디버그 로그. recentHistoryText가 없으면 조용히 스킵.
  static void _debugLogHistoryInclusion(String prompt, String? recentHistoryText) {
    if (recentHistoryText == null || recentHistoryText.isEmpty) return;
    final included = prompt.contains(recentHistoryText);
    debugPrint('[HISTORY] 프롬프트에 최근 이력 포함 여부: $included');
    debugPrint('[HISTORY] 삽입된 텍스트:\n$recentHistoryText');
  }

  static String _buildAttributeAnalysisPromptWithPhoto(
    List<({String category, ClothingAttributes attributes})> items, {
    String? recentHistoryText,
    bool isRelevanceRanked = false,
  }) {
    final itemLines = _itemsToPromptLines(items);
    final historySection =
        _buildHistorySection(recentHistoryText, isRelevanceRanked: isRelevanceRanked);
    return '''
당신은 전문 패션 스타일리스트입니다.

[핵심 지침 - 반드시 준수하세요]
첫 번째 이미지는 착용자의 체형, 피부톤, 얼굴형, 전체적인 분위기를 파악하기 위한 참고 사진입니다.
절대로 첫 번째 사진 속 인물이 현재 입고 있는 옷에 대해 분석하거나 언급하지 마세요.
분석 대상은 아래 텍스트로 설명된 의류들입니다. 실제 이미지는 첨부되지 않았으니 아래 설명만으로 판단해 주세요.

$itemLines
$historySection
이 의류들을 첫 번째 사진 착용자가 입었을 때 얼마나 잘 어울릴지, 가상 피팅 관점에서 평가해 주세요.

아래 형식으로 정확히 답변해 주세요.

[점수] (현재 코디의 컬러 조합을 1~100점으로 평가한 숫자만 입력)
[분위기점수] (이 조합이 이 착용자에게 얼마나 잘 어울리는 분위기를 연출하는지 1~100점)
[분위기] (아래 목록 중 이 코디와 가장 가까운 분위기를 하나만 정확히 골라 적어 주세요: 캐주얼, 포멀, 스트리트, 미니멀, 러블리, 스포티, 빈티지, 시크)

1. 스타일링 팁: 전체 코디를 더욱 완성도 있게 만들 액세서리나 추가 아이템을 1~2가지 제안해 주세요.
2. 다른 색상 추천: 현재 선택한 의류와 동일한 스타일이지만 더 높은 컬러 조합 점수를 받을 수 있는 색상 조합을 40자 이내의 한 문장으로 짧게 추천해 주세요.

[출력 형식 규칙 - 반드시 준수하세요]
응답의 첫 세 줄은 반드시 아래 순서와 형식으로 시작해 주세요. 예시:
[점수] 78
[분위기점수] 85
[분위기] 캐주얼
별표(*), 샵(#), 대시(-) 등 어떠한 마크다운 기호도 절대 사용하지 마세요.
이모지나 특수문자도 사용하지 마세요.
1. 2. 숫자 번호와 일반 텍스트로만 깔끔하게 답변해 주세요.
전체 답변은 각 항목당 지정된 문장 수를 넘기지 말고 간결하게 작성해 주세요.
다른 색상 추천 항목은 반드시 40자를 넘기지 마세요.
''';
  }

  static String _buildAttributeAnalysisPromptWithProfile(
    List<({String category, ClothingAttributes attributes})> items,
    UserProfile profile, {
    String? recentHistoryText,
    bool isRelevanceRanked = false,
  }) {
    final itemLines = _itemsToPromptLines(items);
    final historySection =
        _buildHistorySection(recentHistoryText, isRelevanceRanked: isRelevanceRanked);
    return '''
당신은 전문 패션 스타일리스트입니다.

착용자 정보(사용자가 직접 입력): ${profile.toPromptLine()}

분석 대상은 아래 텍스트로 설명된 의류들입니다.

$itemLines
$historySection
위 착용자 정보를 참고해서, 이 의류들이 착용자에게 얼마나 잘 어울릴지 평가해 주세요.

아래 형식으로 정확히 답변해 주세요.

[점수] (현재 코디의 컬러 조합을 1~100점으로 평가한 숫자만 입력)
[분위기점수] (이 조합이 착용자 정보에 얼마나 잘 어울리는 분위기를 연출하는지 1~100점)
[분위기] (아래 목록 중 이 코디와 가장 가까운 분위기를 하나만 정확히 골라 적어 주세요: 캐주얼, 포멀, 스트리트, 미니멀, 러블리, 스포티, 빈티지, 시크)

1. 스타일링 팁: 전체 코디를 더욱 완성도 있게 만들 액세서리나 추가 아이템을 1~2가지 제안해 주세요.
2. 다른 색상 추천: 현재 선택한 의류와 동일한 스타일이지만 더 높은 컬러 조합 점수를 받을 수 있는 색상 조합을 40자 이내의 한 문장으로 짧게 추천해 주세요.

[출력 형식 규칙 - 반드시 준수하세요]
응답의 첫 세 줄은 반드시 아래 순서와 형식으로 시작해 주세요. 예시:
[점수] 78
[분위기점수] 85
[분위기] 캐주얼
별표(*), 샵(#), 대시(-) 등 어떠한 마크다운 기호도 절대 사용하지 마세요.
이모지나 특수문자도 사용하지 마세요.
1. 2. 숫자 번호와 일반 텍스트로만 깔끔하게 답변해 주세요.
전체 답변은 각 항목당 지정된 문장 수를 넘기지 말고 간결하게 작성해 주세요.
다른 색상 추천 항목은 반드시 40자를 넘기지 마세요.
''';
  }

  // 자기 평가 루프(OutfitSelfEvaluator) 전용 프롬프트 — 사진/프로필 버전과
  // 달리 여기만 다축 평가 형식([총점]/[격식적합]/[색상조화]/[스타일통일]/
  // [개선점])을 요청한다. 진단-수리 루프가 [개선점]과 축 점수로 어떤
  // 아이템이 문제인지 찾아 교체를 시도할 재료가 된다.
  static String _buildAttributeAnalysisPrompt(
    List<({String category, ClothingAttributes attributes})> items, {
    String? recentHistoryText,
    bool isRelevanceRanked = false,
  }) {
    final itemLines = _itemsToPromptLines(items);
    final historySection =
        _buildHistorySection(recentHistoryText, isRelevanceRanked: isRelevanceRanked);
    return '''
당신은 전문 패션 스타일리스트입니다.
아래에 텍스트로 설명된 의류 조합을 보고, 컬러 조합을 점수로 평가하고 코디 분석 및 다른 색상 추천을 해 주세요. 실제 이미지는 첨부되지 않았으니 아래 설명만으로 판단해 주세요.

$itemLines
$historySection
아래 형식으로 정확히 답변해 주세요.

색상 평가 시 참고: 무채색(화이트/블랙/네이비/그레이/베이지 등)은 어떤 색과도
무난하게 어울립니다. 유채색은 조합 안에 3개를 넘지 않는 편이 안정적입니다.
같은 색 계열이면 명도 차이를 준 것을(톤온톤), 다른 색 계열이면 명도를 맞춘
것을(톤인톤) 좋게 보고, 그 외에는 색상환상 관계를 참고해 판단하세요. 채도나
소재 느낌처럼 텍스트만으로 판단하기 애매한 부분은 스타일리스트로서 자유롭게
평가하세요.

[총점] (이 코디 조합의 전체 완성도를 1~100점으로 평가한 숫자만 입력)
[격식적합] (조합 내 아이템들의 격식이 서로 얼마나 잘 맞는지 1~100점)
[색상조화] (색상 조합이 얼마나 잘 어울리는지 1~100점)
[스타일통일] (스타일이 통일감 있게 어울리는지 1~100점)
[개선점] (총점이 낮다면 어떤 아이템(카테고리)이 문제인지 한 줄로 짚어주세요. 문제가 없다면 "없음"이라고만 적으세요)

1. 코디 분위기: 이 의류 조합이 연출하는 전반적인 스타일과 분위기를 2~3문장으로 설명해 주세요.
2. 신발 추천: 이 코디에 가장 잘 어울리는 신발을 종류와 색상을 포함해 2가지 추천해 주세요.
3. 스타일링 팁: 전체 코디를 더욱 완성도 있게 만들 액세서리나 추가 아이템을 1~2가지 제안해 주세요.
4. 다른 색상 추천: 현재 선택한 의류와 동일한 스타일이지만 더 높은 컬러 조합 점수를 받을 수 있는 색상 조합 2가지를 구체적으로 추천해 주세요. 각 추천마다 어떤 색상으로 바꾸면 좋은지, 왜 더 잘 어울리는지 설명해 주세요.

[출력 형식 규칙 - 반드시 준수하세요]
응답의 첫 다섯 줄은 반드시 아래 순서와 형식으로 시작해 주세요. 예시:
[총점] 78
[격식적합] 82
[색상조화] 75
[스타일통일] 80
[개선점] 아우터 색상이 나머지와 부딪힙니다
별표(*), 샵(#), 대시(-) 등 어떠한 마크다운 기호도 절대 사용하지 마세요.
이모지나 특수문자도 사용하지 마세요.
1. 2. 3. 4. 숫자 번호와 일반 텍스트로만 깔끔하게 답변해 주세요.
전체 답변은 각 항목당 지정된 문장 수를 넘기지 말고 간결하게 작성해 주세요.
''';
  }
}
