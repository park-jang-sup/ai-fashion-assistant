import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

// 서명 URL 이행 A-4의 킬 스위치 — 여기 두는 이유(2026-08-06 이전엔
// widgets/signed_network_image.dart에만 있었다): A-5에서 GeminiService의
// 다운로드 경로(군 (a))도 이 플래그로 게이팅해야 하는데, 서비스가
// 위젯 파일을 import하는 건 계층을 거스른다 — 서비스 계층인 여기로
// 옮기고 signed_network_image.dart는 재수출만 한다.
//
//   flutter run --dart-define=SIGNED_URLS=true
const bool signedUrlsEnabled =
    bool.fromEnvironment('SIGNED_URLS', defaultValue: false);

// 서명 URL 이행 A-3(docs/task_signed_urls_v1.md) — 화면은 이 클래스를
// 거쳐서만 서명 URL을 받는다(A-4에서 배선). GeminiService/StorageService와
// 같은 static-only 서비스 패턴을 따른다.
//
// 배치 발급(prefetch) + docId 키 메모리 캐시 + 만료 80% 시점 갱신 + 실패
// 시 null 반환(호출부가 기존 URL 필드로 폴백, §3-3). 서명 URL은 어디에도
// 영속화하지 않는다 — 이 캐시는 앱 프로세스가 살아있는 동안만 유효하고,
// 콜드스타트마다 비어서 다시 채워진다.
//
// [2026-08-06 병합 수정] 관문 B 계측에서 옷장(120벌) 한 번 진입에
// signCount가 9~91까지 새는 게 실측됐다 — prefetch()의 배치 콜과
// GridView 타일마다 독립 실행되는 SignedNetworkImage.resolve()가
// 서로 모르는 채 각자 발사했기 때문(로그로 확인: 배치 120 직후 52ms
// 안에 개별 배치=1 콜이 여러 건 이어짐 — 배치 응답이 오기 전에 타일이
// 먼저 빌드돼 캐시가 비어 있는 걸 보고 자기 것만 따로 요청). 그래서
// resolve()는 더 이상 즉시 발사하지 않는다 — 짧은 창(디바운스) 동안
// 요청을 모아 한 콜로 합치고, 이미 같은 id를 요청 중이면 그 Future를
// 공유해 중복 발사 자체를 구조적으로 막는다. prefetch()도 이제 이
// 병합 경로를 그대로 타는 얇은 래퍼다 — 별도 배치 로직을 안 둔다.
class ImageUrlResolver {
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-northeast3');

  static final Map<String, _CacheEntry> _cache = {};

  // 계측(§5) — Firestore에 영속화하지 않고 프로세스 수명 동안의 인메모리
  // 카운터만 둔다(v1 범위). 관문 A/B는 이 값을 읽어 "폴백 발화 0"을 확인한다.
  static int cacheHitCount = 0;
  static int cacheMissCount = 0;
  static int fallbackCount = 0;

  // 서버(1회 콜) 배치 상한과 동일 — signed_url_policy.ts의 MAX_BATCH_SIZE.
  static const int _maxBatchSize = 200;

  // 병합 창 — 이 시간 안에 들어온 resolve() 요청은 전부 한 콜로 묶인다.
  // 사람이 스크롤하며 타일이 순차로 빌드되는 속도(수~수십 ms 간격)보다
  // 넉넉해야 하고, 화면 체감 지연으로 느껴지지 않을 만큼 짧아야 한다.
  static const Duration _coalesceWindow = Duration(milliseconds: 40);

  // key = "collection/id" — 같은 id라도 컬렉션이 다르면(이론상) 별개
  // 요청으로 다룬다. 진행 중(아직 응답 안 옴)인 요청의 Future를 여기서
  // 공유한다 — 새 네트워크 호출을 만들지 않는다.
  static final Map<String, Completer<List<String>?>> _pending = {};
  static final List<({String collection, String id})> _pendingQueue = [];
  static Timer? _flushTimer;

  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    _pending.clear();
    _pendingQueue.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    cacheHitCount = 0;
    cacheMissCount = 0;
    fallbackCount = 0;
  }

  // 화면 진입 시(예: 옷장 120벌) 여러 문서의 URL을 한 번에 미리 받아둔다.
  // resolve()와 같은 병합 경로를 타므로, 개별 타일이 동시에 resolve()를
  // 불러도 여기서 이미 큐에 들어간 항목과 자연히 합쳐진다 — prefetch
  // 전용 로직을 따로 두지 않는다.
  static Future<void> prefetch(
      List<({String collection, String id})> items) async {
    await Future.wait(
      items.map((item) => resolve(collection: item.collection, id: item.id)),
    );
  }

  // 문서 하나의 서명 URL 목록을 반환한다. 순서는 서버(signed_url_policy.ts
  // decideSignedUrlAccess)와 동일 — wardrobe/demo_wardrobe는 [이미지, (컷아웃)],
  // fitting_cache는 [이미지] 하나뿐이다. 실패하면 null — 호출부가 기존
  // imageUrl/cutoutImageUrl 필드로 폴백해야 한다는 신호다.
  static Future<List<String>?> resolve({
    required String collection,
    required String id,
  }) {
    final now = DateTime.now();
    final cached = _cache[id];
    // 만료 80% 시점(refreshAt)까지만 캐시 적중으로 본다(§3-3) — 실제
    // expiresAt까지 쓰면 화면에 떠 있는 동안 URL이 만료돼버릴 수 있다.
    // prefetch든 개별 resolve()든 이제 같은 기준을 쓴다(예전엔 이 둘이
    // 서로 다른 기준을 써서 어느 경로가 먼저 도는지에 따라 갱신 시점이
    // 갈렸다).
    if (cached != null && now.isBefore(cached.refreshAt)) {
      cacheHitCount++;
      return Future.value(cached.urls);
    }

    final key = '$collection/$id';
    final existing = _pending[key];
    if (existing != null) {
      // 이미 이번 병합 창(또는 진행 중인 콜)에 같은 항목이 요청돼 있다
      // — 새로 발사하지 않고 그 결과를 같이 기다린다.
      return existing.future;
    }

    cacheMissCount++;
    final completer = Completer<List<String>?>();
    _pending[key] = completer;
    _pendingQueue.add((collection: collection, id: id));
    _flushTimer ??= Timer(_coalesceWindow, _flushPending);
    return completer.future;
  }

  // A-5 군 (a) — GeminiService의 다운로드 경로가 쓰는 진입점. 킬 스위치가
  // off면 resolve()조차 부르지 않는다(호출부가 매번 signedUrlsEnabled를
  // 따로 검사하지 않아도 되게, 여기서 한 곳에 모아둔다).
  static Future<List<String>?> resolveIfEnabled({
    required String collection,
    required String id,
  }) {
    if (!signedUrlsEnabled) return Future.value(null);
    return resolve(collection: collection, id: id);
  }

  static Future<void> _flushPending() async {
    _flushTimer = null;
    if (_pendingQueue.isEmpty) return;

    final batch = List<({String collection, String id})>.from(_pendingQueue);
    _pendingQueue.clear();

    // 서버 배치 상한(200)을 넘으면 청크로 나눠 순차 처리한다 — 옷장
    // 120벌 정도는 한 청크로 끝난다.
    for (var i = 0; i < batch.length; i += _maxBatchSize) {
      final end = (i + _maxBatchSize < batch.length) ? i + _maxBatchSize : batch.length;
      final chunk = batch.sublist(i, end);
      try {
        await _fetchAndCache(chunk);
      } catch (e) {
        debugPrint('[ImageUrlResolver] 발급 실패(${chunk.length}건): $e');
      }
      for (final item in chunk) {
        final key = '${item.collection}/${item.id}';
        final completer = _pending.remove(key);
        if (completer == null) continue; // 이미 처리됨(방어적)
        final result = _cache[item.id];
        if (result != null) {
          completer.complete(result.urls);
        } else {
          // 서버 응답에 이 id가 없다(정책 거부·경로 없음 등, functions/
          // src/index.ts getSignedImageUrls 참고) 또는 배치 콜 자체가
          // 실패했다 — 어느 쪽이든 폴백 신호.
          fallbackCount++;
          completer.complete(null);
        }
      }
    }
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
