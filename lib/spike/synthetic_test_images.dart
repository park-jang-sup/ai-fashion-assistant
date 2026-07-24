import 'dart:math';

import 'package:image/image.dart' as img;

/// [스파이크 전용] 삼각 유사도 테스트용 합성 이미지 3장.
/// 실제 옷 사진 대신 색상+약한 노이즈로 근사한다: A=검은 상의,
/// B=A와 비슷한 다른 검은 상의, C=전혀 다른 청바지. 네트워크나 실사진
/// 의존 없이 파이프라인 동작(로드→전처리→추론→정규화)만 검증하면
/// 되므로 이 정도 근사로 충분하다.
class SyntheticTestImages {
  static img.Image blackTopA() =>
      _solidWithNoise(base: const [20, 20, 22], noiseAmplitude: 6, seed: 1);

  static img.Image blackTopB() =>
      _solidWithNoise(base: const [24, 22, 26], noiseAmplitude: 6, seed: 2);

  static img.Image jeansC() =>
      _solidWithNoise(base: const [70, 95, 150], noiseAmplitude: 18, seed: 3);

  static img.Image _solidWithNoise({
    required List<int> base,
    required int noiseAmplitude,
    required int seed,
    int size = 320,
  }) {
    final rnd = Random(seed);
    final image = img.Image(width: size, height: size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final n = rnd.nextInt(noiseAmplitude * 2) - noiseAmplitude;
        image.setPixelRgb(
          x,
          y,
          (base[0] + n).clamp(0, 255),
          (base[1] + n).clamp(0, 255),
          (base[2] + n).clamp(0, 255),
        );
      }
    }
    return image;
  }
}
