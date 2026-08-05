import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

// 서명 URL 이행 A-3(docs/task_signed_urls_v1.md) — 화면은 이 클래스를
// 거쳐서만 서명 URL을 받는다(A-4에서 배선). GeminiService/StorageService와
// 같은 static-only 서비스 패턴을 따른다.
//
// 배치 발급(prefetch) + docId 키 메모리 캐시 + 만료 80% 시점 갱신 + 실패
// 시 null 반환(호출부가 기존 URL 필드로 폴백, §3-3). 서명 URL은 어디에도
// 영속화하지 않는다 — 이 캐시는 앱 프로세스가 살아있는 동안만 유효하고,
// 콜드스타트마다 비어서 다시 채워진다.
class ImageUrlResolver {
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-northeast3');

  static final Map<String, _CacheEntry> _cache = {};

  // 계측(§5) — Firestore에 영속화하지 않고 프로세스 수명 동안의 인메모리
  // 카운터만 둔다(v1 범위). 관문 A는 이 값을 읽어 "폴백 발화 0"을 확인한다.
  static int cacheHitCount = 0;
  static int cacheMissCount = 0;
  static int fallbackCount = 0;

  // 서버(1회 콜) 배치 상한과 동일 — signed_url_policy.ts의 MAX_BATCH_SIZE.
  static const int _maxBatchSize = 200;

  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    cacheHitCount = 0;
    cacheMissCount = 0;
    fallbackCount = 0;
  }

  // 화면 진입 시(예: 옷장 119벌) 여러 문서의 URL을 한 번에 미리 받아둔다.
  // 이미 캐시가 살아있는(갱신 마진 이전) 항목은 요청에서 자동으로 빠진다 —
  // 매번 전체를 다시 발급받지 않는다.
  static Future<void> prefetch(
      List<({String collection, String id})> items) async {
    final now = DateTime.now();
    final needed = items
        .where((item) {
          final cached = _cache[item.id];
          return cached == null || !now.isBefore(cached.refreshAt);
        })
        .toList();
    if (needed.isEmpty) return;

    for (var i = 0; i < needed.length; i += _maxBatchSize) {
      final end =
          (i + _maxBatchSize < needed.length) ? i + _maxBatchSize : needed.length;
      try {
        await _fetchAndCache(needed.sublist(i, end));
      } catch (e) {
        // 배치 하나가 실패해도 나머지 청크는 계속 시도한다 — 이미 채워진
        // 캐시는 그대로 유효하고, 못 받은 항목은 resolve() 호출 시점에
        // 개별 폴백으로 처리된다.
        debugPrint('[ImageUrlResolver] prefetch 배치 실패(${needed.length}건 중 일부): $e');
      }
    }
  }

  // 문서 하나의 서명 URL 목록을 반환한다. 순서는 서버(signed_url_policy.ts
  // decideSignedUrlAccess)와 동일 — wardrobe/demo_wardrobe는 [이미지, (컷아웃)],
  // fitting_cache는 [이미지] 하나뿐이다. 실패하면 null — 호출부가 기존
  // imageUrl/cutoutImageUrl 필드로 폴백해야 한다는 신호다.
  static Future<List<String>?> resolve({
    required String collection,
    required String id,
  }) async {
    final now = DateTime.now();
    final cached = _cache[id];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      cacheHitCount++;
      return cached.urls;
    }
    cacheMissCount++;

    try {
      await _fetchAndCache([(collection: collection, id: id)]);
    } catch (e) {
      debugPrint('[ImageUrlResolver] 발급 실패, 기존 URL로 폴백 collection=$collection id=$id: $e');
      fallbackCount++;
      return null;
    }

    final result = _cache[id];
    if (result == null) {
      // 서버 응답에 이 id가 없다 — 정책 거부(소유 불일치 등)나 경로 없음
      // 등 개별 사유로 생략된 것(functions/src/index.ts getSignedImageUrls
      // 참고). 서버가 왜 거부했는지는 서버 로그에만 남고 클라이언트는
      // 그냥 폴백한다.
      fallbackCount++;
      return null;
    }
    return result.urls;
  }

  static Future<void> _fetchAndCache(
      List<({String collection, String id})> items) async {
    final callable = _functions.httpsCallable('getSignedImageUrls');
    final response = await callable.call({
      'items': items
          .map((i) => {'collection': i.collection, 'id': i.id})
          .toList(),
    });

    // cloud_functions가 플랫폼 채널로 돌려주는 중첩 맵은 런타임 타입이
    // Map<Object?, Object?>다(gemini_service.dart 스트리밍 주석과 동일한
    // 함정) — 제네릭까지 검사하는 캐스트는 여기서 실패하므로 Map.from으로
    // 다시 감싼다.
    final data = Map<String, dynamic>.from(response.data as Map);
    final now = DateTime.now();
    for (final entry in data.entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      final urls = (value['urls'] as List).map((u) => u as String).toList();
      final expiresAt = DateTime.parse(value['expiresAt'] as String);
      // 만료 80% 시점에 갱신(§3-3) — 만료 60분이면 발급 48분 후부터는
      // 캐시를 만료로 취급해 다음 resolve/prefetch가 새로 받는다.
      final totalSpan = expiresAt.difference(now);
      final refreshAt = now.add(totalSpan * 0.8);
      _cache[entry.key] = _CacheEntry(
        urls: urls,
        expiresAt: expiresAt,
        refreshAt: refreshAt,
      );
    }
  }
}

class _CacheEntry {
  final List<String> urls;
  final DateTime expiresAt;
  final DateTime refreshAt;

  _CacheEntry({
    required this.urls,
    required this.expiresAt,
    required this.refreshAt,
  });
}
