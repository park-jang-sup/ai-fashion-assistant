// AI에게 부탁하기 — 지난 부탁 기록(docs/task_agent_ask_v1.md §10 C).
//
// 저장 위치: users/{uid}/agent_meta/ask_history 문서 하나의 `entries` 배열(최신이 앞, 최대 20건).
// agent_meta는 firestore.rules에 이미 본인 읽기·쓰기로 열려 있고(규칙 변경 없음), 앱은 그 안의
// `background` 문서만 id로 읽으므로 다른 문서가 섞이지 않는다. 문서 하나를 id로 읽고 쓰므로 색인이
// 필요 없고, 활동 내역(agent_logs)과 따로라 그 화면의 표시도 그대로다.
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/wardrobe_item.dart';
import 'ask_engine.dart';

const askHistoryMax = 20;

class AskRecordStep {
  final String action;
  final String thought;
  final String summary; // 결과 첫 줄
  const AskRecordStep({required this.action, required this.thought, required this.summary});

  Map<String, dynamic> toMap() => {'action': action, 'thought': thought, 'summary': summary};
  factory AskRecordStep.fromMap(Map<String, dynamic> m) => AskRecordStep(
      action: m['action'] as String? ?? '-', thought: m['thought'] as String? ?? '', summary: m['summary'] as String? ?? '');
}

// 다시 보기에서 사진을 그리는 데 필요한 만큼만(옷 문서 id·종류·이미지 주소).
class AskRecordItem {
  final String id;
  final String category;
  final String imageUrl;
  final String? cutoutImageUrl;
  const AskRecordItem({required this.id, required this.category, required this.imageUrl, this.cutoutImageUrl});

  factory AskRecordItem.of(WardrobeItem i) =>
      AskRecordItem(id: i.id, category: i.category, imageUrl: i.imageUrl, cutoutImageUrl: i.cutoutImageUrl);
  Map<String, dynamic> toMap() =>
      {'id': id, 'category': category, 'imageUrl': imageUrl, if (cutoutImageUrl != null) 'cutoutImageUrl': cutoutImageUrl};
  factory AskRecordItem.fromMap(Map<String, dynamic> m) => AskRecordItem(
      id: m['id'] as String? ?? '',
      category: m['category'] as String? ?? '',
      imageUrl: m['imageUrl'] as String? ?? '',
      cutoutImageUrl: m['cutoutImageUrl'] as String?);
}

class AskRecord {
  final String request;
  final DateTime createdAt;
  final String end; // AskEnd.name
  final String answer;
  final List<AskRecordStep> steps;
  final List<AskRecordItem> items;
  const AskRecord({
    required this.request,
    required this.createdAt,
    required this.end,
    required this.answer,
    this.steps = const [],
    this.items = const [],
  });

  bool get finished => end == AskEnd.finished.name;

  factory AskRecord.fromOutcome(String request, AskOutcome o, List<WardrobeItem> combo, DateTime at) => AskRecord(
        request: request,
        createdAt: at,
        end: o.end.name,
        answer: o.answer,
        steps: [
          for (final s in o.steps)
            if (s.action != 'finish')
              AskRecordStep(action: s.action, thought: s.thought, summary: (s.observation ?? '').split('\n').first),
        ],
        items: [for (final i in combo) AskRecordItem.of(i)],
      );

  Map<String, dynamic> toMap() => {
        'request': request,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'end': end,
        'answer': answer,
        'steps': [for (final s in steps) s.toMap()],
        'items': [for (final i in items) i.toMap()],
      };

  factory AskRecord.fromMap(Map<String, dynamic> m) => AskRecord(
        request: m['request'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch((m['createdAt'] as num?)?.toInt() ?? 0),
        end: m['end'] as String? ?? '',
        answer: m['answer'] as String? ?? '',
        steps: [for (final s in (m['steps'] as List? ?? const [])) AskRecordStep.fromMap(Map<String, dynamic>.from(s as Map))],
        items: [for (final i in (m['items'] as List? ?? const [])) AskRecordItem.fromMap(Map<String, dynamic>.from(i as Map))],
      );
}

abstract class AskHistoryStore {
  Future<List<AskRecord>> recent();
  Future<void> add(AskRecord record);
}

// 새 기록을 앞에 붙이고 최대 20건으로 자른다(순수 — 저장소와 테스트가 같이 쓴다).
List<Map<String, dynamic>> prependAskRecord(List<Map<String, dynamic>> entries, AskRecord record) =>
    [record.toMap(), ...entries].take(askHistoryMax).toList();

class FirestoreAskHistoryStore implements AskHistoryStore {
  final String uid;
  FirestoreAskHistoryStore(this.uid);

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('users').doc(uid).collection('agent_meta').doc('ask_history');

  static List<Map<String, dynamic>> _entries(Map<String, dynamic>? data) =>
      [for (final e in (data?['entries'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

  @override
  Future<List<AskRecord>> recent() async {
    final snap = await _doc.get();
    return [for (final e in _entries(snap.data())) AskRecord.fromMap(e)];
  }

  @override
  Future<void> add(AskRecord record) => FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(_doc);
        tx.set(_doc, {'entries': prependAskRecord(_entries(snap.data()), record)});
      });
}
