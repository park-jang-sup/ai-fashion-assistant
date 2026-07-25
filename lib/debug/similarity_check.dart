import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/embedding_service.dart';
import '../services/firestore_service.dart';

// [검증 전용] main.dart에서 --dart-define=RUN_SIMILARITY_CHECK=true 로 빌드했을
// 때만 호출되는 "같은 카테고리 내 유사 옷 검색" 콘솔 검증(CLIP 임베딩 통합
// A단계). RAG 이력 검색이나 OutfitMatcher 궁합 매칭과는 무관 — 실기기에서
// 백필된 embedding 데이터로 findSimilarItems()가 카테고리를 안 섞고
// 기대한 색상끼리 묶는지 눈으로/로그로 재검증할 때 쓴다.
//
// --dart-define=SIMILARITY_CHECK_ITEM_ID=<id>를 함께 주면 그 아이템 하나만
// 상세 출력하고, 없으면 embedding 있는 아이템 전체를 일괄 출력한다.
//
// wardrobe 컬렉션(request.auth != null 요구)을 읽어야 하므로 로그인 세션이
// 없으면 익명 로그인부터 한다. 결과는 화면이 아니라 debugPrint로만 확인 —
// flutter run 콘솔 또는 adb logcat에서 본다.
Future<void> runSimilarityCheck() async {
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  final wardrobe = await FirestoreService.wardrobeStream().first;
  final withEmbedding = wardrobe.where((i) => i.embedding != null).length;
  debugPrint('[유사옷검색] 전체 옷장 ${wardrobe.length}벌 중 '
      'embedding 있음 $withEmbedding벌 / 없음 ${wardrobe.length - withEmbedding}벌');

  const targetId = String.fromEnvironment('SIMILARITY_CHECK_ITEM_ID');
  final targets = targetId.isNotEmpty
      ? wardrobe.where((i) => i.id == targetId).toList()
      : wardrobe.where((i) => i.embedding != null).toList();

  if (targetId.isNotEmpty && targets.isEmpty) {
    debugPrint('[유사옷검색] SIMILARITY_CHECK_ITEM_ID=$targetId 인 아이템을 찾을 수 없음');
    return;
  }

  for (final item in targets) {
    final label = '${item.category}/${item.attributes?.color ?? '?'} (${item.id})';
    if (item.embedding == null) {
      debugPrint('[유사옷검색] $label → embedding 없음, 검색 불가');
      continue;
    }
    final results =
        EmbeddingService.findSimilarItems(item: item, wardrobe: wardrobe, topN: 5);
    debugPrint('[유사옷검색] $label →');
    if (results.isEmpty) {
      debugPrint('  같은 카테고리 내 비교 대상 없음');
      continue;
    }
    for (final r in results) {
      final match = wardrobe.firstWhere((w) => w.id == r.itemId);
      debugPrint('  ${match.category}/${match.attributes?.color ?? '?'} '
          '(${match.id}) sim=${r.similarity.toStringAsFixed(3)}');
    }
  }
}

// [검증 전용] 콘솔 로그가 전부라 화면은 크래시 방지용 placeholder 하나면 충분.
class SimilarityCheckApp extends StatelessWidget {
  const SimilarityCheckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(child: Text('유사 옷 검색 완료 — 콘솔 로그 확인')),
      ),
    );
  }
}
