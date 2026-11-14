import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// 떠 있는 버튼 옆 "AI에게 부탁하기" 말풍선(docs/task_agent_ask_v1.md §10 A) — 한 번 누르면 다시
// 보여 주지 않는다. 첫 실행 가이드의 "다시 보지 않기"와 같은 방식(계정별 기기 파일).
class AskBubblePrefs {
  static Future<File> _file(String uid) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/ask_bubble_seen_$uid.txt');
  }

  static Future<bool> seen(String uid) async {
    try {
      return (await _file(uid)).existsSync();
    } catch (e) {
      debugPrint('[ASK] 말풍선 기록 읽기 실패(보여 줌): $e');
      return false;
    }
  }

  static Future<void> markSeen(String uid) async {
    try {
      await (await _file(uid)).writeAsString('1');
    } catch (e) {
      debugPrint('[ASK] 말풍선 기록 저장 실패(무시): $e');
    }
  }
}
