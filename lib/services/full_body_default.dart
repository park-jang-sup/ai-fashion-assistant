import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/wardrobe_item.dart';

// 전신 사진 기본값 — 선택된 전신 사진이 없을 때 앱이 고른다. 순서: 이 계정에서 마지막으로 쓴 전신
// 사진 → 없으면(지워졌거나 기록 없음) 등록된 전신 사진 가운데 가장 최근에 등록한 것.
// 마지막으로 쓴 사진은 계정별 기기 파일에 옷 id만 남긴다(AskBubblePrefs와 같은 방식, 앱을 다시 켜도 남는다).
WardrobeItem? pickDefaultFullBody(List<WardrobeItem> bodies, String? lastUsedId) {
  if (bodies.isEmpty) return null;
  for (final b in bodies) {
    if (b.id == lastUsedId) return b;
  }
  final sorted = List.of(bodies)..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return sorted.first;
}

abstract class FullBodyLastUsedStore {
  Future<String?> load(String uid);
  Future<void> save(String uid, String itemId);
}

class FullBodyPrefs implements FullBodyLastUsedStore {
  const FullBodyPrefs();

  static Future<File> _file(String uid) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/full_body_last_$uid.txt');
  }

  @override
  Future<String?> load(String uid) async {
    try {
      final f = await _file(uid);
      if (!f.existsSync()) return null;
      final id = (await f.readAsString()).trim();
      return id.isEmpty ? null : id;
    } catch (e) {
      debugPrint('[전신 사진] 마지막 사진 기록 읽기 실패(최근 등록한 것으로): $e');
      return null;
    }
  }

  @override
  Future<void> save(String uid, String itemId) async {
    try {
      await (await _file(uid)).writeAsString(itemId);
    } catch (e) {
      debugPrint('[전신 사진] 마지막 사진 기록 저장 실패(무시): $e');
    }
  }
}
