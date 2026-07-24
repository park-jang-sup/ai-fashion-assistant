import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// ⚠️ [스파이크 전용 — 앱 통합 아님] 온디바이스 이미지 임베딩이 release
/// 빌드에서 안정적으로 도는지만 검증하는 코드. 여기서 로드하는
/// EfficientNet-Lite0 헤드리스 feature-vector 모델은 파이프라인
/// 검증용 스캐폴드일 뿐 실제 채택 모델이 아니다. ImageNet 사전학습
/// feature라 "시각적 유사도"만 반영하고 "옷 스타일 궁합"은 반영하지
/// 않으므로, 이 서비스의 유사도 수치를 모델 채택 근거로 쓰면 안 된다.
class EmbeddingService {
  static const inputSize = 224;

  Interpreter? _interpreter;
  int _outputDim = 0;

  int get outputDim => _outputDim;
  bool get isReady => _interpreter != null;

  // adb push 방식(external files dir)이 이 기기(Android 16 API 36)의
  // scoped storage에서 File.existsSync()가 false를 반환하는 문제를 만나
  // asset 번들링 + fromBuffer()로 전환했다(파일시스템 경로 자체를 우회).
  // 스파이크 전용 예외 — pubspec.yaml 주석 참고.
  Future<void> loadModelFromAsset(String assetPath) async {
    final buffer = await rootBundle.load(assetPath);
    final bytes = buffer.buffer.asUint8List(buffer.offsetInBytes, buffer.lengthInBytes);
    final interpreter = Interpreter.fromBuffer(bytes);
    final outputShape = interpreter.getOutputTensor(0).shape;
    _outputDim = outputShape.last;
    _interpreter = interpreter;
    debugPrint('[임베딩스파이크] 모델 로드 완료 output_shape=$outputShape');
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }

  /// 이미지 1장 → (L2 정규화된 임베딩 벡터, 추론 소요시간 ms).
  (List<double>, int) embed(img.Image image) {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('loadModel()을 먼저 호출해야 합니다.');
    }

    final resized = img.copyResize(image, width: inputSize, height: inputSize);
    // EfficientNet 계열 표준 전처리: [0,255] -> [-1,1]
    final input = [
      List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final p = resized.getPixel(x, y);
          return [
            (p.r / 127.5) - 1.0,
            (p.g / 127.5) - 1.0,
            (p.b / 127.5) - 1.0,
          ];
        }),
      ),
    ];
    final output = [List.filled(_outputDim, 0.0)];

    final sw = Stopwatch()..start();
    interpreter.run(input, output);
    sw.stop();

    return (_l2Normalize(output[0]), sw.elapsedMilliseconds);
  }

  static List<double> _l2Normalize(List<double> v) {
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  // 두 벡터 모두 L2 정규화된 상태라고 가정 — 내적이 곧 코사인 유사도.
  static double cosineSimilarity(List<double> a, List<double> b) {
    var dot = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }
}