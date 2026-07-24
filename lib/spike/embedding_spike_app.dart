import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'embedding_service.dart';
import 'synthetic_test_images.dart';

const _modelAssetPath = 'assets/spike_models/efficientnet_lite0_feature_vector.tflite';

/// [스파이크 전용] `--dart-define=RUN_EMBEDDING_SPIKE=true`로 빌드했을 때만
/// main()에서 이 앱이 실행된다(기본값 false, 일반 앱 실행에는 영향 없음).
/// 로그인/Firebase 등 본 앱 플로우를 거치지 않고 모델 로드 → 20회 반복
/// 추론 → 삼각 유사도 테스트를 독립적으로 실행해 결과를 화면과
/// debugPrint(logcat)에 남긴다. 앱 통합 여부와 무관한 실행 가능성
/// 검증용 코드다.
class EmbeddingSpikeApp extends StatefulWidget {
  const EmbeddingSpikeApp({super.key});

  @override
  State<EmbeddingSpikeApp> createState() => _EmbeddingSpikeAppState();
}

class _EmbeddingSpikeAppState extends State<EmbeddingSpikeApp> {
  final _service = EmbeddingService();
  final _log = <String>[];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _print(String line) {
    debugPrint('[임베딩스파이크] $line');
    if (mounted) setState(() => _log.add(line));
  }

  Future<void> _run() async {
    try {
      _print('모델 로드 시작 (asset: $_modelAssetPath)');
      await _service.loadModelFromAsset(_modelAssetPath);
      _print('모델 로드 완료 (output_dim=${_service.outputDim})');

      final a = SyntheticTestImages.blackTopA();
      final b = SyntheticTestImages.blackTopB();
      final c = SyntheticTestImages.jeansC();

      const iterations = 20;
      final timingsMs = <int>[];
      List<double>? embA, embB, embC;

      for (var i = 1; i <= iterations; i++) {
        final (ea, ta) = _service.embed(a);
        final (eb, tb) = _service.embed(b);
        final (ec, tc) = _service.embed(c);
        timingsMs.addAll([ta, tb, tc]);
        embA = ea;
        embB = eb;
        embC = ec;
        _print('반복 $i/$iterations 완료 (A:${ta}ms B:${tb}ms C:${tc}ms)');
      }

      final avgMs = timingsMs.reduce((x, y) => x + y) / timingsMs.length;
      final maxMs = timingsMs.reduce(math.max);

      final simAB = EmbeddingService.cosineSimilarity(embA!, embB!);
      final simAC = EmbeddingService.cosineSimilarity(embA, embC!);

      _print('=== 결과 ===');
      _print('총 추론 ${timingsMs.length}회(20반복 x 3장) 크래시 없이 완료');
      _print('추론시간 avg=${avgMs.toStringAsFixed(1)}ms max=${maxMs}ms');
      _print('sim(A,B)=${simAB.toStringAsFixed(4)}  sim(A,C)=${simAC.toStringAsFixed(4)}');
      _print(simAB > simAC
          ? '삼각 테스트 통과: sim(A,B) > sim(A,C) — 시각적 유사도만 검증됨, 모델 채택 근거 아님'
          : '삼각 테스트 실패: sim(A,B) <= sim(A,C)');
    } catch (e, st) {
      _print('예외 발생: $e');
      debugPrint('$st');
    } finally {
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('임베딩 스파이크 (검증용)')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!_done) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              for (final line in _log)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    line,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
