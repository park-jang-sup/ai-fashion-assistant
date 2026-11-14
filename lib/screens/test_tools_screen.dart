part of 'settings_screen.dart';

// 테스트 도구 — 개발과 시연 확인용 기능을 설정 화면에서 옮겨 모았다(위치만 옮김, 이름·설명·동작은
// 그대로). 설정 화면 "정보" 묶음의 "테스트 도구" 줄에서 연다.
const _assumptionLabels = {
  ForecastAssumption.none: '없음',
  ForecastAssumption.rain: '비',
  ForecastAssumption.hot: '더운 날',
  ForecastAssumption.mild: '온화한 날',
  ForecastAssumption.cool: '선선한 날',
  ForecastAssumption.cold: '추운 날',
};

class TestToolsScreen extends StatefulWidget {
  const TestToolsScreen({super.key});

  @override
  State<TestToolsScreen> createState() => _TestToolsScreenState();
}

class _TestToolsScreenState extends State<TestToolsScreen> {
  // agent_meta 스트림과 별개로 관리한다 — D 케이스(로그아웃 상태에서 조기
  // 반환)처럼 agent_meta를 건드리지 않는 실행은 스트림이 emit하지 않아
  // 이 값이 그 안에 있으면 영영 안 바뀐다(2026-07-31 실기기 관측). 화면
  // 진입 시 한 번 읽고, 수동 새로고침으로만 갱신한다.
  ({String path, bool exists, int value, String? lastError})? _localCounterDiag;

  // 예보 가정(테스트용) — docs/task_agent_grounding_v1.md §4-4. 기기에만 저장.
  ForecastAssumption _forecastAssumption = ForecastAssumption.none;

  @override
  void initState() {
    super.initState();
    _refreshLocalCounterDiagnostics();
    WeatherService.loadAssumption().then((a) {
      if (mounted) setState(() => _forecastAssumption = a);
    });
  }

  Future<void> _setForecastAssumption(ForecastAssumption a) async {
    try {
      await WeatherService.saveAssumption(a);
      if (mounted) setState(() => _forecastAssumption = a);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('예보 가정을 저장하지 못했어요: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Widget _buildForecastAssumptionRow() {
    return _SettingsRow(
      label: '예보 가정(테스트용)',
      sub: _forecastAssumption == ForecastAssumption.none
          ? '실제 예보를 씁니다'
          : '실제 예보 대신 가정한 예보로 추천합니다 — 추천 문구에 "(테스트용 가정 예보)"가 붙습니다',
      trailing: DropdownButton<ForecastAssumption>(
        value: _forecastAssumption,
        underline: const SizedBox.shrink(),
        items: [
          for (final a in ForecastAssumption.values)
            DropdownMenuItem(value: a, child: Text(_assumptionLabels[a]!)),
        ],
        onChanged: (a) {
          if (a != null) _setForecastAssumption(a);
        },
      ),
    );
  }

  Future<void> _refreshLocalCounterDiagnostics() async {
    final diag = await BackgroundAgent.readLocalCounterDiagnostics();
    if (mounted) setState(() => _localCounterDiag = diag);
  }

  // B단계 검증용 — 3시간 주기를 기다리지 않고 즉시 확인한다. force: true로
  // 빈도 가드를 우회한다.
  void _triggerBackgroundNow() {
    Workmanager().registerOneOffTask(
      'dot-bg-manual-${DateTime.now().millisecondsSinceEpoch}',
      'proactiveCheck',
      inputData: {'force': true},
    );
  }

  // 시연용 — 버튼 → 앱 완전 종료 → 잠금화면 알림 순서로 촬영하기 위해 30초
  // 지연을 둔다. 즉시 실행은 앱이 열린 상태에서 알림이 뜨므로 "앱을 안
  // 켜도 준비된다"의 증명이 되지 못한다.
  void _triggerBackgroundDelayed() {
    Workmanager().registerOneOffTask(
      'dot-bg-delayed-${DateTime.now().millisecondsSinceEpoch}',
      'proactiveCheck',
      initialDelay: const Duration(seconds: 30),
      inputData: {'force': true},
    );
  }

  // F'.3 계측 검증용 — inputData 없이 등록한다. backgroundCallbackDispatcher가
  // `inputData?['force'] == true`로 읽으므로 이 경로는 force:false로
  // run()에 들어가 실제 빈도 가드(shouldRunNow)를 그대로 태운다. 위 두
  // 버튼은 force:true라 가드를 항상 우회해 skipped:true를 온디맨드로 만들
  // 수 없었다 — 이 버튼이 그 결핍을 메운다. 직전에 위 버튼 중 하나를 눌러
  // lastRunAt이 10시간 이내로 갱신된 상태라면, 이 실행은 invocationLog에
  // skipped:true로 기록된다.
  void _triggerBackgroundNaturalCadence() {
    Workmanager().registerOneOffTask(
      'dot-bg-natural-${DateTime.now().millisecondsSinceEpoch}',
      'proactiveCheck',
    );
  }

  // B단계 진단용 — 이 uid에 등록된 모든 기기로 서버가 실제로 푸시를
  // 보낼 수 있는지 확인한다. 토큰이 0건이면 "아직 등록 안 됨"과 발송
  // 실패를 구분해서 안내한다.
  Future<void> _sendTestPush() async {
    try {
      final result = await FcmService.sendTestPush();
      if (!mounted) return;
      final message = result.tokenCount == 0
          ? '등록된 기기가 없습니다. 잠시 후 다시 시도해주세요.'
          : '${result.tokenCount}개 기기 중 ${result.sentCount}개로 발송했습니다.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('FCM 테스트 푸시 실패: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }

  // agent_meta/background 문서를 실시간 표시 — "백그라운드가 안 돌고
  // 있는데 모르는" 상황을 막는 유일한 장치(B.5).
  Widget _buildBackgroundStatus(String uid) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: settingsBackgroundMetaStream(uid),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('아직 실행 기록 없음',
                style: TextStyle(color: AppColors.textPlaceholder, fontSize: 11)),
          );
        }
        final fmt = DateFormat('MM/dd HH:mm:ss');
        final startedAt = (data['startedAt'] as Timestamp?)?.toDate();
        final lastRunAt = (data['lastRunAt'] as Timestamp?)?.toDate();
        final lastError = data['lastError'] as String?;
        final incomplete = startedAt != null &&
            (lastRunAt == null || startedAt.isAfter(lastRunAt));
        final invokeCount = data['invokeCount'] as int?;
        final skipCount = data['skipCount'] as int?;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '마지막 완료: ${lastRunAt != null ? fmt.format(lastRunAt) : '없음'}',
                style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
              ),
              if (incomplete)
                const Text('⚠ 마지막 실행이 완료되지 않음',
                    style: TextStyle(color: AppColors.red, fontSize: 11)),
              if (lastError != null)
                Text('오류: $lastError',
                    style: const TextStyle(color: AppColors.red, fontSize: 11)),
              // F'.3 발화 계측 — invokeCount는 "uid+meta 읽기 성공까지 도달한
              // 실행 수"(agent_meta), 아래 로컬 카운터는 Firestore·auth와
              // 무관한 "OS가 콜백을 부른 수"(기기 로컬 파일). 둘의 차이가
              // 곧 인증/초기화 단계에서 죽은 실행 수다.
              if (invokeCount != null)
                Text(
                  'invokeCount: $invokeCount'
                  '${skipCount != null ? ' (skip $skipCount)' : ''}',
                  style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
                ),
            ],
          ),
        );
      },
    );
  }

  // agent_meta 스트림과 무관하게(위 _buildBackgroundStatus와 별도) 항상 그릴
  // 수 있어야 한다 — data == null(실행 기록 없음) 상태에서도 로컬 카운터는
  // 기기 단위로 이미 존재할 수 있다. 오른쪽 새로고침 아이콘으로 언제든 다시
  // 읽는다(D처럼 agent_meta를 안 건드리는 실행 뒤에도 값을 확인하려면
  // 스트림 emit을 기다릴 수 없다).
  Widget _buildLocalCounterDiagnostics() {
    final diag = _localCounterDiag;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: diag == null
                ? const Text(
                    '로컬 카운터 읽는 중...',
                    style: TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
                  )
                : Text(
                    '로컬 발화 카운터: ${diag.value}'
                    '${diag.exists ? '' : ' (파일 없음)'}'
                    '${diag.lastError != null ? '\n오류: ${diag.lastError}' : ''}'
                    '\n경로: ${diag.path}',
                    style: const TextStyle(color: AppColors.textPlaceholder, fontSize: 11),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            tooltip: '다시 읽기',
            onPressed: _refreshLocalCounterDiagnostics,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = settingsCurrentUser()?.uid;
    final showBackgroundDiagnostics =
        defaultTargetPlatform == TargetPlatform.android && uid != null;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text('테스트 도구', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: SingleChildScrollView(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('개발과 시연 확인용 기능입니다. 일반 사용에는 필요하지 않습니다.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                const SizedBox(height: 28),
                const _SectionLabel('알림'),
                _SettingsRow(
                  label: '테스트 알림 보내기',
                  onTap: () =>
                      NotificationService.showRecommendationReady('내일 [결혼식]'),
                ),
                _SettingsRow(
                  label: 'FCM 테스트 푸시',
                  sub: '서버가 이 계정의 등록 기기로 직접 보냅니다',
                  onTap: _sendTestPush,
                ),
                if (showBackgroundDiagnostics) ...[
                  const SizedBox(height: 28),
                  const _SectionLabel('백그라운드 에이전트'),
                  _buildForecastAssumptionRow(),
                  _SettingsRow(label: '즉시 실행 (테스트)', onTap: _triggerBackgroundNow),
                  _SettingsRow(
                    label: '지연 실행 30초 (시연용)',
                    sub: '누른 뒤 앱을 완전히 종료해도 실행됩니다',
                    onTap: _triggerBackgroundDelayed,
                  ),
                  _SettingsRow(
                    label: '주기 실행 시뮬레이션 (가드 적용)',
                    sub: 'force 없이 등록 — 최근 실행이 있으면 skipped로 기록됩니다',
                    onTap: _triggerBackgroundNaturalCadence,
                  ),
                  const SizedBox(height: 28),
                  const _SectionLabel('진단 정보'),
                  // seed.py --owner-uid / report.py가 둘 다 uid를 요구하는데
                  // 앱에 노출되는 곳이 없어 여기 붙인다. 탭하면 복사.
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: uid));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('uid를 복사했습니다'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'uid: $uid (탭하여 복사)',
                        style: const TextStyle(
                          color: AppColors.textPlaceholder,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  _buildLocalCounterDiagnostics(),
                  _buildBackgroundStatus(uid),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
