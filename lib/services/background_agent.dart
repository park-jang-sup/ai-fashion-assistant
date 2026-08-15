import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';
import '../firebase_options.dart';
import '../models/agent_log_entry.dart';
import 'agent_planner.dart';
import 'agent_sweeper.dart';
import 'cadence_policy.dart';
import 'firestore_service.dart';
import 'notification_service.dart';
import 'response_signal.dart';
import 'weather_service.dart';

// WorkManager가 부르는 진입점. @pragma('vm:entry-point')가 없으면 릴리스
// 빌드에서 트리 셰이킹으로 제거되어 "디버그는 정상, 릴리스만 안 도는" 형태로
// 나타난다.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return await BackgroundAgent.run(force: inputData?['force'] == true);
  });
}

// C단계: AgentSweeper(태스크 복구) → AgentPlanner.runProactiveCheck(선제
// 추천, maxPlans로 처리량 제한) → 알림 순으로 연결한다.
class BackgroundAgent {
  static const _minInterval = Duration(hours: 10);

  // 최소 간격 판정 — 이 작업에서 유일하게 분리해 테스트하는 순수 함수.
  // lastRunAt이 미래(기기 시각 변경 등)면 실행 쪽으로 폴백한다: 그렇지
  // 않으면 시각이 잘못 기록된 뒤로 영영 실행되지 않을 수 있기 때문이다.
  @visibleForTesting
  static bool shouldRunNow({
    required DateTime? lastRunAt,
    required DateTime now,
    required bool force,
    Duration minInterval = _minInterval,
  }) {
    if (force) return true;
    if (lastRunAt == null) return true;
    if (lastRunAt.isAfter(now)) return true;
    return now.difference(lastRunAt) >= minInterval;
  }

  // 반환값: true = 성공 또는 재시도해도 달라지지 않는 상황(다음 주기까지
  // 대기). false = Firebase 초기화 자체가 실패한 경우로 한정 — 그 외에는
  // 이 프로젝트가 이미 가진 태스크 큐(agent_tasks)와 재시도가 겹치지
  // 않도록 항상 true를 반환한다.
  //
  // F'.3 발화 계측 — 세 값이 각각 다른 것을 센다(HANDOFF 4-5: debugPrint는
  // 릴리스 빌드에서 안 찍힌다, 실측 근거):
  //  1. 로컬 파일 카운터(_bumpLocalInvocationCounter) — "OS가 콜백을 불렀다"
  //     의 릴리스 안전 기준선. Firebase.initializeApp()보다 앞에서 증가하므로
  //     Firestore·auth 성패와 무관하다. 설정 화면에서 읽는다(readLocalCounterDiagnostics).
  //  2. agent_meta의 invokeCount — "uid 확보+meta 읽기 성공까지 도달한 실행
  //     횟수"다. Firestore 인증 자체가 안 된 실행은 여기 안 잡힌다.
  //  3. 위 debugPrint 줄 — 디버그 빌드 전용 보조 확인 수단. 릴리스 기준선으로
  //     쓰지 않는다.
  // (1)과 (2)의 차이가 "Firebase 초기화 실패 또는 인증 복원 타임아웃으로
  // 죽은 실행" 수다.
  //
  // 로컬 카운터는 기기 단위, invokeCount는 uid 단위 — 계정을 바꾸면(F'.2
  // 검증에서 심사 계정 ↔ 본인 계정을 오가는 경우) 절대값 비교가 성립하지
  // 않고, 계정을 되돌린 시점(t1)의 두 값을 기준으로 삼은 증분(Δ) 비교만
  // 유효하다.
  //
  // 판정: (1) - (2)가 **음수**로 나오면 그건 죽은 실행이 아니라 로컬
  // 카운터 자체가 도중에 리셋된 것이다(배터리 최적화가 프로세스를 정지시킨
  // 순간과 파일 쓰기가 겹치면 발생 — 2026-07-29 실측: 정지 후 약 100초 뒤
  // 재시도). 그 구간의 조기 사망 건수는 산출 불가로 보고한다.
  static const _invocationLogCap = 500;
  static const _localInvocationCountFileName = 'bg_local_invocation_count.txt';

  static Future<File> _localInvocationCountFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_localInvocationCountFileName');
  }

  // 카운터 쓰기가 릴리스에서 실패해도 debugPrint만으로는 증거가 안 남는다
  // (한계로 남기기로 했던 지점이 실제로 문제가 됐다 — 2026-07-31). 마지막
  // 시도의 성패를 메모리에 남겨 UI(진단 패널)와 다음 agent_meta 쓰기 양쪽에서
  // 회수할 수 있게 한다. 성공하면 지운다 — "마지막 시도"만 반영해야 오래된
  // 오류가 계속 표시되는 걸 막는다.
  static String? lastLocalCounterError;

  // Firestore·auth와 무관한 릴리스 발화 기준선. shared_preferences는 이
  // 저장소 pubspec에 없고(2026-07-30 확인), 이미 의존성인 path_provider로
  // 텍스트 파일 하나면 충분해 새 의존성을 추가하지 않는다. 킬 스위치
  // BG_AGENT(main.dart)는 bool.fromEnvironment 컴파일 타임 상수라 재사용할
  // 저장 수단이 아니다. 카운터 자체가 실패해도(드묾) 콜백은 계속되어야 하므로
  // 삼킨다 — 그 경우 릴리스 기준선 쪽만 그 실행을 놓친다.
  //
  // writeAsString은 통짜 덮어쓰기라, 배터리 최적화가 그 도중 프로세스를
  // 정지시키면(2026-07-29 실측 근거) 파일이 빈 채로 남아 다음 실행의
  // int.tryParse가 null → 카운터가 조용히 0으로 리셋된다. 임시 파일에 쓰고
  // rename으로 갈아끼운다 — 같은 디렉터리 내 rename은 원자적이라 중간에
  // 죽어도 이전 완전한 값이나 새 완전한 값만 남고 반쪽 파일이 생기지 않는다.
  static Future<void> _bumpLocalInvocationCounter() async {
    try {
      final file = await _localInvocationCountFile();
      var count = 0;
      if (await file.exists()) {
        count = int.tryParse(await file.readAsString()) ?? 0;
      }
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString('${count + 1}');
      await tmpFile.rename(file.path);
      lastLocalCounterError = null;
    } catch (e) {
      lastLocalCounterError = '$e';
      debugPrint('[BG] 로컬 발화 카운터 기록 실패(무시): $e');
    }
  }

  // 설정 화면이 읽는 진단 진입점 — Firestore 없이 값을 낸다. 파일 절대 경로·
  // 존재 여부·현재 값·마지막 오류를 함께 반환한다: "파일이 아예 없다"(백그
  // 라운드가 한 번도 쓰지 못함)와 "파일은 있는데 값이 낮다"(일부 실행만
  // 실패)는 원인이 다르므로 값 하나만으로는 구분이 안 된다.
  static Future<({String path, bool exists, int value, String? lastError})>
      readLocalCounterDiagnostics() async {
    try {
      final file = await _localInvocationCountFile();
      final exists = await file.exists();
      final value = exists ? (int.tryParse(await file.readAsString()) ?? 0) : 0;
      return (path: file.path, exists: exists, value: value, lastError: lastLocalCounterError);
    } catch (e) {
      return (path: '(경로 확인 실패)', exists: false, value: 0, lastError: '$e');
    }
  }

  static Future<bool> run({bool force = false}) async {
    // 디버그 빌드 전용 보조 로그 — 릴리스 기준선은 아래 로컬 카운터다.
    debugPrint('[BG] 콜백 진입(force=$force)');
    // 백그라운드 콜백은 별도 아이솔레이트에서 실행되므로 main()의 초기화가
    // 전혀 적용돼 있지 않다 — 여기서 다시 해야 한다.
    WidgetsFlutterBinding.ensureInitialized();
    // path_provider_android는 dartPluginClass로 등록되는 federated 플러그인이라
    // (.dart_tool/flutter_build/dart_plugin_registrant.dart의 _PluginRegistrant가
    // PathProviderAndroid.registerWith()를 호출) 메인 아이솔레이트 시작 때는
    // 엔진이 자동으로 이걸 실행해 주지만, workmanager 콜백처럼 별도 진입점으로
    // 만들어진 아이솔레이트에서는 보장이 아니다. flutter_local_notifications는
    // 자바 쪽 GeneratedPluginRegistrant로 등록돼 이미 동작하는 것과 대조된다.
    // 비용이 0이라 명시적으로 호출한다(실기기에서 로컬 카운터가 D 케이스에서만
    // 재현 안 되는 비대칭 증상의 유력한 원인 — 2026-07-31).
    DartPluginRegistrant.ensureInitialized();
    // Firebase 초기화보다 앞에 있어야 그 실패와 무관하게 이 실행이 기록된다.
    await _bumpLocalInvocationCounter();

    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } catch (e) {
      debugPrint('[BG] Firebase 초기화 실패: $e');
      return false; // WorkManager 재시도
    }

    // App Check는 현재 강제(enforce)되지 않으므로 여기서 activate하지 않는다.
    // 나중에 강제로 전환하면 이 아이솔레이트에서도 activate가 필요해진다.

    // initializeApp() 직후 currentUser를 바로 읽으면 인증 상태의 디스크
    // 복원이 아직 끝나지 않아 거의 확실히 null이다. authStateChanges()의
    // 첫 값(복원 완료 신호)을 기다리되, 무한 대기를 막기 위해 타임아웃을 둔다.
    final user = await FirebaseAuth.instance
        .authStateChanges()
        .firstWhere((u) => u != null)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (user == null) {
      // 로그인 안 된 상태 — 재시도해도 달라지지 않는다. 절대 여기서
      // signInAnonymously()를 부르지 않는다: 새 익명 uid가 생겨 유령
      // 계정 아래 추천이 쌓이고 사용자는 영영 보지 못한다.
      return true;
    }
    final uid = user.uid;

    Map<String, dynamic>? meta;
    try {
      meta = await FirestoreService.getBackgroundAgentMeta(uid);
    } catch (e) {
      // 가드를 못 읽으면 실행하지 않는다 — 가드가 불확실한 채로 파이프라인이
      // 도는 것보다 이번 실행을 거르는 게 낫다.
      debugPrint('[BG] 가드 읽기 실패, 이번 실행 건너뜀: $e');
      return true;
    }

    final lastRunAt = (meta?['lastRunAt'] as Timestamp?)?.toDate();
    final now = DateTime.now();
    // adjustedIntervalHours(docs/task_agent_cadence_v1.md §8) — 발화 정책
    // 자기 조정이 낸 값. 필드가 없으면(아직 한 번도 조정 안 됨, 또는
    // 조정 로직 도입 이전 문서) 기존 상수 _minInterval을 그대로 쓴다 —
    // 이 폴백이 기존 동작과의 diff 0을 보장한다.
    final adjustedIntervalHours = (meta?['adjustedIntervalHours'] as num?)?.toInt();
    final effectiveMinInterval = adjustedIntervalHours != null
        ? Duration(hours: adjustedIntervalHours)
        : _minInterval;
    final skippedByGuard = !shouldRunNow(
      lastRunAt: lastRunAt,
      now: now,
      force: force,
      minInterval: effectiveMinInterval,
    );

    // F'.3 발화 간격 계측 — invokeCount/skipCount는 위 주석대로 "meta 읽기
    // 성공까지 도달한 실행"만 센다. invocationLog는 시계열(구간 목록)이
    // 필요해서이고(단일 필드 덮어쓰기로는 마지막 값만 남아 간격이 안 나옴),
    // 상한(500)을 두어 무한히 자라지 않게 한다 — main.dart의 3시간 주기
    // 기준 남은 측정 기간(~30일) 최대 발화(240회)의 2배 여유. 상한 미만에서는
    // arrayUnion으로 원자적 append(동시 실행에 안전, 추가 read 없음), 상한에
    // 닿았을 때만 이미 읽어둔 meta로 잘라서 통짜로 덮어쓴다(그 경계에서만
    // read-modify-write 경합 가능 — 500회에 한 번꼴이라 감수). 이 쓰기가
    // 실패해도 콜백 전체를 죽이지 않는다: 스킵 경로면 그대로 스킵, 통과
    // 경로면 그대로 파이프라인을 계속한다. at은 기기 시계다(이 문서의 다른
    // 시각 필드도 전부 기기 시계라 서버 시각 검증 수단이 없다) — 간격은
    // invocationLog 내부 at끼리만 계산해야 한다.
    try {
      final currentLog = (meta?['invocationLog'] as List?) ?? const [];
      final entry = {'at': Timestamp.fromDate(now), 'skipped': skippedByGuard};
      final invocationLogUpdate = currentLog.length >= _invocationLogCap
          ? [...currentLog.skip(currentLog.length - _invocationLogCap + 1), entry]
          : FieldValue.arrayUnion([entry]);
      await FirestoreService.setBackgroundAgentMeta(uid, {
        'invocationLog': invocationLogUpdate,
        'invokeCount': FieldValue.increment(1),
        if (skippedByGuard) 'skipCount': FieldValue.increment(1),
        // 이번 실행의 로컬 카운터 쓰기가 실패했으면 Firestore로도 회수한다 —
        // 로컬 파일 자체는 릴리스에서 debugPrint 외에 증거를 안 남기므로,
        // 이 쓰기가 그 실패를 관측 가능하게 만드는 유일한 경로다.
        if (lastLocalCounterError != null) 'localCounterError': lastLocalCounterError,
      });
    } catch (e) {
      debugPrint('[BG] invocationLog 기록 실패(무시): $e');
    }

    if (skippedByGuard) {
      return true;
    }

    // startedAt을 먼저 기록해야 "실행이 아예 안 걸렸다"와 "실행되다 OS에
    // 죽었다"를 구분할 수 있다. 이 쓰기가 실패하면 마찬가지로 실행하지 않는다.
    try {
      await FirestoreService.setBackgroundAgentMeta(uid, {
        'startedAt': Timestamp.fromDate(now),
      });
    } catch (e) {
      debugPrint('[BG] 가드 쓰기(startedAt) 실패, 이번 실행 건너뜀: $e');
      return true;
    }

    var resultCreated = 0;
    String? lastError;
    try {
      // 6-1. 상태 지속성 복구 — 실패한 태스크를 이어서 처리(최대 2건).
      await AgentSweeper.run(uid);
      // 6-2. API 호출 분산 — main.dart의 AppShell.initState와 동일한 취지.
      await Future.delayed(const Duration(seconds: 3));
      // 6-3. 선제 추천. WorkManager 실행 시간 한도(~10분) 때문에 가장
      // 가까운 일정 2건까지만 처리한다(앱 내 호출은 제한 없음, 영향 없음).
      final result = await AgentPlanner.runProactiveCheck(uid, maxPlans: 2);
      resultCreated = result.created;
      // 6-4. 새 추천이 생겼을 때만 알림 — 없는데 알림이 오면 사용자가 금방
      // 끈다. 하루 상한은 이미 빈도 가드(10시간)가 맡고 있다.
      if (result.created > 0 && result.firstLabel != null) {
        try {
          await NotificationService.init();
          await NotificationService.showRecommendationReady(result.firstLabel!);
        } catch (e) {
          debugPrint('[BG] 알림 발송 실패(무시): $e');
        }
      }
    } catch (e) {
      // AgentSweeper.run / AgentPlanner.runProactiveCheck는 내부에서 이미
      // 예외를 삼키므로 원칙적으로 여기 도달하지 않는다 — 방어적으로만 남긴다.
      lastError = '$e';
      debugPrint('[BG] 파이프라인 예외: $e');
    }

    // 6-5. 로그 드레인. agent_planner.dart의 활동 로그 쓰기(addAgentLogSilently)
    // 상당수가 unawaited로 던져진다 — 포그라운드에서는 아이솔레이트가 계속
    // 살아 있어 문제없지만, 이 콜백은 반환되는 순간 아이솔레이트가 종료되어
    // 완료되지 않은 Firestore 쓰기가 잘려나갈 수 있다. 보장이 아니라 유예다.
    // 근본 해법(전부 await로 전환)은 범위가 크고 동기 흐름의 지연을 늘려
    // 하지 않는다 — 여기서 짧게 기다리는 것으로 한계를 감수한다.
    await Future.delayed(const Duration(seconds: 3));

    // 6-6. 발화 정책 자기 조정 판정(docs/task_agent_cadence_v1.md §4~§8).
    // 판정 자체(judgeCadence)와 입력 산출(summarizeRecentResponses)이
    // 분리돼 있는 이유는 §4-4가 사전 등록한 대로, 나중에 이 입력이
    // (a)의 발송-탭 매칭 데이터로 교체될 때 판정부·그 단위 테스트를
    // 건드리지 않기 위해서다 — 여기(배선부)만 입력 산출 함수 교체에
    // 맞춰 바뀐다. 이 판정이 실패해도 이번 실행 자체(추천 생성 등)는
    // 이미 끝났으므로 실행을 막지 않는다 — lastRunAt 기록과 같은
    // 실패 관용도로 다룬다.
    CadenceDecision? cadenceDecision;
    try {
      final recentRecs = await FirestoreService.recentRecommendationsSilently(uid);
      final signal = summarizeRecentResponses(candidates: recentRecs, now: DateTime.now());
      cadenceDecision = judgeCadence(
        currentIntervalHours: effectiveMinInterval.inHours,
        sampleSize: signal.sampleSize,
        respondedCount: signal.respondedCount,
        noResponseCount: signal.noResponseCount,
        acceptedCount: signal.acceptedCount,
      );
    } catch (e) {
      debugPrint('[BG] 발화 정책 판정 실패(무시): $e');
    }

    // 6-7. 조정이 실제로 있을 때만 활동 로그(서사)에 남긴다 — 유지 판단은
    // 위 6-6이 agent_meta에 이미 기록했다(진단 채널, §6-2). 감지·조정을
    // 별도 이벤트 두 건으로 남기는 이유는 다른 파이프라인과 같다 — "무엇을
    // 감지했는지"와 "그래서 무엇을 했는지"가 같은 문장에 섞이면 활동 로그
    // 화면에서 판단 근거와 결과가 구분되지 않는다.
    if (cadenceDecision != null && cadenceDecision.changed) {
      final fromHours = effectiveMinInterval.inHours;
      final toHours = cadenceDecision.recommendedIntervalHours;
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCadenceSignalDetected,
          message: cadenceDecision.signalReason,
        ),
      ));
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCadenceAdjusted,
          message: '발화 간격을 $fromHours시간에서 $toHours시간으로 조정합니다',
        ),
      ));
    }

    try {
      await FirestoreService.setBackgroundAgentMeta(uid, {
        'lastRunAt': Timestamp.fromDate(DateTime.now()),
        'lastResultCreated': resultCreated,
        'lastError': lastError,
        // 진단용 — 날씨 API 실패율을 실행 이력과 함께 추적하기 위한 표시.
        // 실패해도 실행에는 영향을 주지 않는다(WeatherService 호출부는
        // 이미 null 폴백으로 조용히 넘어간다). 이번 실행에서 날씨를 한
        // 번도 조회하지 않았으면(예: 처리할 일정이 없어 조기 반환) 기본값
        // true가 그대로 유지된다.
        'lastWeatherOk': WeatherService.lastFetchOk,
        // 누적 카운터 — FieldValue.increment는 필드가 없으면 0에서
        // 시작하므로 기존 문서에 없던 필드라도 별도 초기화가 필요 없다.
        'weatherTotalCount': FieldValue.increment(1),
        'weatherOkCount': FieldValue.increment(WeatherService.lastFetchOk ? 1 : 0),
        // 조정이 없었을 때도 매번 남긴다(docs §6-2) — agent_logs(서사)는
        // 조정이 실제로 있을 때만 남기지만(4/5 단계에서 배선), 이 진단
        // 필드는 "판단했으나 유지했다"까지 항상 관측 가능해야 한다.
        if (cadenceDecision != null) ...{
          'adjustedIntervalHours': cadenceDecision.recommendedIntervalHours,
          'lastCadenceReason': cadenceDecision.signalReason,
          'lastCadenceCheckAt': Timestamp.fromDate(DateTime.now()),
        },
      });
    } catch (e) {
      // 완료 기록 실패는 다음 실행 판단에 영향을 주지만, 이번 실행 자체는
      // 이미 끝났으므로 재시도를 요청하지 않는다.
      debugPrint('[BG] 가드 쓰기(lastRunAt) 실패: $e');
    }

    return true;
  }
}
