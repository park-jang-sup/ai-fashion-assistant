import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/agent_log_entry.dart';
import '../models/agent_task.dart';
import '../models/clothing_attributes.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/clothing_size.dart';
import '../models/outfit_history_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/scrap_entry.dart';
import '../models/user_profile.dart';
import '../models/wardrobe_item.dart';

class FirestoreService {
  static final _db = FirebaseFirestore.instance;
  static const _wardrobeCol = 'wardrobe';
  static const _fittingCacheCol = 'fitting_cache';
  static const _usersCol = 'users';

  static Stream<List<WardrobeItem>> wardrobeStream() {
    return _db
        .collection(_wardrobeCol)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => WardrobeItem.fromFirestore(doc))
              .toList(),
        );
  }

  static Future<String> addWardrobeItem({
    required String imageUrl,
    String? cutoutImageUrl,
    required String category,
    String? subCategory,
    ClothingSize? size,
  }) async {
    final doc = await _db.collection(_wardrobeCol).add({
      'imageUrl': imageUrl,
      if (cutoutImageUrl != null) 'cutoutImageUrl': cutoutImageUrl,
      'category': category,
      if (subCategory != null) 'subCategory': subCategory,
      'createdAt': FieldValue.serverTimestamp(),
      if (size != null) 'size': size.toFirestore(),
    });
    return doc.id;
  }

  // 등록 직후 백그라운드 추출, 또는 분석 시점 폴백 추출 결과를 문서에 patch.
  static Future<void> updateWardrobeAttributes(
    String id,
    ClothingAttributes attributes,
  ) async {
    await _db.collection(_wardrobeCol).doc(id).update({
      'attributes': attributes.toFirestore(),
    });
  }

  // 이미 등록된 옷에 치수를 나중에 입력하거나 기존 치수를 수정할 때 사용.
  static Future<void> updateWardrobeSize(String id, ClothingSize size) async {
    await _db.collection(_wardrobeCol).doc(id).update({
      'size': size.toFirestore(),
    });
  }

  // AgentSweeper가 실패한 태스크를 재개할 때 옷 정보를 다시 읽어오는 용도.
  // 그 사이 삭제됐을 수 있어 null을 반환할 수 있다.
  static Future<WardrobeItem?> getWardrobeItemSilently(String id) async {
    try {
      final doc = await _db.collection(_wardrobeCol).doc(id).get();
      if (!doc.exists) return null;
      return WardrobeItem.fromFirestore(doc);
    } catch (e) {
      debugPrint('[TASK] 옷 조회 실패: $e');
      return null;
    }
  }

  // wardrobe는 전 사용자가 공유하는 컬렉션이라, AgentSweeper가 같은 아이템을
  // 동시에(다른 기기/세션에서) 중복 재추출하지 않도록 시도 시각을 찍어
  // 잠그는 용도. 트랜잭션 없이 read-then-write라 이론상 레이스 윈도우는
  // 있지만, 이 앱의 다른 Firestore 접근도 동일한 수준의 단순함을 유지한다.
  // 최근 10분 내 시도 기록이 있으면 false(스킵), 없으면 시각을 찍고 true.
  static Future<bool> tryClaimExtractionAttemptSilently(String itemId) async {
    try {
      final doc = await _db.collection(_wardrobeCol).doc(itemId).get();
      final attemptedAt = (doc.data()?['extractionAttemptedAt'] as Timestamp?)?.toDate();
      if (attemptedAt != null &&
          DateTime.now().difference(attemptedAt) < const Duration(minutes: 10)) {
        return false;
      }
      await _db
          .collection(_wardrobeCol)
          .doc(itemId)
          .update({'extractionAttemptedAt': FieldValue.serverTimestamp()});
      return true;
    } catch (e) {
      debugPrint('[TASK] 추출 시도 클레임 실패: $e');
      return false; // 판단 불가 시 안전하게 스킵(다음 스윕에서 재시도)
    }
  }

  // TODO: 옷/사용자 사진이 삭제될 때 해당 아이템이 포함된 fitting_cache
  // 문서와 Storage의 결과 이미지를 함께 정리하는 로직 필요 (현재 범위 밖 —
  // 지금은 삭제해도 캐시가 orphan으로 남아 낡은 조합을 계속 가리킬 수 있다).
  static Future<void> deleteWardrobeItem(String id) async {
    await _db.collection(_wardrobeCol).doc(id).delete();
  }

  // ── 가상 피팅 결과 캐시 (doc id = 사용자 사진+옷 조합의 SHA-256 해시) ──
  static Future<String?> getCachedFittingImageUrl(String cacheKey) async {
    final doc = await _db.collection(_fittingCacheCol).doc(cacheKey).get();
    return doc.data()?['imageUrl'] as String?;
  }

  static Future<void> cacheFittingResult(String cacheKey, String imageUrl) async {
    await _db.collection(_fittingCacheCol).doc(cacheKey).set({
      'imageUrl': imageUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // ── 사용자 체형/취향 프로필 (doc id = uid, 본인만 접근 가능) ──
  static Future<UserProfile?> getUserProfile(String uid) async {
    final doc = await _db.collection(_usersCol).doc(uid).get();
    final data = doc.data();
    if (data == null) return null;
    return UserProfile.fromFirestore(data);
  }

  static Future<void> saveUserProfile(String uid, UserProfile profile) async {
    await _db.collection(_usersCol).doc(uid).set( profile.toFirestore());
  }

  // 분석 시점의 프로필 조회는 어디까지나 속도 최적화(사진 대체)를 위한
  // 것이므로, 실패해도 조용히 null을 반환해 기존 사진 기반 분석으로
  // 자연스럽게 폴백되게 한다 (fitting_cache 조회와 동일한 패턴).
  static Future<UserProfile?> getUserProfileSilently(String uid) async {
    try {
      return await getUserProfile(uid);
    } catch (e) {
      debugPrint('[프로필조회] 실패: $e');
      return null;
    }
  }

  // ── 코디 사용 이력 (개인화 추천용 축적 데이터, 본인만 접근 가능) ──
  static const _historyCol = 'history';

  static Future<void> addHistoryEntry(String uid, OutfitHistoryEntry entry) async {
    await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_historyCol)
        .add(entry.toFirestore());
  }

  // 이력 기록은 분석/피팅/코디보드 같은 핵심 기능의 부가 작업일 뿐이므로,
  // 실패해도 조용히 무시한다 (getUserProfileSilently와 동일한 패턴).
  static Future<void> addHistoryEntrySilently(String uid, OutfitHistoryEntry entry) async {
    try {
      await addHistoryEntry(uid, entry);
    } catch (e) {
      // 무시 — 사용자가 방금 완료한 분석/피팅/보드 작업 자체는 이미 성공한 상태다.
      debugPrint('[히스토리저장] 실패: $e');
    }
  }

  static Future<List<OutfitHistoryEntry>> getRecentHistorySilently(
    String uid, {
    int limit = 50,
  }) async {
    try {
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_historyCol)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs
          .map((doc) => OutfitHistoryEntry.fromFirestore(doc.data()))
          .toList();
    } catch (e) {
      debugPrint('[히스토리조회] 실패: $e');
      return [];
    }
  }

  // ── 능동 추천 (새 옷 등록을 계기로 백그라운드 생성, 본인만 접근 가능) ──
  static const _recommendationsCol = 'recommendations';

  static Future<String> addRecommendation(String uid, RecommendationEntry entry) async {
    final doc = await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_recommendationsCol)
        .add(entry.toFirestore());
    return doc.id;
  }

  // 추천 생성은 옷 등록의 부가 기능이므로, 실패해도 조용히 무시한다
  // (addHistoryEntrySilently와 동일한 패턴). 파이프라인이 어디서 끊기는지
  // 진단할 수 있도록 성공/실패를 로그로 남긴다.
  static Future<String?> addRecommendationSilently(String uid, RecommendationEntry entry) async {
    try {
      final docId = await addRecommendation(uid, entry);
      debugPrint('[RECOMMEND] 저장 완료: docId=$docId');
      return docId;
    } catch (e) {
      debugPrint('[RECOMMEND] 저장 실패: $e');
      return null;
    }
  }

  // 채택률 지표(AgentStats)용 — 최근 N일 추천 전체(dismissed 무관)를 가져와
  // 호출부가 userChoice로 클라이언트 필터링한다. createdAt 단일 range라
  // 복합 인덱스 불필요.
  static Future<List<RecommendationEntry>> recommendationsSinceSilently(
    String uid,
    DateTime since,
  ) async {
    try {
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_recommendationsCol)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
          .get();
      return snapshot.docs.map((d) => RecommendationEntry.fromFirestore(d)).toList();
    } catch (e) {
      debugPrint('[STATS] 최근 추천 조회 실패: $e');
      return [];
    }
  }

  // dismissed == false인 것 중 최신 1건만 — 홈 화면 카드는 항상 최대 1개만 노출한다.
  static Stream<RecommendationEntry?> recommendationStream(String uid) {
    return _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_recommendationsCol)
        .where('dismissed', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.isEmpty ? null : RecommendationEntry.fromFirestore(snapshot.docs.first));
  }

  static Future<void> dismissRecommendation(String uid, String id) async {
    await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_recommendationsCol)
        .doc(id)
        .update({'dismissed': true});
  }

  // candidates에서 "이 날짜 일정 중복 게이트의 진짜 대상"과 "정리(dismiss)할
  // 나머지"를 가르는 순수 함수(Firestore 호출 없음, 단위 테스트 대상).
  //  · triggerItemId가 비어있지 않은 문서(새 옷 등록이 계기인 일반 추천)는
  //    애초에 일정 중복 게이트 대상이 아니므로 제외한다 — targetDate가
  //    우연히 같은 날짜로 채워져도(등록일=일정일) 여기서 걸러낸다.
  //  · 남은 일정 기반 후보가 여럿이면(비결정적 limit(1) 시절의 잔재 등)
  //    createdAt 최신 문서를 대상으로 삼고, 그 외는 정리 대상으로 돌려준다
  //    — 다음 실행에서 다시 후보로 걸리지 않도록 호출부가 dismiss한다.
  static ({RecommendationEntry? target, List<RecommendationEntry> toDismiss})
      selectDateRecommendation(List<RecommendationEntry> candidates) {
    final scheduleBased = candidates.where((r) => r.triggerItemId.isEmpty).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (scheduleBased.isEmpty) return (target: null, toDismiss: const []);
    return (target: scheduleBased.first, toDismiss: scheduleBased.skip(1).toList());
  }

  // 특정 날짜 일정의 살아있는(dismissed=false) 선제 추천을 조회 — 중복 생성
  // 방지 게이트 겸, 예보 재계획 판단(AgentPlanner.shouldReplanForWeather)에
  // 필요한 스냅샷/replanCount를 함께 돌려준다. targetDate/dismissed 둘 다
  // equality 필터라(orderBy 없음) 복합 인덱스가 필요 없다 — triggerItemId
  // 필터나 createdAt 정렬을 쿼리에 추가하면 복합 인덱스가 필요해지므로,
  // 후보를 넉넉히(5건) 받아 selectDateRecommendation으로 Dart에서 가른다.
  static Future<RecommendationEntry?> recommendationForDateSilently(
    String uid,
    DateTime date,
  ) async {
    try {
      final normalized = DateTime(date.year, date.month, date.day);
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_recommendationsCol)
          .where('targetDate', isEqualTo: Timestamp.fromDate(normalized))
          .where('dismissed', isEqualTo: false)
          .limit(5)
          .get();
      final candidates = snapshot.docs.map((d) => RecommendationEntry.fromFirestore(d)).toList();
      final selection = selectDateRecommendation(candidates);
      for (final stale in selection.toDismiss) {
        unawaited(dismissRecommendation(uid, stale.id));
      }
      return selection.target;
    } catch (e) {
      debugPrint('[PLAN] 추천 중복 조회 실패: $e');
      return null;
    }
  }

  // ── 레벨 3: 피드백 학습 ──
  // 날짜 ± windowDays 범위의 선제/일반 추천들 조회(피드백 대조용). targetDate
  // 단일 필드 range(양방향 부등호)라 복합 인덱스 불필요. 태그 우선순위·근접
  // 매칭은 호출부(agent_planner.dart)가 클라이언트에서 처리한다.
  static Future<List<RecommendationEntry>> recommendationsInDateRangeSilently(
      String uid, DateTime centerDate, int windowDays) async {
    try {
      final center = DateTime(centerDate.year, centerDate.month, centerDate.day);
      final start = center.subtract(Duration(days: windowDays));
      final end = center.add(Duration(days: windowDays));
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_recommendationsCol)
          .where('targetDate', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('targetDate', isLessThanOrEqualTo: Timestamp.fromDate(end))
          .get();
      return snapshot.docs.map((d) => RecommendationEntry.fromFirestore(d)).toList();
    } catch (e) {
      debugPrint('[FEEDBACK] 기간별 추천 조회 실패: $e');
      return [];
    }
  }

  // 추천 문서에 사용자 반응(채택/불일치)을 기록. 부가 기능이라 실패는 조용히 무시.
  static Future<void> updateRecommendationFeedbackSilently(
    String uid,
    String recId, {
    required String userChoice,
    List<String> userChosenItemIds = const [],
  }) async {
    try {
      await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_recommendationsCol)
          .doc(recId)
          .update({
        'userChoice': userChoice,
        if (userChosenItemIds.isNotEmpty) 'userChosenItemIds': userChosenItemIds,
      });
    } catch (e) {
      debugPrint('[FEEDBACK] 피드백 기록 실패: $e');
    }
  }

  // 최근 추천 이력 원본 조회 — getRelevantHistorySilently가 관련도 계산의
  // 재료로 쓴다. orderBy 단독이라 복합 인덱스 불필요.
  static Future<List<RecommendationEntry>> recentRecommendationsSilently(
    String uid, {
    int limit = 30,
  }) async {
    try {
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_recommendationsCol)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return snapshot.docs.map((d) => RecommendationEntry.fromFirestore(d)).toList();
    } catch (e) {
      debugPrint('[RAG] 최근 추천 이력 조회 실패: $e');
      return [];
    }
  }

  // RAG 프롬프트에 주입할 "관련 코디 이력" — recency가 아니라 relevance로
  // 뽑는다. 최근 이력 30건을 한 번에 가져와(기존 recentRecommendationsSilently
  // 재사용, 새 인덱스 불필요) 클라이언트에서 점수를 매긴다:
  //  · tpoTag 일치 → +3
  //  · candidateItemIds와 겹치는 itemId 1개당 → +2
  //  · colorScore >= 80 → +1
  //  · 동점이면 최신순
  // 전부 0점이면(관련 신호가 하나도 없으면) 관련 없다고 빈손으로 가는 대신
  // 최신순 limit건으로 폴백한다 — 이 경우 isFallback=true.
  static Future<
      ({
        List<String> lines,
        int tagMatchCount,
        int itemOverlapCount,
        bool isFallback,
      })> getRelevantHistorySilently(
    String uid, {
    String? tpoTag,
    List<String>? candidateItemIds,
    int limit = 5,
    Map<String, WardrobeItem>? wardrobeById,
  }) async {
    final pool = await recentRecommendationsSilently(uid, limit: 30);
    if (pool.isEmpty) {
      return (lines: <String>[], tagMatchCount: 0, itemOverlapCount: 0, isFallback: false);
    }

    final candidateSet = candidateItemIds?.toSet() ?? const <String>{};
    final scored = pool.map((entry) {
      var score = 0;
      final tagMatch = tpoTag != null && entry.targetTpoTag == tpoTag;
      if (tagMatch) score += 3;
      final overlap =
          candidateSet.isEmpty ? 0 : entry.itemIds.where(candidateSet.contains).length;
      score += overlap * 2;
      if ((entry.colorScore ?? 0) >= 80) score += 1;
      return (entry: entry, score: score, tagMatch: tagMatch, overlap: overlap);
    }).toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return b.entry.createdAt.compareTo(a.entry.createdAt);
      });

    final isFallback = scored.every((s) => s.score == 0);
    final chosen = scored.take(limit).toList();
    final tagMatchCount = chosen.where((s) => s.tagMatch).length;
    final itemOverlapCount = chosen.where((s) => s.overlap > 0).length;

    debugPrint('[RAG] 이력 ${pool.length}건 중 관련도 상위 ${chosen.length}건 선택 '
        '(태그일치 $tagMatchCount건, 아이템겹침 $itemOverlapCount건)'
        '${isFallback ? ' — 관련 신호 없어 최신순 폴백' : ''}');

    return (
      lines: chosen.map((s) => s.entry.toPromptLine(wardrobeById: wardrobeById)).toList(),
      tagMatchCount: tagMatchCount,
      itemOverlapCount: itemOverlapCount,
      isFallback: isFallback,
    );
  }

  // ── 에이전트 활동 로그 (백그라운드 행동 서사, 본인만 접근 가능) ──
  // history/recommendations가 "결과물"이라면 여기는 그 결과에 이르는 "행동"을
  // 남긴다. where 없이 createdAt orderBy만 쓰므로 복합 인덱스가 필요 없다.
  static const _agentLogsCol = 'agent_logs';

  // 로그 기록은 추천/분석/피팅 같은 핵심 흐름의 부가 작업이므로, 실패해도
  // 조용히 무시한다 (addHistoryEntrySilently와 동일한 fire-and-forget 패턴).
  static Future<void> addAgentLogSilently(String uid, AgentLogEntry entry) async {
    try {
      await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_agentLogsCol)
          .add(entry.toFirestore());
    } catch (e) {
      // 무시 — 로그를 못 남겨도 사용자가 겪는 기능(추천/분석/피팅)에는 영향 없다.
      debugPrint('[에이전트로그저장] 실패: $e');
    }
  }

  // 활동 내역 화면이 구독하는 최신순 스트림. orderBy 단독이라 자동 인덱스로 충분.
  static Stream<List<AgentLogEntry>> agentLogStream(String uid, {int limit = 100}) {
    return _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_agentLogsCol)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => AgentLogEntry.fromFirestore(doc)).toList());
  }

  // ── 에이전트 재시도 태스크 (상태 지속성 — 실패한 백그라운드 작업의 재개
  // 지점, 본인만 접근 가능) ── status만 where로 걸고 nextRetryAt/정렬은
  // 클라이언트에서 처리해 복합 인덱스가 필요 없다.
  static const _agentTasksCol = 'agent_tasks';

  // 같은 type+itemId의 pending 태스크가 이미 있으면 새로 만들지 않는다
  // (파이프라인이 여러 경로로 재시도되며 중복 태스크를 쌓는 것을 방지).
  static Future<void> enqueueAgentTaskSilently(String uid, AgentTask task) async {
    try {
      final itemId = task.itemId;
      if (itemId != null) {
        final existing = await _db
            .collection(_usersCol)
            .doc(uid)
            .collection(_agentTasksCol)
            .where('status', isEqualTo: AgentTask.statusPending)
            .get();
        final dup = existing.docs.any((d) {
          final data = d.data();
          return data['type'] == task.type &&
              (data['payload'] as Map?)?['itemId'] == itemId;
        });
        if (dup) return;
      }
      await _db.collection(_usersCol).doc(uid).collection(_agentTasksCol).add(task.toFirestore());
      debugPrint('[TASK] 재시도 태스크 등록: ${task.type}($itemId)');
    } catch (e) {
      debugPrint('[TASK] 태스크 등록 실패: $e');
    }
  }

  // nextRetryAt <= now인 pending 태스크를 오래된 순(createdAt 오름차순)으로.
  static Future<List<AgentTask>> duePendingAgentTasksSilently(String uid) async {
    try {
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_agentTasksCol)
          .where('status', isEqualTo: AgentTask.statusPending)
          .get();
      final now = DateTime.now();
      final due = snapshot.docs
          .map((d) => AgentTask.fromFirestore(d))
          .where((t) => !t.nextRetryAt.isAfter(now))
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return due;
    } catch (e) {
      debugPrint('[TASK] 대기 태스크 조회 실패: $e');
      return [];
    }
  }

  static Future<void> markAgentTaskDoneSilently(String uid, String taskId) async {
    try {
      await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_agentTasksCol)
          .doc(taskId)
          .update({'status': AgentTask.statusDone});
    } catch (e) {
      debugPrint('[TASK] 완료 처리 실패: $e');
    }
  }

  // 실패 시 지수 백오프로 재스케줄. retryCount가 maxRetries를 넘으면 gave_up.
  static Future<void> rescheduleAgentTaskSilently(
    String uid,
    String taskId, {
    required int retryCount,
    required String error,
  }) async {
    try {
      final gaveUp = retryCount > AgentTask.maxRetries;
      await _db.collection(_usersCol).doc(uid).collection(_agentTasksCol).doc(taskId).update({
        'retryCount': retryCount,
        'nextRetryAt':
            Timestamp.fromDate(DateTime.now().add(Duration(minutes: 1 << retryCount))),
        'lastError': error,
        if (gaveUp) 'status': AgentTask.statusGaveUp,
      });
    } catch (e) {
      debugPrint('[TASK] 재스케줄 실패: $e');
    }
  }

  // ── 백그라운드 실행 메타(진단용 — 마지막 실행 시각·결과, 본인만 접근 가능) ──
  // BackgroundAgent의 빈도 가드가 참조하는 단일 문서. "가드 읽기/쓰기가
  // 실패하면 실행하지 않는다" 원칙 때문에 다른 agent_* 메서드와 달리 실패를
  // 삼키지 않고 그대로 던진다 — 호출부(BackgroundAgent.run)가 예외 여부로
  // 가드 신뢰 가능 여부를 판단해야 한다.
  static const _agentMetaCol = 'agent_meta';
  static const _agentMetaBackgroundDocId = 'background';

  static Future<Map<String, dynamic>?> getBackgroundAgentMeta(String uid) async {
    final doc = await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_agentMetaCol)
        .doc(_agentMetaBackgroundDocId)
        .get();
    return doc.data();
  }

  static Future<void> setBackgroundAgentMeta(
    String uid,
    Map<String, dynamic> data,
  ) async {
    await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_agentMetaCol)
        .doc(_agentMetaBackgroundDocId)
        .set(data, SetOptions(merge: true));
  }

  // 설정 화면의 상태 표시(B.5)용 — 백그라운드가 문서를 갱신하면 앱이 열려
  // 있어도 실시간으로 반영된다.
  static Stream<Map<String, dynamic>?> backgroundAgentMetaStream(String uid) {
    return _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_agentMetaCol)
        .doc(_agentMetaBackgroundDocId)
        .snapshots()
        .map((doc) => doc.data());
  }

  // ── 착장 캘린더 (OOTD 기록, 본인만 접근 가능) ──
  // date 필드의 range(>=, <=)와 orderBy가 같은 필드라 복합 인덱스가 필요 없다.
  static const _calendarCol = 'calendar';

  // 착장 기록은 사용자의 명시적 액션이라, 실패를 삼키지 않고 그대로 던진다
  // (addScrap과 동일 원칙 — 호출부가 스낵바로 알린다). 저장된 문서 id를 반환.
  static Future<String> addCalendarEntry(String uid, OutfitCalendarEntry entry) async {
    final doc = await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_calendarCol)
        .add(entry.toFirestore());
    return doc.id;
  }

  // 예정(planned) 캘린더 문서를 그대로 기록(recorded)으로 전환할 때 쓴다.
  // 새 문서를 만들지 않고 같은 문서를 업데이트 — date/tpoTag/createdAt은
  // 원래 예정 등록 시점 값을 그대로 유지한다.
  static Future<void> updateCalendarEntry(
    String uid,
    String id, {
    required String status,
    String? fittingImageUrl,
    required List<String> itemIds,
    required List<String> itemSummaries,
    required String source,
    String? recommendationId,
  }) async {
    await _db.collection(_usersCol).doc(uid).collection(_calendarCol).doc(id).update({
      'status': status,
      if (fittingImageUrl != null) 'fittingImageUrl': fittingImageUrl,
      'itemIds': itemIds,
      'itemSummaries': itemSummaries,
      'source': source,
      if (recommendationId != null) 'recommendationId': recommendationId,
    });
  }

  static Future<void> deleteCalendarEntry(String uid, String id) async {
    await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_calendarCol)
        .doc(id)
        .delete();
  }

  // 해당 월(1일 00:00 ~ 다음달 1일 00:00 미만) 기록 스트림 — 캘린더 화면용.
  static Stream<List<OutfitCalendarEntry>> calendarEntriesForMonth(
    String uid,
    int year,
    int month,
  ) {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 1); // 다음 달 1일(미만 비교)
    return _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_calendarCol)
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThan: Timestamp.fromDate(end))
        .orderBy('date')
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => OutfitCalendarEntry.fromFirestore(doc)).toList());
  }

  // 임의 범위 조회 — 이후 에이전트(주간 플랜/선제 추천)가 다가오는 일정과
  // 과거 착장을 함께 읽을 때 쓴다. 실패해도 조용히 빈 리스트.
  static Future<List<OutfitCalendarEntry>> calendarEntriesForRange(
    String uid,
    DateTime from,
    DateTime to,
  ) async {
    try {
      final snapshot = await _db
          .collection(_usersCol)
          .doc(uid)
          .collection(_calendarCol)
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
          .where('date', isLessThanOrEqualTo: Timestamp.fromDate(to))
          .orderBy('date')
          .get();
      return snapshot.docs
          .map((doc) => OutfitCalendarEntry.fromFirestore(doc))
          .toList();
    } catch (e) {
      debugPrint('[캘린더조회] 실패: $e');
      return [];
    }
  }

  // ── 가상 피팅 스크랩 (사용자가 직접 북마크, 본인만 접근 가능) ──
  // 사용자의 명시적 액션이므로 다른 *Silently 메서드들과 달리 실패를
  // 삼키지 않고 그대로 던진다 — 호출부(fitting_room_screen.dart)가
  // 스낵바로 알린다.
  static const _scrapsCol = 'scraps';

  static Future<String> addScrap(String uid, ScrapEntry entry) async {
    final doc = await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_scrapsCol)
        .add(entry.toFirestore());
    return doc.id;
  }

  static Future<void> deleteScrap(String uid, String scrapId) async {
    await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_scrapsCol)
        .doc(scrapId)
        .delete();
  }

  // 이름은 "스크랩됐는지 여부"지만, 있으면 그 문서 id를 그대로 반환해
  // 호출부가 곧장 deleteScrap에 넘길 수 있게 한다(null이면 미스크랩).
  // where절 1개만 쓰므로 복합 인덱스가 필요 없다.
  static Future<String?> isScrapped(String uid, String fittingImageUrl) async {
    final snapshot = await _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_scrapsCol)
        .where('fittingImageUrl', isEqualTo: fittingImageUrl)
        .limit(1)
        .get();
    return snapshot.docs.isEmpty ? null : snapshot.docs.first.id;
  }

  static Stream<List<ScrapEntry>> scrapStream(String uid) {
    return _db
        .collection(_usersCol)
        .doc(uid)
        .collection(_scrapsCol)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) => ScrapEntry.fromFirestore(doc)).toList());
  }
}
