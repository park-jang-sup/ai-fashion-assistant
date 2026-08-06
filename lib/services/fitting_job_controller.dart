import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/agent_log_entry.dart';
import '../models/clothing_attributes.dart';
import '../models/outfit_history_entry.dart';
import '../models/user_profile.dart';
import '../models/wardrobe_item.dart';
import 'firestore_service.dart';
import 'gemini_api_exception.dart';
import 'gemini_service.dart';
import 'storage_service.dart';

// 화면(State)이 아니라 AppShell 레벨에서 보관되는 컨트롤러.
// 탭을 이동하거나 위젯이 dispose되어도 진행 중인 Future와 그 결과는
// 이 인스턴스에 남아있기 때문에 작업이 끊기지 않는다.
class FittingJobController extends ChangeNotifier {
  bool isAnalyzing = false;
  bool isGeneratingFitting = false;

  String? analysisResult;
  String? analysisError;

  Uint8List? fittingImage;
  String? fittingImageUrl; // 캐시에서 가져온 결과 (Storage URL, bytes 아님)
  // fitting_cache 문서 id(=캐시 키) — fittingImageUrl이 실제 fitting_cache
  // 결과일 때만 채워진다. ImageUrlResolver.resolve(collection:
  // 'fitting_cache', id: fittingCacheKey)에 쓴다(서명 URL 이행 A-4).
  String? fittingCacheKey;
  bool isFittingFromCache = false;
  String? fittingError;

  bool get isBusy => isAnalyzing || isGeneratingFitting;

  Future<void> analyze({
    required List<WardrobeItem> clothingItems,
    required WardrobeItem? userPhoto,
    UserProfile? userProfile,
  }) async {
    // isBusy(분석 OR 피팅)가 아니라 자기 자신의 진행 여부만 본다 — 통합 버튼이
    // analyze()와 generateFitting()을 동시에 실행할 수 있어야 하므로, 서로가
    // 서로를 막으면 안 된다.
    if (isAnalyzing || clothingItems.isEmpty) return;

    isAnalyzing = true;
    analysisResult = null;
    analysisError = null;
    notifyListeners();

    final debugT0 = DateTime.now();
    try {
      // 이력 조회는 속성 준비와 서로 의존하지 않으므로 동시에 시작해 지연을 숨긴다.
      // recency가 아니라 relevance로 뽑는다 — 지금 고른 옷들과 겹치는 과거
      // 추천을 우선한다(태그는 이 화면엔 없으니 생략).
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final candidateItemIds = clothingItems.map((i) => i.id).toList();
      final relevantHistoryFuture = uid != null
          ? FirestoreService.getRelevantHistorySilently(uid, candidateItemIds: candidateItemIds)
          : Future.value(
              (lines: <String>[], tagMatchCount: 0, itemOverlapCount: 0, isFallback: false));

      final itemsWithAttributes = await _resolveAttributes(clothingItems);
      final debugT1 = DateTime.now();
      debugPrint('[TIMING] 1) 속성 준비: ${debugT1.difference(debugT0).inMilliseconds}ms');

      final relevantHistory = await relevantHistoryFuture;
      final recentHistoryText =
          relevantHistory.lines.isEmpty ? null : relevantHistory.lines.join('\n');
      final isRelevanceRanked = !relevantHistory.isFallback;
      final debugT1b = DateTime.now();
      debugPrint('[TIMING] 1b) 이력 조회(속성 준비와 병렬, 순수 대기분): '
          '${debugT1b.difference(debugT1).inMilliseconds}ms');
      debugPrint('[HISTORY] 관련 이력 ${relevantHistory.lines.length}건 조회됨'
          '${recentHistoryText != null ? ' — 프롬프트에 전달:\n$recentHistoryText' : ' (없음, 섹션 생략)'}');

      try {
        final buffer = StringBuffer();
        DateTime? debugFirstChunkAt;
        await for (final chunk in GeminiService.analyzeOutfitFromAttributesStream(
          items: itemsWithAttributes,
          userPhotoId: userPhoto?.id,
          userPhotoUrl: userPhoto?.imageUrl,
          userProfile: userProfile,
          recentHistoryText: recentHistoryText,
          isRelevanceRanked: isRelevanceRanked,
        )) {
          debugFirstChunkAt ??= DateTime.now();
          buffer.write(chunk);
          analysisResult = buffer.toString();
          notifyListeners();
        }
        final debugT2 = DateTime.now();
        debugPrint('[TIMING] 2) 첫 응답까지(순수 Gemini 네트워크): '
            '${(debugFirstChunkAt ?? debugT2).difference(debugT1b).inMilliseconds}ms');
        debugPrint('[TIMING] 3) 전체 생성 완료: '
            '${debugT2.difference(debugT1b).inMilliseconds}ms '
            '(총합 ${debugT2.difference(debugT0).inMilliseconds}ms)');
        if (buffer.isEmpty) throw Exception('스트리밍 응답이 비어 있습니다.');
      } catch (e) {
        // 스트리밍이 중간에 끊기거나 실패하면 부분 텍스트는 버리고
        // 기존의 안정적인 전체 호출 + 재시도 경로로 폴백한다.
        debugPrint('[STREAM-FALLBACK] 스트리밍 실패, 원인: $e');
        analysisResult = null;
        notifyListeners();
        analysisResult = await GeminiService.withTextModelFallback(
          (model) => GeminiService.analyzeOutfitFromAttributes(
            items: itemsWithAttributes,
            userPhotoId: userPhoto?.id,
            userPhotoUrl: userPhoto?.imageUrl,
            userProfile: userProfile,
            recentHistoryText: recentHistoryText,
            isRelevanceRanked: isRelevanceRanked,
            model: model,
          ),
        );
      }
      _logAnalysisHistorySilently(clothingItems, itemsWithAttributes, analysisResult);
    } catch (e) {
      analysisError = e.toString();
    } finally {
      isAnalyzing = false;
      notifyListeners();
    }
  }

  // 분석 결과 텍스트에서 "[점수] N" 줄을 찾아 점수를 뽑는다.
  // fitting_room_screen.dart의 표시용 파서와 별개로, 이력 기록 전용으로 둔다.
  static int? _parseScore(String? text) {
    if (text == null) return null;
    final match = RegExp(r'\[점수\]\s*(\d+)').firstMatch(text);
    if (match == null) return null;
    final score = int.tryParse(match.group(1) ?? '');
    return score?.clamp(1, 100);
  }

  static void _logAnalysisHistorySilently(
    List<WardrobeItem> clothingItems,
    List<({String category, ClothingAttributes attributes})> itemsWithAttributes,
    String? analysisResult,
  ) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snapshots = List.generate(clothingItems.length, (i) {
      final resolved = itemsWithAttributes[i];
      return HistoryItemSnapshot(
        id: clothingItems[i].id,
        category: resolved.category,
        color: resolved.attributes.color,
        style: resolved.attributes.style,
        formality: resolved.attributes.formality,
      );
    });
    final score = _parseScore(analysisResult);
    unawaited(FirestoreService.addHistoryEntrySilently(
      uid,
      OutfitHistoryEntry(
        type: OutfitHistoryEntry.typeAnalysis,
        items: snapshots,
        score: score,
      ),
    ));
    unawaited(FirestoreService.addAgentLogSilently(
      uid,
      AgentLogEntry(
        id: '',
        eventType: AgentLogEntry.typeAnalysisCompleted,
        message: score != null ? '코디 분석을 완료했습니다 ($score점)' : '코디 분석을 완료했습니다',
      ),
    ));
  }

  // 등록 시점에 이미 속성이 캐싱된 아이템은 그대로 쓰고, 아직 없는
  // 레거시 아이템만 병렬로 추출한 뒤 다음 번을 위해 Firestore에 백필한다.
  // 추출 호출 자체도 타임아웃/일시적 오류에 재시도를 적용한다.
  static Future<List<({String category, ClothingAttributes attributes})>>
      _resolveAttributes(List<WardrobeItem> items) {
    return Future.wait(items.map((item) async {
      final cached = item.attributes;
      if (cached != null) return (category: item.category, attributes: cached);

      final extracted = await GeminiService.withTextModelFallback(
        (model) => GeminiService.extractAttributes(
          itemId: item.id,
          imageUrl: item.imageUrl,
          category: item.category,
          model: model,
        ),
      );
      unawaited(FirestoreService.updateWardrobeAttributes(item.id, extracted));
      return (category: item.category, attributes: extracted);
    }));
  }

  // 응답 생성이 일시적으로 느려 타임아웃났거나, Gemini가 일시적으로
  // 과부하(503)·요청 급증(429) 상태인 경우 곧바로 실패시키지 않고
  // 한 번 더 시도해본다. 두 번째도 같은 상황이면 그대로 실패로 처리한다.
  static Future<T> _withRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on TimeoutException {
      return await action();
    } on GeminiApiException catch (e) {
      if (!e.isRetryable) rethrow;
      return await action();
    }
  }

  Future<void> generateFitting({
    required WardrobeItem userPhoto,
    required List<WardrobeItem> clothingItems,
    bool forceRegenerate = false,
  }) async {
    // analyze()와 동일한 이유로 자기 자신의 진행 여부만 본다.
    if (isGeneratingFitting || clothingItems.isEmpty) return;

    isGeneratingFitting = true;
    fittingImage = null;
    fittingImageUrl = null;
    fittingCacheKey = null;
    isFittingFromCache = false;
    fittingError = null;
    notifyListeners();

    try {
      final cacheKey = _buildFittingCacheKey(userPhoto, clothingItems);

      if (!forceRegenerate) {
        final cachedUrl = await _getCachedFittingImageUrlSilently(cacheKey);
        if (cachedUrl != null) {
          fittingImageUrl = cachedUrl;
          fittingCacheKey = cacheKey;
          isFittingFromCache = true;
          _logFittingHistorySilently(clothingItems, cachedUrl, cacheKey);
          return;
        }
      }

      final bytes = await _withRetry(
        () => GeminiService.generateFittingImage(
          userPhotoId: userPhoto.id,
          userPhotoUrl: userPhoto.imageUrl,
          clothingItemIds: clothingItems.map((i) => i.id).toList(),
          clothingImageUrls: clothingItems.map((i) => i.imageUrl).toList(),
          clothingNames: clothingItems.map((i) => i.category).toList(),
        ),
      );
      fittingImage = bytes;

      // 캐시 저장은 이미 화면에 이미지가 표시된 뒤의 부가 작업이라
      // 실패해도 조용히 무시한다 (_resolveAttributes의 백필과 동일 패턴).
      // 히스토리에 남길 URL은 이 업로드가 끝나야만 생기므로, 로깅도
      // 함께 그 성공 콜백 안에서 처리한다(실패하면 URL이 없으니 로깅도 스킵).
      unawaited(_cacheFittingResultSilently(cacheKey, bytes, clothingItems));
    } catch (e) {
      fittingError = e.toString();
    } finally {
      isGeneratingFitting = false;
      notifyListeners();
    }
  }

  // 사용자 사진 ID + 정렬된 옷 ID들을 합쳐 SHA-256 해시로 만든다.
  // 옷 선택 순서가 달라도(하의→상의 vs 상의→하의) 같은 조합이면 같은 키가 나오도록
  // 정렬을 거친다.
  static String _buildFittingCacheKey(
    WardrobeItem userPhoto,
    List<WardrobeItem> clothingItems,
  ) {
    final sortedClothingIds = clothingItems.map((i) => i.id).toList()..sort();
    final raw = '${userPhoto.id}:${sortedClothingIds.join(',')}';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  // 인스턴스 메서드다(static 아님) — 업로드가 끝나야만 알 수 있는 URL을
  // fittingImageUrl에 반영하고 리스너에게 알려야 스크랩 등 URL이 필요한
  // 기능이 신규 생성 결과에도 동작한다(기존엔 캐시 히트 때만 채워졌었다).
  // [C-4b] 이 URL의 유효 범위는 storage_service.dart 주석 참고 — 업로드
  // 직후 서버 트리거가 토큰을 회수하기 전까지만 유효한 잔여물이다.
  Future<void> _cacheFittingResultSilently(
    String cacheKey,
    Uint8List bytes,
    List<WardrobeItem> clothingItems,
  ) async {
    try {
      // fitting_cache의 경로는 문서 id(=cacheKey) 자체에서 결정론적으로
      // 나온다(signed_url_policy.ts와 동일 규칙) — path 필드를 따로
      // 저장할 필요가 없어 .url만 쓴다.
      final imageUrl = (await StorageService.uploadFittingResult(bytes, cacheKey)).url;
      // fitting_cache의 create 규칙이 ownerUid == request.auth.uid를 요구한다.
      // uid가 없으면 캐시 문서 저장만 건너뛴다(폴백 = 아무것도 하지 않음) —
      // 방금 만든 이미지는 fittingImageUrl로는 계속 반영되어 화면·스크랩에 쓰인다.
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await FirestoreService.cacheFittingResult(cacheKey, imageUrl, uid);
        // fitting_cache 문서가 실제로 쓰였을 때만 채운다 — 아니면 서명
        // 대상 문서가 없어 ImageUrlResolver가 매번 not-found 폴백만 반복한다.
        fittingCacheKey = cacheKey;
      }
      fittingImageUrl = imageUrl;
      notifyListeners();
      // fittingCacheKey(인스턴스 필드)는 방금 위에서 uid != null일 때만
      // 채워졌다 — fitting_cache 문서가 실제로 쓰였을 때만 이력에도
      // 같이 남긴다(그래야 나중에 서명 대상 문서가 확실히 존재한다).
      _logFittingHistorySilently(clothingItems, imageUrl, fittingCacheKey);
    } catch (e) {
      // 캐시 저장 실패는 무시 — 사용자에게는 이미 방금 생성된 이미지가 표시된 상태다.
      debugPrint('[피팅캐시저장] 실패: $e');
    }
  }

  // 캐시 조회는 어디까지나 최적화이므로, 권한/네트워크 문제로 실패해도
  // 캐시 미스로 취급하고 정상 생성 경로로 넘어간다 — 여기서 예외가 새어나가면
  // 캐시 기능 하나 때문에 가상 피팅 자체가 실패해버린다.
  static Future<String?> _getCachedFittingImageUrlSilently(String cacheKey) async {
    try {
      return await FirestoreService.getCachedFittingImageUrl(cacheKey);
    } catch (e) {
      debugPrint('[피팅캐시조회] 실패: $e');
      return null;
    }
  }

  // 캐시 히트/신규 생성 여부와 무관하게, 사용자가 실제로 받아본 가상 피팅
  // 조합은 전부 이력에 남긴다. 결과 이미지 URL이 반드시 있어야 홈 화면
  // "최근 착장" 섹션에 노출될 수 있으므로 필수 인자로 받는다.
  static void _logFittingHistorySilently(
    List<WardrobeItem> clothingItems,
    String fittingImageUrl,
    String? fittingCacheKey,
  ) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    unawaited(FirestoreService.addHistoryEntrySilently(
      uid,
      OutfitHistoryEntry(
        type: OutfitHistoryEntry.typeFitting,
        items: clothingItems.map(HistoryItemSnapshot.fromWardrobeItem).toList(),
        fittingImageUrl: fittingImageUrl,
        fittingCacheKey: fittingCacheKey,
      ),
    ));
    unawaited(FirestoreService.addAgentLogSilently(
      uid,
      AgentLogEntry(
        id: '',
        eventType: AgentLogEntry.typeFittingGenerated,
        message: '가상 피팅 이미지를 생성했습니다',
      ),
    ));
  }
}
