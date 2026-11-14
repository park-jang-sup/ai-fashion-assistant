// 떠 있는 버튼 옮기기(docs/task_agent_ask_v2.md §2-G) — 본문 영역 안으로만, 놓으면 좌우 가장자리,
// 계정별 저장, 옮긴 자리는 모든 탭에, 옮긴 적이 없으면 탭별 기본 자리.
import 'package:ai_fashion_assistant/services/ask_controller.dart';
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_fab_prefs.dart';
import 'package:ai_fashion_assistant/services/ask_history.dart';
import 'package:ai_fashion_assistant/widgets/ask_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_fakes.dart';

class _Spots implements AskFabSpotStore {
  final saved = <String, AskFabSpot>{};
  @override
  Future<AskFabSpot?> load(String uid) async => saved[uid];
  @override
  Future<void> save(String uid, AskFabSpot spot) async => saved[uid] = spot;
}

class _NoHistory implements AskHistoryStore {
  @override
  Future<List<AskRecord>> recent() async => const [];
  @override
  Future<void> save(AskRecord record) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> clear() async {}
}

AskController _controller() => AskController(
      currentUid: () => 'u',
      toolsFor: (_) => askTools(FakeAskData(snap: askSnapshot())),
      callModel: (_) async => AskModelReply(const {}, 'text-primary'),
      logSink: (_) {},
      historyFor: (_) => _NoHistory(),
    );

const _w = 400.0;
const _h = 600.0;
const _box = askFabSize + 8;

Widget _app(AskController c, _Spots spots, {int tab = 0, String? uid = 'u', VoidCallback? onTap}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _w,
            height: _h,
            child: Stack(children: [
              const SizedBox.expand(),
              MovableAskFab(
                controller: c,
                onTap: onTap ?? () {},
                tab: tab,
                maxWidth: _w,
                maxHeight: _h,
                uid: uid,
                store: spots,
              ),
            ]),
          ),
        ),
      ),
    );

Offset _topLeft(WidgetTester tester) => tester.getTopLeft(find.byType(AskFab));

void main() {
  testWidgets('옮긴 적이 없으면 탭별 기본 자리, 누르면 열린다', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(_controller(), _Spots(), onTap: () => taps++));
    await tester.pump();
    expect(_topLeft(tester), const Offset(_w - 18 - _box, _h - 84 - _box));
    await tester.tap(find.byType(AskFab));
    expect(taps, 1);
    await tester.pumpWidget(_app(_controller(), _Spots(), tab: 2));
    await tester.pump();
    expect(_topLeft(tester), const Offset(_w - 20 - _box, 18));
  });

  testWidgets('놓으면 가까운 가장자리에 붙고 계정별로 저장 — 다른 탭에도 같은 자리', (tester) async {
    final spots = _Spots();
    final c = _controller();
    await tester.pumpWidget(_app(c, spots));
    await tester.pump();
    await tester.drag(find.byType(AskFab), const Offset(-250, -200));
    await tester.pumpAndSettle();
    final at = _topLeft(tester);
    expect(at.dx, askFabSideEdge); // 왼쪽 가장자리
    expect(spots.saved['u']!.left, isTrue);
    expect(spots.saved['u']!.top, at.dy);
    expect(at.dy, lessThan(_h - 84 - _box - 150));
    // 다른 탭(기본 자리가 다른 피팅룸)에서도 옮긴 자리
    await tester.pumpWidget(_app(c, spots, tab: 2));
    await tester.pump();
    expect(_topLeft(tester), at);
    // 오른쪽 절반에서 놓으면 오른쪽 가장자리
    await tester.drag(find.byType(AskFab), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(_topLeft(tester).dx, _w - askFabSideEdge - _box);
    expect(spots.saved['u']!.left, isFalse);
  });

  testWidgets('본문 영역 밖(위·아래 = 하단 탭 쪽)으로 나가지 않는다', (tester) async {
    final spots = _Spots();
    await tester.pumpWidget(_app(_controller(), spots));
    await tester.pump();
    await tester.drag(find.byType(AskFab), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(_topLeft(tester), const Offset(_w - askFabSideEdge - _box, _h - askFabVerticalEdge - _box));
    await tester.drag(find.byType(AskFab), const Offset(-2000, -3000));
    await tester.pumpAndSettle();
    expect(_topLeft(tester), const Offset(askFabSideEdge, askFabVerticalEdge));
  });

  testWidgets('저장된 자리는 그 계정에만 — 다른 계정은 기본 자리, 저장값이 화면보다 아래면 안으로', (tester) async {
    final spots = _Spots()..saved['u'] = const AskFabSpot(left: true, top: 5000);
    await tester.pumpWidget(_app(_controller(), spots, tab: 1));
    await tester.pump();
    expect(_topLeft(tester), const Offset(askFabSideEdge, _h - askFabVerticalEdge - _box));
    await tester.pumpWidget(_app(_controller(), spots, tab: 1, uid: 'other'));
    await tester.pump();
    expect(_topLeft(tester), const Offset(_w - 18 - _box, _h - 142 - _box));
  });

  test('저장 형식 왕복과 잘못된 값', () {
    const s = AskFabSpot(left: true, top: 120.5);
    final back = AskFabSpot.fromMap(s.toMap())!;
    expect((back.left, back.top), (true, 120.5));
    expect(AskFabSpot.fromMap({'left': 'x', 'top': 1}), isNull);
    expect(AskFabSpot.fromMap(null), isNull);
  });
}
