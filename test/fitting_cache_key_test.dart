// 가상 피팅 캐시 키 — functions/src/fitting_cache_key.test.ts와 같은 고정
// 벡터를 Dart 쪽에서 고정한다(docs/task_fitting_quality_v2.md §4-1-5).
// 서버는 클라이언트 키를 믿지 않고 같은 식으로 재계산하므로, 두 쪽이
// 어긋나면 캐시가 영원히 미스가 되는데 증상이 조용하다.
import 'package:ai_fashion_assistant/services/fitting_job_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // sha256(utf8('v2:TEST_U:a,b')) — Node crypto·Python hashlib로 교차 계산한 값.
  const expected = 'e0bd598b6ef801709da291c36f31d1a3216fc42dc22eaee0b4fdad2768560202';

  test('고정 벡터(v2, TEST_U, [a, b]) — 서버 테스트와 같은 값', () {
    expect(fittingCacheKeyFor('TEST_U', ['a', 'b']), expected);
  });

  test('입력 순서와 무관하다(정렬 후 계산)', () {
    expect(fittingCacheKeyFor('TEST_U', ['b', 'a']), expected);
  });

  test('버전 접두사 없는 옛 키와 다르다(옛 캐시 결과를 돌려주지 않음)', () {
    expect(fittingCacheKeyFor('TEST_U', ['a', 'b']),
        isNot('8f6b3aa991bcbc456d8e0b7e0e85b5cb96fb3c92fb42f15cef0f6e667911e847'));
  });

  test('원본 리스트를 변형하지 않는다', () {
    final ids = ['b', 'a'];
    fittingCacheKeyFor('TEST_U', ids);
    expect(ids, ['b', 'a']);
  });
}
