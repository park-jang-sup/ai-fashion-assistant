// 서버의 지역 표(functions/src/forecast_regions.ts)가 앱의 지역 목록과 같은지 — 키(이름)와 좌표.
import 'dart:io';

import 'package:ai_fashion_assistant/data/region_presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('functions/src/forecast_regions.ts = lib/data/region_presets.dart', () {
    final ts = File('functions/src/forecast_regions.ts').readAsStringSync();
    final rows = RegExp(r'"([^"]+)": \{latitude: ([0-9.\-]+), longitude: ([0-9.\-]+)\}').allMatches(ts).toList();
    final server = {for (final m in rows) m[1]!: (double.parse(m[2]!), double.parse(m[3]!))};
    final app = {for (final p in regionPresets) p.name: (p.latitude, p.longitude)};
    expect(server, app);
    expect(ts, contains('SEOUL_REGION_KEY = "서울특별시"'));
  });
}
