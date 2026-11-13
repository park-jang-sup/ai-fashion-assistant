// 옷장 추천 후보 — docs/task_agent_grounding_v1.md 부분 B.
//
// 코디 분석 텍스트와 그 아래 "내 스타일에 맞는 추천 옷" 카드, 합성 중 팝업이
// **같은 후보 목록**을 쓰게 하려고, 화면 파일(fitting_room_screen.dart)에 있던
// _matchStyleRecommendations를 이곳으로 옮겼다. 뽑는 규칙(카테고리당 상위 2개,
// 궁합 점수 내림차순, 최대 maxItems)은 한 글자도 바꾸지 않았다 — Gemini/Claude
// 호출 없이 OutfitMatcher로 기기 안에서 계산한다.
//
// 분석 요청은 이 후보를 프롬프트의 [내 옷장 후보]로 넣고, 모델은 그 안에서만
// 골라 [추천후보] 줄로 번호를 낸다. 그 줄은 화면에 보이지 않게 지운다
// (visibleAnalysisText), 고른 번호는 카드 맨 앞 "AI 추천"으로 쓴다.
import 'package:firebase_auth/firebase_auth.dart';

import '../constants/outfit_reason.dart';
import '../models/wardrobe_item.dart';
import 'firestore_service.dart';
import 'outfit_matcher.dart';

class StyleCandidate {
  final WardrobeItem item;
  final String caption; // 카드·팝업 아래 추천 이유
  const StyleCandidate({required this.item, required this.caption});
}

// 순수 함수 — 옮기기 전 _matchStyleRecommendations와 같은 계산(옷장을 인자로
// 받는다는 것만 다르다). 매칭 후보가 없으면 빈 리스트.
List<StyleCandidate> matchStyleCandidates({
  required List<WardrobeItem> selected,
  required List<WardrobeItem> wardrobe,
  int maxItems = 5,
}) {
  final selectedWithAttrs = selected.where((i) => i.attributes != null).toList();
  if (selectedWithAttrs.isEmpty) return const [];

  final fittingIds = selected.map((i) => i.id).toSet();
  const allCategories = ['상의', '하의', '아우터', '신발', '액세서리'];

  final scored = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
  for (final category in allCategories) {
    final eligibleAnchors = selectedWithAttrs.where((a) => a.category != category).toList();
    if (eligibleAnchors.isEmpty) continue;

    final pool = wardrobe
        .where((i) =>
            i.category == category && i.attributes != null && !fittingIds.contains(i.id))
        .toList();
    if (pool.isEmpty) continue;

    final perCategory = <({WardrobeItem item, WardrobeItem anchor, double score})>[];
    for (final candidate in pool) {
      WardrobeItem? bestAnchor;
      var bestScore = double.negativeInfinity;
      for (final anchor in eligibleAnchors) {
        final score = OutfitMatcher.compatibilityScore(anchor.attributes!, candidate.attributes!);
        if (score > bestScore) {
          bestScore = score;
          bestAnchor = anchor;
        }
      }
      if (bestAnchor != null) {
        perCategory.add((item: candidate, anchor: bestAnchor, score: bestScore));
      }
    }
    perCategory.sort((a, b) => b.score.compareTo(a.score));
    scored.addAll(perCategory.take(2));
  }

  scored.sort((a, b) => b.score.compareTo(a.score));
  if (scored.isEmpty) return const [];
  return scored
      .take(maxItems)
      .map((s) => StyleCandidate(
          item: s.item, caption: buildOutfitReason(anchor: s.anchor, candidate: s.item)))
      .toList();
}

// 로그인 사용자의 옷장을 읽어 matchStyleCandidates를 돌린다(옮기기 전
// _matchStyleRecommendations의 비동기 부분 그대로).
Future<List<StyleCandidate>> loadStyleCandidates(
  List<WardrobeItem> selected, {
  int maxItems = 5,
}) async {
  if (!selected.any((i) => i.attributes != null)) return const [];
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return const [];
  final wardrobe = await FirestoreService.wardrobeStream(uid).first;
  return matchStyleCandidates(selected: selected, wardrobe: wardrobe, maxItems: maxItems);
}

// 분석 요청에 넣는 후보 수(§3-1 — 카드와 같은 8개).
const analysisCandidateCount = 8;

// "추가 가능"(지금 조합에 그 종류가 없음) / "교체 후보"(이미 있음). 액세서리는
// 세부 종류(모자·가방·시계·팔찌) 기준 — subCategory가 없는 액세서리는 "액세서리"
// 하나로 본다.
String _kindKey(WardrobeItem i) => i.category == '액세서리' ? (i.subCategory ?? '액세서리') : i.category;

bool isAddableCandidate(WardrobeItem candidate, List<WardrobeItem> selected) =>
    !selected.any((s) => _kindKey(s) == _kindKey(candidate));

// [내 옷장 후보] 한 줄 — "1. 아우터(추가 가능): 색상 브라운, …".
String candidatePromptLine(int index, WardrobeItem candidate, List<WardrobeItem> selected) {
  final role = isAddableCandidate(candidate, selected) ? '추가 가능' : '교체 후보';
  return '${index + 1}. ${_kindKey(candidate)}($role): ${candidate.attributes!.toPromptLine()}';
}

String candidatePromptLines(List<StyleCandidate> candidates, List<WardrobeItem> selected) => [
      for (var i = 0; i < candidates.length; i++) candidatePromptLine(i, candidates[i].item, selected),
    ].join('\n');

const _recommendTag = '[추천후보]';

// 모델이 낸 [추천후보] 줄에서 0-based 후보 인덱스를 꺼낸다. 줄이 없거나 "없음"이거나
// 형식이 틀리면 빈 리스트. 범위 밖 번호·중복은 버리고, 앞에서부터 최대 2개.
List<int> parseRecommendedCandidates(String raw, int candidateCount) {
  if (candidateCount <= 0) return const [];
  final line = raw.split('\n').map((l) => l.trim()).firstWhere(
        (l) => l.startsWith(_recommendTag),
        orElse: () => '',
      );
  if (line.isEmpty) return const [];
  final body = line.substring(_recommendTag.length).trim();
  if (body.isEmpty || body.startsWith('없음')) return const [];
  final out = <int>[];
  for (final m in RegExp(r'\d+').allMatches(body)) {
    final n = int.parse(m.group(0)!);
    if (n < 1 || n > candidateCount) continue;
    if (!out.contains(n - 1)) out.add(n - 1);
    if (out.length == 2) break;
  }
  return out;
}

// 화면·이력에 보일 텍스트 — [추천후보] 줄을 지운다. 스트리밍 도중 마지막 줄이
// 아직 덜 온 "[추", "[추천후보] 1" 같은 상태도 숨긴다(줄바꿈이 오기 전까지).
String visibleAnalysisText(String raw) {
  final lines = raw.split('\n');
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trimLeft();
    final isLast = i == lines.length - 1;
    if (t.startsWith(_recommendTag)) continue;
    if (isLast && t.isNotEmpty && _recommendTag.startsWith(t)) continue;
    out.add(lines[i]);
  }
  return out.join('\n');
}

// 카드 순서 — 모델이 고른 후보를 고른 순서대로 맨 앞에, 나머지는 원래 순서.
List<({StyleCandidate candidate, bool aiPick})> orderWithAiPicks(
  List<StyleCandidate> candidates,
  List<int> picks,
) {
  final picked = [for (final i in picks) if (i >= 0 && i < candidates.length) i];
  return [
    for (final i in picked) (candidate: candidates[i], aiPick: true),
    for (var i = 0; i < candidates.length; i++)
      if (!picked.contains(i)) (candidate: candidates[i], aiPick: false),
  ];
}
