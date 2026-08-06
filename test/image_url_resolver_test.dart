import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/image_url_resolver.dart';

// A-6(docs/task_signed_urls_v1.md §9 사고의 재발 방지) — 배치 발급
// 실패 시 재시도·격리·재시도 가능 상태를 단위 테스트로 검증한다.
// FirebaseFunctions는 실제로 안 부른다 — ImageUrlResolver.testServerCall로
// 서버 응답/실패를 직접 주입한다.
void main() {
  setUp(() {
    ImageUrlResolver.resetForTest();
    ImageUrlResolver.retryBackoffBase = const Duration(milliseconds: 1);
  });

  tearDown(() {
    ImageUrlResolver.resetForTest();
  });

  Map<String, dynamic> fakeResponse(List<({String collection, String id})> items) {
    return {
      for (final i in items)
        i.id: {
          'urls': ['https://signed.example/${i.id}'],
          'expiresAt': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
        },
    };
  }

  test('배치 호출이 두 번 실패하고 세 번째(최종 재시도)에 성공하면 결과가 반영된다', () async {
    var calls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      calls++;
      if (calls < 3) throw Exception('네트워크 순간 오류');
      return fakeResponse(items);
    };

    final urls = await ImageUrlResolver.resolve(collection: 'wardrobe', id: 'itemA');

    expect(calls, 3, reason: '최초 시도 1회 + 재시도 2회 = 3회');
    expect(urls, ['https://signed.example/itemA']);
    expect(ImageUrlResolver.fallbackCount, 0);
  });

  test('재시도를 전부 소진해도 실패하면 null(폴백 신호)을 반환하고, 실패한 항목은 진행중 상태로 남지 않아 다음 resolve()에서 다시 시도된다', () async {
    var failingCalls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      failingCalls++;
      throw Exception('영구 오류');
    };

    final first = await ImageUrlResolver.resolve(collection: 'wardrobe', id: 'itemB');

    expect(first, isNull);
    expect(failingCalls, 3, reason: '최초 시도 1회 + 재시도 2회 = 3회 후 포기');
    expect(ImageUrlResolver.fallbackCount, 1);

    // 실패한 id가 _pending에 남아 굳어 있으면 이 두 번째 호출이 첫
    // 번째와 같은 Future를 공유하며 서버를 다시 안 부른다 — 굳지
    // 않았다면 새 배치로 다시 발사돼야 한다.
    var secondCalls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      secondCalls++;
      return fakeResponse(items);
    };
    final second = await ImageUrlResolver.resolve(collection: 'wardrobe', id: 'itemB');

    expect(second, ['https://signed.example/itemB']);
    expect(secondCalls, 1, reason: '재시도 없이 한 번에 성공(정상 서버 응답)');
  });

  test('한 배치의 실패가 다른(별도 코얼레싱 창의) 요청에 전파되지 않는다', () async {
    ImageUrlResolver.testServerCall = (items) async {
      if (items.any((i) => i.id == 'fail')) {
        throw Exception('이 배치만 실패');
      }
      return fakeResponse(items);
    };

    // 첫 요청을 완전히 끝낸 뒤(await) 다음 요청을 시작해 서로 다른
    // flush 사이클(별도 청크)에 걸리게 한다 — 청크 단위 격리 확인.
    final failing = await ImageUrlResolver.resolve(collection: 'wardrobe', id: 'fail');
    final okay = await ImageUrlResolver.resolve(collection: 'wardrobe', id: 'ok');

    expect(failing, isNull);
    expect(okay, ['https://signed.example/ok']);
  });

  test('같은 코얼레싱 창(같은 배치) 안에서는 일부만 실패할 수 없다 — 배치 전체가 예외 하나로 실패/재시도된다', () async {
    var calls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      calls++;
      throw Exception('배치 전체 실패');
    };

    final results = await Future.wait([
      ImageUrlResolver.resolve(collection: 'wardrobe', id: 'x1'),
      ImageUrlResolver.resolve(collection: 'wardrobe', id: 'x2'),
    ]);

    expect(results, [null, null], reason: '같은 배치라 둘 다 함께 폴백된다(정상 동작)');
    expect(ImageUrlResolver.fallbackCount, 2);
    expect(calls, 3, reason: '배치 자체는 한 번만 재시도 시퀀스를 탄다(청크 1개)');
  });
}
