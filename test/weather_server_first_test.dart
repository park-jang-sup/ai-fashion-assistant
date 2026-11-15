// 예보는 서버(getForecast)를 먼저, 실패하면 Open-Meteo 직접 — 동시 요청은 하나로.
import 'dart:async';
import 'dart:convert';

import 'package:ai_fashion_assistant/data/region_presets.dart';
import 'package:ai_fashion_assistant/screens/home_screen.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _forecast(double temp) => {
      'current': {'temperature_2m': temp, 'weather_code': 0},
      'daily': {
        'time': ['2026-11-15'],
        'temperature_2m_max': [18.0],
        'temperature_2m_min': [9.0],
        'precipitation_probability_max': [10],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // 예보 가정 파일 읽기가 실패해도 "없음"

  late int directCalls;
  late List<String?> fnKeys;

  void use({required Future<Map<String, dynamic>> Function(String? key) fn}) {
    directCalls = 0;
    fnKeys = [];
    WeatherService.configureForTest(
      client: MockClient((_) async {
        directCalls++;
        return http.Response(jsonEncode(_forecast(5)), 200);
      }),
      requestTimeout: const Duration(milliseconds: 50),
      forecastFunction: (key) {
        fnKeys.add(key);
        return fn(key);
      },
    );
  }

  test('함수가 성공하면 직접 요청을 하지 않는다 — 앱의 해석 코드 그대로', () async {
    use(fn: (_) async => {'forecast': _forecast(17), 'fetchedAt': '2026-11-15T05:00:00.000Z', 'source': 'fresh'});
    final s = await WeatherService.fetch();
    expect(s!.current.tempC, 17);
    expect(s.daily.single.maxTempC, 18);
    expect(directCalls, 0);
    expect(WeatherService.lastFetchOk, isTrue);
    expect(fnKeys, [null]); // 지역 미설정 — 키 없이(서버가 서울로)
  });

  test('함수가 실패하면 직접 요청으로 넘어간다', () async {
    use(fn: (_) async => throw TimeoutException('fn'));
    final s = await WeatherService.fetch();
    expect(s!.current.tempC, 5);
    expect(directCalls, 1);
  });

  test('함수 응답의 형태가 다르면 직접 요청으로', () async {
    use(fn: (_) async => {'source': 'fresh'});
    expect((await WeatherService.fetch())!.current.tempC, 5);
    expect(directCalls, 1);
  });

  test('지역 목록의 좌표는 이름을 키로, 목록에 없는 좌표는 함수를 쓰지 않는다', () async {
    final busan = regionPresets.firstWhere((p) => p.name == '부산광역시');
    use(fn: (_) async => {'forecast': _forecast(17), 'source': 'fresh'});
    await WeatherService.fetch(latitude: busan.latitude, longitude: busan.longitude);
    expect(fnKeys, ['부산광역시']);
    use(fn: (_) async => {'forecast': _forecast(17), 'source': 'fresh'});
    await WeatherService.fetch(latitude: 1.5, longitude: 2.5);
    expect(fnKeys, isEmpty);
    expect(directCalls, 1);
  });

  test('동시에 들어온 같은 지역 요청은 하나로 합친다', () async {
    final gate = Completer<Map<String, dynamic>>();
    use(fn: (_) => gate.future);
    final a = WeatherService.fetch();
    final b = WeatherService.fetch();
    await Future<void>.delayed(Duration.zero);
    gate.complete({'forecast': _forecast(17), 'source': 'fresh'});
    final r = await Future.wait([a, b]);
    expect(fnKeys.length, 1);
    expect(r[0], same(r[1]));
    // 끝난 뒤의 호출은 30분 기억에서.
    await WeatherService.fetch();
    expect(fnKeys.length, 1);
  });

  testWidgets('홈 화면 — 실패하면 "다시 시도", 누르거나 앱이 앞으로 나오면 다시 받는다', (tester) async {
    var calls = 0;
    WeatherSnapshot? next;
    Future<({WeatherSnapshot? snapshot, String regionName})> loader() async {
      calls++;
      return (snapshot: next, regionName: '서울');
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: HomeWeatherRow(loader: loader))));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text(homeWeatherFailedText), findsOneWidget);
    expect(find.text(homeWeatherRetryLabel), findsOneWidget);

    await tester.tap(find.text(homeWeatherRetryLabel));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text(homeWeatherFailedText), findsOneWidget);

    await tester.tap(find.text(homeWeatherFailedText)); // 날씨 칸을 눌러도
    await tester.pumpAndSettle();
    expect(calls, 3);

    next = WeatherSnapshot.fromOpenMeteo(_forecast(17));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 4);
    expect(find.text(homeWeatherRetryLabel), findsNothing);
    expect(find.textContaining('17°'), findsOneWidget);

    // 성공한 뒤에는 앞으로 나와도 다시 받지 않는다.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 4);
  });
}
