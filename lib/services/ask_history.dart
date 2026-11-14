// AI에게 부탁하기 — 대화 내역(docs/task_agent_ask_v1.md §10 C, task_agent_ask_v2.md §2-D).
//
// 저장 위치: users/{uid}/agent_meta/ask_history 문서 하나의 `entries` 배열(최신이 앞, 최대 20건).
// agent_meta는 firestore.rules에 이미 본인 읽기·쓰기로 열려 있고(규칙 변경 없음), 앱은 그 안의
// `background` 문서만 id로 읽으므로 다른 문서가 섞이지 않는다. 문서 하나를 id로 읽고 쓰므로 색인이
// 필요 없고, 활동 내역(agent_logs)과 따로라 그 화면의 표시도 그대로다.
//
// 한 건은 대화 하나(모든 턴)다. 턴이 끝날 때마다 같은 id의 건을 갈아 끼운다. v1 형식(턴 없이 요청·답이
// 바로 있는 건)은 한 턴짜리 대화로 읽는다. 사진 자체는 넣지 않고(옷 문서 id·주소만), 답은 턴마다
// 2,000자까지만 저장한다.
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/wardrobe_item.dart';
import 'ask_engine.dart';

const askHistoryMax = 20;
const askRecordAnswerMax = 2000;

class AskRecordStep {
  final String action;
  final String thought;
  final String summary; // 화면용 한 줄
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

// 답의 번호를 붙인 조합 줄("- 1. …(#n) + …")마다 그 줄에 적힌 옷 번호 — 그런 줄이 둘 이상일 때만
// (하나뿐이거나 없으면 빈 목록, 답 아래 사진 한 줄은 지금처럼). 화면이 줄마다 사진을 그릴 때 쓴다.
final _numberedComboLine = RegExp(r'^-\s*\d+\.\s');
final _itemNumber = RegExp(r'#(\d+)');

List<({int line, List<int> numbers})> askNumberedComboLines(String answer) {
  final lines = answer.split('\n');
  final out = [
    for (var i = 0; i < lines.length; i++)
      if (_numberedComboLine.hasMatch(lines[i].trim()))
        (line: i, numbers: [for (final m in _itemNumber.allMatches(lines[i])) int.parse(m.group(1)!)]),
  ];
  return out.length >= 2 ? out : const [];
}

String _clipAnswer(String a) => a.length <= askRecordAnswerMax ? a : a.substring(0, askRecordAnswerMax);

class AskRecordTurn {
  final String request;
  final DateTime createdAt;
  final String end; // AskEnd.name
  final String answer;
  final List<AskRecordStep> steps;
  final List<AskRecordItem> items;
  // 가상 피팅 결과(v2 §2-E) — 사진 자체가 아니라 캐시 키·주소만.
  final String? fittingImageUrl;
  final String? fittingCacheKey;
  // 번호를 붙인 조합 줄에 적힌 옷(번호 → 옷) — 대화 내역에서 다시 열어도 줄마다 사진을 그리게.
  final Map<int, AskRecordItem> lineItems;
  const AskRecordTurn({
    required this.request,
    required this.createdAt,
    required this.end,
    required this.answer,
    this.steps = const [],
    this.items = const [],
    this.fittingImageUrl,
    this.fittingCacheKey,
    this.lineItems = const {},
  });

  bool get finished => end == AskEnd.finished.name;

  factory AskRecordTurn.fromOutcome(String request, AskOutcome o, List<WardrobeItem> combo, DateTime at,
          {String? fittingImageUrl, String? fittingCacheKey, Map<int, WardrobeItem> lineItems = const {}}) =>
      AskRecordTurn(
        request: request,
        createdAt: at,
        end: o.end.name,
        answer: _clipAnswer(o.answer),
        steps: [
          for (final s in o.steps)
            if (s.action != 'finish' && !s.hidden)
              AskRecordStep(
                  action: s.action, thought: s.thought, summary: s.display ?? (s.observation ?? '').split('\n').first),
        ],
        items: [for (final i in combo) AskRecordItem.of(i)],
        fittingImageUrl: fittingImageUrl,
        fittingCacheKey: fittingCacheKey,
        lineItems: {for (final e in lineItems.entries) e.key: AskRecordItem.of(e.value)},
      );

  Map<String, dynamic> toMap() => {
        'request': request,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'end': end,
        'answer': _clipAnswer(answer),
        'steps': [for (final s in steps) s.toMap()],
        'items': [for (final i in items) i.toMap()],
        if (fittingImageUrl != null) 'fittingImageUrl': fittingImageUrl,
        if (fittingCacheKey != null) 'fittingCacheKey': fittingCacheKey,
        if (lineItems.isNotEmpty) 'lineItems': {for (final e in lineItems.entries) '${e.key}': e.value.toMap()},
      };

  factory AskRecordTurn.fromMap(Map<String, dynamic> m) => AskRecordTurn(
        request: m['request'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch((m['createdAt'] as num?)?.toInt() ?? 0),
        end: m['end'] as String? ?? '',
        answer: m['answer'] as String? ?? '',
        steps: [for (final s in (m['steps'] as List? ?? const [])) AskRecordStep.fromMap(Map<String, dynamic>.from(s as Map))],
        items: [for (final i in (m['items'] as List? ?? const [])) AskRecordItem.fromMap(Map<String, dynamic>.from(i as Map))],
        fittingImageUrl: m['fittingImageUrl'] as String?,
        fittingCacheKey: m['fittingCacheKey'] as String?,
        lineItems: {
          for (final e in (m['lineItems'] as Map? ?? const {}).entries)
            if (int.tryParse('${e.key}') case final n?) n: AskRecordItem.fromMap(Map<String, dynamic>.from(e.value as Map)),
        },
      );
}

// 대화 하나.
class AskRecord {
  final String id;
  final List<AskRecordTurn> turns;
  const AskRecord({required this.id, required this.turns});

  // 한 턴짜리 대화(v1과 같은 모양)를 바로 만든다.
  factory AskRecord.single({
    required String request,
    required DateTime createdAt,
    required String end,
    required String answer,
    List<AskRecordStep> steps = const [],
    List<AskRecordItem> items = const [],
  }) =>
      AskRecord(id: 'ask_${createdAt.millisecondsSinceEpoch}', turns: [
        AskRecordTurn(request: request, createdAt: createdAt, end: end, answer: answer, steps: steps, items: items),
      ]);

  factory AskRecord.fromOutcome(String request, AskOutcome o, List<WardrobeItem> combo, DateTime at) =>
      AskRecord(id: 'ask_${at.millisecondsSinceEpoch}', turns: [AskRecordTurn.fromOutcome(request, o, combo, at)]);

  DateTime get createdAt => turns.first.createdAt;
  String get request => turns.first.request;
  AskRecordTurn get last => turns.last;
  String get end => last.end;
  String get answer => last.answer;
  bool get finished => last.finished;
  List<AskRecordStep> get steps => last.steps;

  Map<String, dynamic> toMap() => {
        'id': id,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'turns': [for (final t in turns) t.toMap()],
      };

  factory AskRecord.fromMap(Map<String, dynamic> m) {
    final turns = m['turns'];
    if (turns is List) {
      final parsed = [for (final t in turns) AskRecordTurn.fromMap(Map<String, dynamic>.from(t as Map))];
      final id = m['id'] as String? ?? 'ask_${(m['createdAt'] as num?)?.toInt() ?? 0}';
      return AskRecord(id: id, turns: parsed);
    }
    // v1 — 요청 하나가 한 건.
    final t = AskRecordTurn.fromMap(m);
    return AskRecord(id: 'ask_${t.createdAt.millisecondsSinceEpoch}', turns: [t]);
  }
}

abstract class AskHistoryStore {
  Future<List<AskRecord>> recent();
  // 같은 id가 있으면 갈아 끼우고 맨 앞으로.
  Future<void> save(AskRecord record);
  Future<void> delete(String id);
  Future<void> clear();
}

// 새 기록(또는 같은 대화의 새 판)을 맨 앞에 두고 최대 20건으로 자른다(순수 — 저장소와 테스트가 같이 쓴다).
List<Map<String, dynamic>> upsertAskRecord(List<Map<String, dynamic>> entries, AskRecord record) => [
      record.toMap(),
      for (final e in entries)
        if (AskRecord.fromMap(e).id != record.id) e,
    ].take(askHistoryMax).toList();

List<Map<String, dynamic>> removeAskRecord(List<Map<String, dynamic>> entries, String id) =>
    [for (final e in entries) if (AskRecord.fromMap(e).id != id) e];

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

  Future<void> _update(List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) change) =>
      FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(_doc);
        tx.set(_doc, {'entries': change(_entries(snap.data()))});
      });

  @override
  Future<void> save(AskRecord record) => _update((e) => upsertAskRecord(e, record));

  @override
  Future<void> delete(String id) => _update((e) => removeAskRecord(e, id));

  @override
  Future<void> clear() => _update((_) => const []);
}
