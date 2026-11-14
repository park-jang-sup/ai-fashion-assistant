import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// weather_code(WMO) → 한국어 상태 + 아이콘 + 비/눈 여부. 에이전트(주간
// 플랜/선제 추천)와 홈 화면이 공통으로 쓴다.
class WeatherCondition {
  final String label;
  final IconData icon;
  final bool isRainy;
  final bool isSnowy;

  const WeatherCondition({
    required this.label,
    required this.icon,
    this.isRainy = false,
    this.isSnowy = false,
  });
}

WeatherCondition weatherConditionFor(int code) {
  if (code == 0) return const WeatherCondition(label: '맑음', icon: Icons.wb_sunny_outlined);
  if (code == 1 || code == 2) {
    return const WeatherCondition(label: '대체로 맑음', icon: Icons.wb_cloudy_outlined);
  }
  if (code == 3) return const WeatherCondition(label: '흐림', icon: Icons.cloud_outlined);
  if (code == 45 || code == 48) {
    return const WeatherCondition(label: '안개', icon: Icons.cloud_outlined);
  }
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
    return const WeatherCondition(label: '비', icon: Icons.water_drop_outlined, isRainy: true);
  }
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
    return const WeatherCondition(label: '눈', icon: Icons.ac_unit, isSnowy: true);
  }
  if (code == 95 || code == 96 || code == 99) {
    return const WeatherCondition(label: '뇌우', icon: Icons.water_drop_outlined, isRainy: true);
  }
  return const WeatherCondition(label: '흐림', icon: Icons.cloud_outlined);
}

class CurrentWeather {
  final double tempC;
  final int weatherCode;

  const CurrentWeather({required this.tempC, required this.weatherCode});

  WeatherCondition get condition => weatherConditionFor(weatherCode);
}

// 하루치 예보 — Open-Meteo daily 응답 1행. weather_code는 요청하지 않으므로
// (강수확률만으로 "비 예보" 판단에 충분) 여기엔 없다.
class DailyWeather {
  final DateTime date; // 자정 정규화(로컬)
  final double maxTempC;
  final double minTempC;
  final int precipitationProbability; // %

  const DailyWeather({
    required this.date,
    required this.maxTempC,
    required this.minTempC,
    required this.precipitationProbability,
  });
}

class WeatherSnapshot {
  final CurrentWeather current;
  final List<DailyWeather> daily; // 오늘 포함 7일, 날짜 오름차순
  // 설정 화면의 "예보 가정(테스트용)"으로 만든 가짜 예보인지 — 이 예보로 만든
  // 추천 문구·활동 내역에 그 사실을 남긴다(docs/task_agent_grounding_v1.md §4-4).
  final bool isAssumed;

  const WeatherSnapshot({required this.current, required this.daily, this.isAssumed = false});

  factory WeatherSnapshot.fromOpenMeteo(Map<String, dynamic> json) {
    final current = json['current'] as Map<String, dynamic>;
    final daily = json['daily'] as Map<String, dynamic>;
    final dates = (daily['time'] as List).cast<String>();
    final maxTemps = daily['temperature_2m_max'] as List;
    final minTemps = daily['temperature_2m_min'] as List;
    final precipProbs = daily['precipitation_probability_max'] as List;

    final dailyList = <DailyWeather>[
      for (var i = 0; i < dates.length; i++)
        DailyWeather(
          date: DateTime.parse(dates[i]),
          maxTempC: (maxTemps[i] as num).toDouble(),
          minTempC: (minTemps[i] as num).toDouble(),
          precipitationProbability: (precipProbs[i] as num?)?.toInt() ?? 0,
        ),
    ];

    return WeatherSnapshot(
      current: CurrentWeather(
        tempC: (current['temperature_2m'] as num).toDouble(),
        weatherCode: (current['weather_code'] as num).toInt(),
      ),
      daily: dailyList,
    );
  }

  // date와 같은 날(연/월/일)의 예보. 없으면 null(7일 범위 밖 등).
  DailyWeather? forDate(DateTime date) {
    for (final d in daily) {
      if (d.date.year == date.year && d.date.month == date.month && d.date.day == date.day) {
        return d;
      }
    }
    return null;
  }
}

// Open-Meteo(무료, API 키 불필요) 기반 날씨 조회. 좌표는 호출부가
// 넘긴다(지역 선택, lib/data/region_presets.dart) — 안 넘기면 아래
// 기본 좌표(서울)로 폴백한다. geolocator/위치 권한 처리는 여전히 범위
// 밖(마감 전 리스크 회피 판단 유지) — 지역 선택은 좌표를 GPS가 아니라
// 사용자가 고른 광역시도 프리셋에서 가져온다.
class WeatherService {
  // 미설정 폴백 좌표(서울) — 사용자가 지역을 아직 설정하지 않았을 때만
  // 쓰인다. fetch()의 latitude/longitude 파라미터가 null이면 이 값으로
  // 대체된다.
  static const _defaultLatitude = 37.57;
  static const _defaultLongitude = 126.98;
  static const _baseUrl = 'https://api.open-meteo.com/v1/forecast';

  static http.Client _client = http.Client();
  // 요청 시한 — 실제 값은 10초 그대로다. 테스트만 짧게 바꿔 시간 초과 경로를 확인한다.
  static Duration _requestTimeout = const Duration(seconds: 10);

  @visibleForTesting
  static void configureForTest({http.Client? client, Duration? requestTimeout}) {
    if (client != null) _client = client;
    if (requestTimeout != null) _requestTimeout = requestTimeout;
    _cache = null;
    _cachedAt = null;
  }

  // 시간 초과·네트워크 오류면 한 번만 바로 다시 시도한다(docs/task_demo_flow_v1.md §9-2) —
  // 2026-11-14 실기기에서 첫 조회가 10초 시간 초과로 실패해 예시 일정 추천이 날씨 없이
  // 만들어졌다. HTTP 오류 응답(200 아님)·응답 파싱 실패는 다시 시도하지 않는다. 두 번 다
  // 실패하면 예외를 그대로 던져 호출부가 지금과 같은 실패 처리를 한다.
  static Future<http.Response> _getWithOneRetry(Uri uri) async {
    try {
      return await _client.get(uri).timeout(_requestTimeout);
    } on Object catch (e) {
      if (e is! TimeoutException && e is! SocketException && e is! http.ClientException) rethrow;
      debugPrint('[WEATHER] 첫 조회 실패($e) — 한 번 다시 시도');
      return await _client.get(uri).timeout(_requestTimeout);
    }
  }

  // 같은 세션에서 반복 호출하지 않게 메모리 캐시(프로세스 생존 동안만,
  // Firestore 저장 없음). 좌표를 캐시 키에 포함시킨다 — 그래야 지역을
  // 바꿨을 때 이전 지역 캐시를 계속 돌려주지 않고 자연히 miss가 나서
  // 새로 조회한다. 별도 "캐시 무효화" 호출을 만들지 않는 이유이기도
  // 하다 — 무효화를 어디서 부를지가 또 하나의 누락 지점이 된다.
  static WeatherSnapshot? _cache;
  static DateTime? _cachedAt;
  static double? _cachedLatitude;
  static double? _cachedLongitude;
  static const _cacheTtl = Duration(minutes: 30);

  // 가장 최근 fetch() 호출(캐시 히트 포함)의 성공 여부 — 진단용 관찰 지점.
  // 백그라운드 실행(background_agent.dart)이 agent_meta/background에
  // lastWeatherOk로 그대로 기록해, 날씨 API 실패율을 실행 이력과 함께
  // 추적할 수 있게 한다. 격리된 아이솔레이트마다 별도 상태라 백그라운드
  // 실행 간 오염되지 않는다.
  static bool lastFetchOk = true;

  // 실패(네트워크 오류/타임아웃/파싱 실패)하면 null — 호출부는 하드코딩된
  // 값으로 폴백하지 말고 위젯을 숨기거나 "불러오지 못했다"고 정직하게 표시한다.
  static Future<WeatherSnapshot?> fetch({double? latitude, double? longitude}) async {
    // 예보 가정(테스트용)이 켜져 있으면 조회 대신 가정한 값을 쓴다 — 시연·검증용.
    // 매번 파일을 읽는다(설정 화면과 백그라운드 아이솔레이트가 같은 값을 보게).
    final assumption = await loadAssumption();
    if (assumption != ForecastAssumption.none) {
      lastFetchOk = true;
      return assumedSnapshot(assumption, DateTime.now());
    }
    final lat = latitude ?? _defaultLatitude;
    final lon = longitude ?? _defaultLongitude;

    final cached = _cache;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        _cachedLatitude == lat &&
        _cachedLongitude == lon &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      lastFetchOk = true;
      return cached;
    }

    try {
      final uri = Uri.parse(_baseUrl).replace(queryParameters: {
        'latitude': '$lat',
        'longitude': '$lon',
        'current': 'temperature_2m,weather_code',
        'daily': 'temperature_2m_max,temperature_2m_min,precipitation_probability_max',
        'timezone': 'Asia/Seoul',
        'forecast_days': '7',
      });
      final response = await _getWithOneRetry(uri);
      if (response.statusCode != 200) {
        debugPrint('[WEATHER] 조회 실패: HTTP ${response.statusCode}');
        lastFetchOk = false;
        return null;
      }
      final snapshot = WeatherSnapshot.fromOpenMeteo(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      _cache = snapshot;
      _cachedAt = DateTime.now();
      _cachedLatitude = lat;
      _cachedLongitude = lon;
      debugPrint('[WEATHER] 조회 성공: ${snapshot.current.tempC.round()}°C '
          '${snapshot.current.condition.label}, 7일 예보 ${snapshot.daily.length}건');
      lastFetchOk = true;
      return snapshot;
    } catch (e) {
      debugPrint('[WEATHER] 조회 실패: $e');
      lastFetchOk = false;
      return null;
    }
  }

  // 강수확률 이 값 이상이면 "비 예보"로 취급(에이전트 제약/카드 문구 공통 기준).
  static const rainProbabilityThreshold = 50;

  // ── 예보 가정(테스트용) — docs/task_agent_grounding_v1.md §4-4 ──────
  // 날씨는 마음대로 바꿀 수 없으므로 설정 화면 진단 영역에서 없음/비/더운 날/
  // 추운 날을 고르게 한다. 기기에만 저장한다(fcm_service.dart와 같은 이유로
  // shared_preferences 대신 path_provider 파일, 임시파일+rename). 기본값은 없음.
  // 읽기 실패는 "없음"으로 — 가정이 실수로 켜진 채 남는 쪽보다 안전하다.
  static const _assumptionFileName = 'forecast_assumption.txt';

  static Future<File> _assumptionFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_assumptionFileName');
  }

  static Future<ForecastAssumption> loadAssumption() async {
    try {
      final file = await _assumptionFile();
      if (!await file.exists()) return ForecastAssumption.none;
      final name = (await file.readAsString()).trim();
      return ForecastAssumption.values.firstWhere((a) => a.name == name,
          orElse: () => ForecastAssumption.none);
    } catch (e) {
      return ForecastAssumption.none;
    }
  }

  static Future<void> saveAssumption(ForecastAssumption a) async {
    final file = await _assumptionFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(a.name);
    await tmp.rename(file.path);
    _cache = null; // 가정을 끄면 다음 조회가 실제 예보를 다시 받게
  }

  // 가정한 7일 예보 — 조건이 확실히 걸리는 값(비: 강수 80%, 더위: 최고 31°C,
  // 추위: 최저 −3°C)을 매일 같게 둔다.
  @visibleForTesting
  static WeatherSnapshot assumedSnapshot(ForecastAssumption a, DateTime now) {
    final (maxT, minT, rain, code) = switch (a) {
      ForecastAssumption.rain => (17.0, 11.0, 80, 63),
      ForecastAssumption.hot => (31.0, 24.0, 10, 0),
      // 온화·선선(docs/task_demo_flow_v1.md §2-4) — 각 기온대(최고 18~25 / 10~18°C)의
      // 가운데쯤. 온화는 최저 10°C 이상이라 일교차 아우터가 걸리지 않는다.
      ForecastAssumption.mild => (22.0, 14.0, 10, 1),
      ForecastAssumption.cool => (14.0, 8.0, 10, 2),
      ForecastAssumption.cold => (3.0, -3.0, 10, 3),
      ForecastAssumption.none => (20.0, 12.0, 0, 0),
    };
    final today = DateTime(now.year, now.month, now.day);
    return WeatherSnapshot(
      current: CurrentWeather(tempC: (maxT + minT) / 2, weatherCode: code),
      daily: [
        for (var i = 0; i < 7; i++)
          DailyWeather(
              date: today.add(Duration(days: i)),
              maxTempC: maxT,
              minTempC: minT,
              precipitationProbability: rain),
      ],
      isAssumed: true,
    );
  }
}

enum ForecastAssumption { none, rain, hot, mild, cool, cold }
