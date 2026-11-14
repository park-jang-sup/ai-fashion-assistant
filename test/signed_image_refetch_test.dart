// SignedNetworkImage 방어(2026-11-15 등록 직후 빈 사진, 원인은 확정하지 못함) — 받아 둔 서명 주소 목록에
// 원하는 번호(누끼)가 없으면 목록을 버리고 서버에 한 번 다시 받는다. 다시 받아도 없으면 폴백, 같은 문서는
// 한 번만 다시 받는다. 서버는 ImageUrlResolver.testServerCall로 흉내 낸다.
import 'package:ai_fashion_assistant/services/image_url_resolver.dart';
import 'package:ai_fashion_assistant/widgets/signed_network_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _resp(List<({String collection, String id})> items, List<String> urls) => {
      for (final i in items)
        i.id: {'urls': urls, 'expiresAt': DateTime.now().add(const Duration(hours: 1)).toIso8601String()},
    };

Widget _image(String id) => MaterialApp(
      home: SignedNetworkImage(
        key: UniqueKey(), // 매번 새 위젯(didUpdateWidget을 거치지 않는 경로)
        collection: 'wardrobe',
        id: id,
        urlIndex: 1, // 누끼
        fallbackUrl: 'https://fallback.example/$id',
        errorWidget: (_, __, ___) => const SizedBox(),
        placeholder: (_, __) => const SizedBox(),
      ),
    );

String _shownUrl(WidgetTester tester) => tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage)).imageUrl;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 5));
}

void main() {
  setUp(() {
    ImageUrlResolver.resetForTest();
    ImageUrlResolver.retryBackoffBase = const Duration(milliseconds: 1);
    resetSignedImageRefetchForTest();
  });
  tearDown(ImageUrlResolver.resetForTest);

  testWidgets('받아 둔 목록에 원본만 있고 누끼를 찾으면 — 다시 받아 누끼를 보여 준다', (tester) async {
    // 누끼가 생기기 전에 받아 둔 목록(원본 하나)이 캐시에 있다
    ImageUrlResolver.testServerCall = (items) async => _resp(items, ['https://signed.example/img']);
    // 묶음 요청 타이머가 가짜 시계에서는 돌지 않으므로 실제 시간으로 미리 받아 둔다
    await tester.runAsync(() => ImageUrlResolver.resolve(collection: 'wardrobe', id: 'd1'));
    var calls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      calls++;
      return _resp(items, ['https://signed.example/img', 'https://signed.example/cut']);
    };
    await tester.pumpWidget(_image('d1'));
    await _settle(tester);
    expect(calls, 1);
    expect(_shownUrl(tester), 'https://signed.example/cut');
    await _done(tester);
  });

  testWidgets('다시 받아도 누끼가 없으면 — 지금의 폴백(옛 주소)', (tester) async {
    var calls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      calls++;
      return _resp(items, ['https://signed.example/img']);
    };
    await tester.pumpWidget(_image('d2'));
    await _settle(tester);
    expect(calls, 2); // 처음 받기 + 다시 받기 한 번
    expect(_shownUrl(tester), 'https://fallback.example/d2');
    await _done(tester);
  });

  testWidgets('다시 받기는 같은 문서에 한 번만 — 위젯이 새로 만들어져도 다시 요청하지 않는다', (tester) async {
    var calls = 0;
    ImageUrlResolver.testServerCall = (items) async {
      calls++;
      return _resp(items, ['https://signed.example/img']);
    };
    await tester.pumpWidget(_image('d3'));
    await _settle(tester);
    expect(calls, 2);
    for (var k = 0; k < 3; k++) {
      await tester.pumpWidget(_image('d3'));
      await _settle(tester);
    }
    expect(calls, 2); // 캐시에서 원본만 받고 더 다시 받지 않는다
    expect(_shownUrl(tester), 'https://fallback.example/d3');
    await _done(tester);
  });
}
