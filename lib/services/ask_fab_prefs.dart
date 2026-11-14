import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// 떠 있는 버튼을 옮긴 자리(docs/task_agent_ask_v2.md §2-G) — 계정별 기기 파일, 모든 탭에 쓴다.
// 옮긴 적이 없으면 null(탭별 기본 자리).
class AskFabSpot {
  final bool left; // 붙은 가장자리 — 왼쪽이면 참
  final double top; // 본문 영역 위쪽에서의 거리
  const AskFabSpot({required this.left, required this.top});

  Map<String, dynamic> toMap() => {'left': left, 'top': top};
  static AskFabSpot? fromMap(Object? m) {
    if (m is! Map || m['left'] is! bool || m['top'] is! num) return null;
    return AskFabSpot(left: m['left'] as bool, top: (m['top'] as num).toDouble());
  }
}

abstract class AskFabSpotStore {
  Future<AskFabSpot?> load(String uid);
  Future<void> save(String uid, AskFabSpot spot);
}

class AskFabPrefs implements AskFabSpotStore {
  const AskFabPrefs();

  static Future<File> _file(String uid) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/ask_fab_spot_$uid.json');
  }

  @override
  Future<AskFabSpot?> load(String uid) async {
    try {
      final f = await _file(uid);
      if (!f.existsSync()) return null;
      return AskFabSpot.fromMap(jsonDecode(await f.readAsString()));
    } catch (e) {
      debugPrint('[ASK] 버튼 자리 읽기 실패(기본 자리): $e');
      return null;
    }
  }

  @override
  Future<void> save(String uid, AskFabSpot spot) async {
    try {
      await (await _file(uid)).writeAsString(jsonEncode(spot.toMap()));
    } catch (e) {
      debugPrint('[ASK] 버튼 자리 저장 실패(무시): $e');
    }
  }
}
