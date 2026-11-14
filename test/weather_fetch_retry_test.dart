// 예보 조회 1회 재시도 — docs/task_demo_flow_v1.md §9-2.
import 'dart:async';
import 'dart:convert';

import 'package:ai_fashion_assistant/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _okBody = jsonEncode({
  'current': {'temperature_2m': 10.0, 'weather_code': 3},
  'daily': {
    'time': ['2026-11-15'],
    'temperature_2m_max': [16.0],
    'temperature_2m_min': [7.0],
    'precipitation_probability_max': [20],
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // 예보 가정 파일 읽기(path_provider)가 실패해도 "없음"
  late int calls;

  void use(Future<http.Response> Function(int call) respond) {
    calls = 0;
    WeatherService.configureForTest(
      client: MockClient((_) => respond(++calls)),
      requestTimeout: const Duration(milliseconds: 50),
    );
  }

  test('첫 시도 네트워크 오류, 둘째 성공이면 성공으로 처리', () async {
    use((n) async => n == 1 ? throw http.ClientException('연결 끊김') : http.Response(_okBody, 200));
    final s = await WeatherService.fetch();
    expect(s, isNotNull);
    expect(s!.forDate(DateTime(2026, 11, 15))!.maxTempC, 16.0);
    expect(WeatherService.lastFetchOk, isTrue);
    expect(calls, 2);
  });

  test('첫 시도 시간 초과, 둘째 성공이면 성공으로 처리', () async {
    use((n) => n == 1 ? Completer<http.Response>().future : Future.value(http.Response(_okBody, 200)));
    final s = await WeatherService.fetch();
    expect(s, isNotNull);
    expect(calls, 2);
  });

  test('둘 다 실패면 지금과 똑같은 실패 처리(null, lastFetchOk false) — 다시 시도는 1회뿐', () async {
    use((n) async => throw http.ClientException('연결 끊김'));
    expect(await WeatherService.fetch(), isNull);
    expect(WeatherService.lastFetchOk, isFalse);
    expect(calls, 2);
    use((n) => Completer<http.Response>().future);
    expect(await WeatherService.fetch(), isNull);
    expect(WeatherService.lastFetchOk, isFalse);
    expect(calls, 2);
  });

  test('HTTP 오류 응답은 다시 시도하지 않는다', () async {
    use((n) async => http.Response('', 500));
    expect(await WeatherService.fetch(), isNull);
    expect(calls, 1);
  });

  test('성공하면 캐시(30분)를 쓴다 — 다음 조회는 요청 없음', () async {
    use((n) async => http.Response(_okBody, 200));
    await WeatherService.fetch();
    await WeatherService.fetch();
    expect(calls, 1);
  });
}
