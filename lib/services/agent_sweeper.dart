import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/agent_log_entry.dart';
import '../models/agent_task.dart';
import '../models/wardrobe_item.dart';
import 'agent_planner.dart';
import 'firestore_service.dart';

// 상태 지속성 — 실패한 파이프라인이 조용히 사라지는 대신 남긴 태스크
// (agent_tasks)를 앱 실행 시 1회 발견해 재개한다. AgentPlanner의 선제
// 추천보다 먼저 실행되어야 한다(복구가 새 작업보다 우선). 한 번에 최대
// 2건만 처리하고 건 사이에 텀을 둬 Gemini 과부하 시 호출이 몰리지 않게 한다.
class AgentSweeper {
  static const _maxPerRun = 2;
  static const _stepDelay = Duration(seconds: 3);

  static Future<void> run(String uid) async {
    try {
      final due = await FirestoreService.duePendingAgentTasksSilently(uid);
      if (due.isEmpty) return; // 발견한 게 없으면 조용히 종료 — 로그 도배 방지

      final batch = due.take(_maxPerRun).toList();
      debugPrint('[SWEEP] 재개 대상 ${due.length}건 중 ${batch.length}건 처리');

      final extractCount =
          batch.where((t) => t.type == AgentTask.typeExtractAttributes).length;
      final recCount = batch.length - extractCount;
      final parts = <String>[
        if (extractCount > 0) '분석하지 못한 옷 $extractCount벌',
        if (recCount > 0) '완료되지 못한 추천 $recCount건',
      ];
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeTaskRecovered,
          message: '${parts.join(', ')}을 발견했습니다 — 재개합니다',
        ),
      ));

      for (var i = 0; i < batch.length; i++) {
        await _process(uid, batch[i]);
        if (i < batch.length - 1) {
          await Future.delayed(_stepDelay);
        }
      }
    } catch (e) {
      debugPrint('[SWEEP] 예외로 중단: $e');
    }
  }

  static Future<void> _process(String uid, AgentTask task) async {
    final itemId = task.itemId;
    if (itemId == null) {
      // payload 손상 — 재개할 방법이 없으니 더 시도하지 않는다.
      await FirestoreService.markAgentTaskDoneSilently(uid, task.id);
      return;
    }
    switch (task.type) {
      case AgentTask.typeExtractAttributes:
        await _processExtractAttributes(uid, task, itemId);
        break;
      case AgentTask.typeGenerateRecommendation:
        await _processGenerateRecommendation(uid, task, itemId);
        break;
      default:
        await FirestoreService.markAgentTaskDoneSilently(uid, task.id);
    }
  }

  static Future<void> _processExtractAttributes(
    String uid,
    AgentTask task,
    String itemId,
  ) async {
    final item = await FirestoreService.getWardrobeItemSilently(itemId);
    if (item == null) {
      await FirestoreService.markAgentTaskDoneSilently(uid, task.id); // 삭제된 옷
      return;
    }
    if (item.attributes != null) {
      // 다른 경로(분석 시점 폴백 등)로 이미 채워짐.
      await FirestoreService.markAgentTaskDoneSilently(uid, task.id);
      return;
    }

    // wardrobe는 전 사용자 공유 컬렉션 — 동시 처리 방지.
    final claimed = await FirestoreService.tryClaimExtractionAttemptSilently(itemId);
    if (!claimed) {
      debugPrint('[SWEEP] $itemId — 최근 10분 내 시도 기록 있음, 이번 스윕은 스킵');
      return; // 태스크는 pending 유지 — 다음 스윕에서 다시 시도
    }

    try {
      final attributes = await AgentPlanner.extractAttributesWithRetry(
        itemId,
        item.imageUrl,
        item.category,
      );
      await FirestoreService.updateWardrobeAttributes(itemId, attributes);
      await FirestoreService.markAgentTaskDoneSilently(uid, task.id);

      final color = attributes.color;
      final label = color.isNotEmpty ? '$color ${item.category}' : item.category;
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeTaskRecovered,
          message: '$label 분석 완료 — 이어서 코디 추천을 생성합니다',
          relatedDocId: itemId,
        ),
      ));

      // 원래 그 시점에 이어서 했어야 할 일 — 추천까지 자동 실행.
      final updated = WardrobeItem(
        id: itemId,
        imageUrl: item.imageUrl,
        cutoutImageUrl: item.cutoutImageUrl,
        category: item.category,
        subCategory: item.subCategory,
        createdAt: item.createdAt,
        attributes: attributes,
        size: item.size,
      );
      final ok = await AgentPlanner.generateRecommendationForNewItem(uid, updated);
      if (!ok) {
        unawaited(FirestoreService.enqueueAgentTaskSilently(
          uid,
          AgentTask.create(
            type: AgentTask.typeGenerateRecommendation,
            payload: {'itemId': itemId},
            lastError: '재개된 속성 추출 성공 후 추천 파이프라인 실패',
          ),
        ));
      }
    } catch (e) {
      await _fail(uid, task, '$e');
    }
  }

  static Future<void> _processGenerateRecommendation(
    String uid,
    AgentTask task,
    String itemId,
  ) async {
    final item = await FirestoreService.getWardrobeItemSilently(itemId);
    if (item == null || item.attributes == null) {
      // 삭제됐거나 속성이 없으면(정상 흐름상 있어야 함) 더 재시도할 근거가 없다.
      await FirestoreService.markAgentTaskDoneSilently(uid, task.id);
      return;
    }
    final ok = await AgentPlanner.generateRecommendationForNewItem(uid, item);
    if (ok) {
      await FirestoreService.markAgentTaskDoneSilently(uid, task.id);
    } else {
      await _fail(uid, task, '추천 파이프라인 재시도 실패(자기 평가 루프)');
    }
  }

  static Future<void> _fail(String uid, AgentTask task, String error) async {
    final nextRetryCount = task.retryCount + 1;
    await FirestoreService.rescheduleAgentTaskSilently(
      uid,
      task.id,
      retryCount: nextRetryCount,
      error: error,
    );
    if (nextRetryCount > AgentTask.maxRetries) {
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeTaskRecovered,
          message: '5회 시도 후에도 실패해 이 작업은 보류합니다',
          relatedDocId: task.itemId,
        ),
      ));
    } else {
      final minutes = 1 << nextRetryCount;
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeTaskRecovered,
          message: '1건은 아직 실패 — $minutes분 후 자동 재시도 예약',
          relatedDocId: task.itemId,
        ),
      ));
    }
  }
}
