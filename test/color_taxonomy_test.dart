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
      '퍼플': (family: 'purple', brightness: ColorBrightness.medium, isNeutral: false),
      '보라': (family: 'purple', brightness: ColorBrightness.medium, isNeutral: false),
      '바이올렛': (family: 'purple', brightness: ColorBrightness.medium, isNeutral: false),
      '라벤더': (family: 'purple', brightness: ColorBrightness.light, isNeutral: false),
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

    // 퍼플은 레드기/블루기에 따라 웜쿨이 갈리는 대표색이라 temperature를
    // neutral로 못박았다 — 이 결정이 유지되는지 별도 확인.
    test('퍼플/보라/바이올렛/라벤더 → temperature는 neutral(웜쿨 안 정함)', () {
      for (final label in ['퍼플', '보라', '바이올렛', '라벤더']) {
        expect(ColorTaxonomy.resolve(label).temperature, ColorTemperature.neutral, reason: label);
      }
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
    test('다크바이올렛 → purple family', () {
      expect(ColorTaxonomy.resolve('다크바이올렛').family, 'purple');
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

  group('매트릭스', () {
    test('red-wine은 0(톤온톤 오판 방지, 감점도 아님)', () {
      expect(ColorTaxonomy.matrixScore('red', 'wine'), 0);
    });
    test('red-green은 -1(보색)', () {
      expect(ColorTaxonomy.matrixScore('red', 'green'), -1);
    });
    test('green-pink는 0(톤다운 조합 흔함)', () {
      expect(ColorTaxonomy.matrixScore('green', 'pink'), 0);
    });
    test('brown은 pink 제외 전부 +1(서브뉴트럴 취급)', () {
      for (final f in ['wine', 'red', 'orange', 'yellow', 'green', 'blue']) {
        expect(ColorTaxonomy.matrixScore('brown', f), 1, reason: 'brown-$f');
      }
      expect(ColorTaxonomy.matrixScore('brown', 'pink'), 0);
    });
    test('purple — blue/pink/brown은 +1(인접색·브라운 우대), 그 외는 0(근거 약함)', () {
      for (final f in ['blue', 'pink', 'brown']) {
        expect(ColorTaxonomy.matrixScore('purple', f), 1, reason: 'purple-$f');
      }
      for (final f in ['wine', 'red', 'orange', 'yellow', 'green']) {
        expect(ColorTaxonomy.matrixScore('purple', f), 0, reason: 'purple-$f');
      }
    });
    test('매트릭스는 대칭이다', () {
      const families = [
        'wine', 'red', 'orange', 'yellow', 'green', 'blue', 'pink', 'brown', 'purple',
      ];
      for (final a in families) {
        for (final b in families) {
          if (a == b) continue;
          expect(ColorTaxonomy.matrixScore(a, b), ColorTaxonomy.matrixScore(b, a),
              reason: '$a-$b 비대칭');
        }
      }
    });
  });
}
