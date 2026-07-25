// 색상 정규화 테이블 단위 검증 — 궁합 규칙 보강의 전제 조건. 이게 틀리면
// 그 위의 모든 매트릭스/톤온톤 규칙이 무의미해지므로 가장 먼저 통과시킨다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/color_taxonomy.dart';

void main() {
  group('정확 매칭 — 실기기 로그에서 관측된 24개 라벨 전부', () {
    const expected = <String, ({String? family, ColorBrightness brightness, bool isNeutral})>{
      '블랙': (family: null, brightness: ColorBrightness.dark, isNeutral: true),
      '화이트': (family: null, brightness: ColorBrightness.light, isNeutral: true),
      '네이비': (family: null, brightness: ColorBrightness.dark, isNeutral: true),
      '그레이': (family: null, brightness: ColorBrightness.medium, isNeutral: true),
      '회색': (family: null, brightness: ColorBrightness.medium, isNeutral: true),
      '차콜': (family: null, brightness: ColorBrightness.dark, isNeutral: true),
      '베이지': (family: null, brightness: ColorBrightness.light, isNeutral: true),
      '아이보리': (family: null, brightness: ColorBrightness.light, isNeutral: true),
      '카키': (family: null, brightness: ColorBrightness.medium, isNeutral: true),
      '그레이지': (family: null, brightness: ColorBrightness.light, isNeutral: true),
      '크림': (family: null, brightness: ColorBrightness.light, isNeutral: true),
      '에크루': (family: null, brightness: ColorBrightness.light, isNeutral: true),
      '와인': (family: 'wine', brightness: ColorBrightness.dark, isNeutral: false),
      '버건디': (family: 'wine', brightness: ColorBrightness.dark, isNeutral: false),
      '레드': (family: 'red', brightness: ColorBrightness.medium, isNeutral: false),
      '핑크': (family: 'pink', brightness: ColorBrightness.light, isNeutral: false),
      '옐로우': (family: 'yellow', brightness: ColorBrightness.medium, isNeutral: false),
      '블루': (family: 'blue', brightness: ColorBrightness.medium, isNeutral: false),
      '스카이블루': (family: 'blue', brightness: ColorBrightness.light, isNeutral: false),
      '인디고': (family: 'blue', brightness: ColorBrightness.dark, isNeutral: false),
      '브라운': (family: 'brown', brightness: ColorBrightness.dark, isNeutral: false),
      '카멜': (family: 'brown', brightness: ColorBrightness.medium, isNeutral: false),
      '오렌지': (family: 'orange', brightness: ColorBrightness.medium, isNeutral: false),
      '그린': (family: 'green', brightness: ColorBrightness.medium, isNeutral: false),
    };

    for (final entry in expected.entries) {
      test('${entry.key} → family=${entry.value.family}, '
          'brightness=${entry.value.brightness}, isNeutral=${entry.value.isNeutral}', () {
        final r = ColorTaxonomy.resolve(entry.key);
        expect(r.family, entry.value.family);
        expect(r.brightness, entry.value.brightness);
        expect(r.isNeutral, entry.value.isNeutral);
      });
    }

    // 관측되진 않았지만 테이블에 넣은 추가 라벨(올리브) — 가족 중복 확인용.
    test('올리브 → green family, 무채색 아님', () {
      final r = ColorTaxonomy.resolve('올리브');
      expect(r.family, 'green');
      expect(r.isNeutral, false);
    });
  });

  group('tier2 — 부분 문자열 매칭(수식어 흡수)', () {
    test('라이트그레이 → neutral(그레이 흡수)', () {
      expect(ColorTaxonomy.resolve('라이트그레이').isNeutral, true);
    });
    test('톤다운블루 → blue family', () {
      expect(ColorTaxonomy.resolve('톤다운블루').family, 'blue');
    });
    test('다크브라운 → brown family', () {
      expect(ColorTaxonomy.resolve('다크브라운').family, 'brown');
    });
    test('딥 네이비(공백 포함) → neutral', () {
      expect(ColorTaxonomy.resolve('딥 네이비').isNeutral, true);
    });
    test('긴 라벨 우선 — 라이트스카이블루 → 스카이블루로 매칭(블루 아님)', () {
      final r = ColorTaxonomy.resolve('라이트스카이블루');
      expect(r.family, 'blue');
      expect(r.brightness, ColorBrightness.light);
    });
  });

  group('tier3 — 매핑 실패 폴백', () {
    test('완전 미지의 라벨 → family null, isNeutral false, 중립 폴백', () {
      final r = ColorTaxonomy.resolve('라일락');
      expect(r.family, isNull);
      expect(r.isNeutral, false);
      expect(r.brightness, ColorBrightness.medium);
      expect(r.temperature, ColorTemperature.neutral);
    });
    test('빈 문자열 → 폴백', () {
      final r = ColorTaxonomy.resolve('');
      expect(r.family, isNull);
      expect(r.isNeutral, false);
    });
  });
}
