import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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

  const WeatherSnapshot({required this.current, required this.daily});

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

// Open-Meteo(무료, API 키 불필요) 기반 날씨 조회. 위치는 서울 좌표로
// 고정한다 — geolocator/위치 권한 처리는 범위 밖(마감 전 리스크 회피).
// 나중에 사용자 위치로 바꾸기 쉽도록 좌표만 상수로 분리해둔다.
class WeatherService {
  static const _latitude = 37.57;
  static const _longitude = 126.98;
  static const _baseUrl = 'https://api.open-meteo.com/v1/forecast';

  static final http.Client _client = http.Client();

  // 같은 세션에서 반복 호출하지 않게 메모리 캐시(프로세스 생존 동안만,
  // Firestore 저장 없음).
  static WeatherSnapshot? _cache;
  static DateTime? _cachedAt;
  static const _cacheTtl = Duration(minutes: 30);

  // 가장 최근 fetch() 호출(캐시 히트 포함)의 성공 여부 — 진단용 관찰 지점.
  // 백그라운드 실행(background_agent.dart)이 agent_meta/background에
  // lastWeatherOk로 그대로 기록해, 날씨 API 실패율을 실행 이력과 함께
  // 추적할 수 있게 한다. 격리된 아이솔레이트마다 별도 상태라 백그라운드
  // 실행 간 오염되지 않는다.
  static bool lastFetchOk = true;

  // 실패(네트워크 오류/타임아웃/파싱 실패)하면 null — 호출부는 하드코딩된
  // 값으로 폴백하지 말고 위젯을 숨기거나 "불러오지 못했다"고 정직하게 표시한다.
  static Future<WeatherSnapshot?> fetch() async {
    final cached = _cache;
    final cachedAt = _cachedAt;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _cacheTtl) {
      lastFetchOk = true;
      return cached;
    }

    try {
      final uri = Uri.parse(_baseUrl).replace(queryParameters: {
        'latitude': '$_latitude',
        'longitude': '$_longitude',
        'current': 'temperature_2m,weather_code',
        'daily': 'temperature_2m_max,temperature_2m_min,precipitation_probability_max',
        'timezone': 'Asia/Seoul',
        'forecast_days': '7',
      });
      final response = await _client.get(uri).timeout(const Duration(seconds: 10));
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
}
