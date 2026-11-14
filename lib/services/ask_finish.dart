// AI에게 부탁하기 — finish 정리와 검사(docs/task_agent_ask_v2.md 실행 기록 "run3 전 결정"). 순수 함수.
//  · buy: 옷장에 없지만 가진 옷과 어울리는 옷 종류. 한 항목은 "옷 종류 — 가진 옷 가운데 무엇과 어울리는지".
//    목록이면 그대로, 문자열 하나면 1개짜리 목록, 그 밖의 형이면 없음(규약 위반으로 치지 않는다). 빈 항목은
//    버리고, 줄바꿈은 공백으로, 최대 3개.
//  · answer 안에 모델이 직접 쓴 "구매 제안:" 줄은 answer에서 떼어 buy 뒤에 넣는다(표시 글자는 떼고 내용만).
//  · 화면·대화 내역·다음 턴 맥락에 쓰는 답은 answer + buy 항목마다 "구매 제안: …" 한 줄(엔진이 만든다).
//  · 엔진의 finish 검사: answer의 각 줄에서 새 옷을 권하는 말을 찾는다(buy는 보지 않는다).

const askBuyMax = 3;
const askBuyLabel = '구매 제안:';

List<String> askNormalizeBuy(Object? v) {
  final raw = v is List
      ? [for (final x in v) if (x is String) x]
      : v is String
          ? [v]
          : const <String>[];
  return [
    for (final x in raw)
      if (x.replaceAll('\n', ' ').trim().isNotEmpty) x.replaceAll('\n', ' ').trim(),
  ];
}

// "구매 제안:"(앞에 "- "가 붙은 것 포함)으로 시작하는 줄의 내용. 아니면 null.
String? _buyLineContent(String line) {
  var l = line.trim();
  if (l.startsWith('- ')) l = l.substring(2).trimLeft();
  if (!l.startsWith(askBuyLabel)) return null;
  return l.substring(askBuyLabel.length).trim();
}

class AskFinishParts {
  final List<String> answerLines; // "구매 제안:" 줄을 뗀 answer
  final List<String> buy; // buy + answer에서 뗀 제안(최대 3개)
  const AskFinishParts(this.answerLines, this.buy);

  // 사용자에게 보일 최종 답.
  String compose() => [...answerLines, for (final b in buy) '$askBuyLabel $b'].join('\n').trim();
}

AskFinishParts askSplitFinish(String answer, Object? buy) {
  final lines = <String>[];
  final moved = <String>[];
  for (final line in answer.trim().split('\n')) {
    final c = _buyLineContent(line);
    if (c == null) {
      lines.add(line.trimRight());
    } else if (c.isNotEmpty) {
      moved.add(c);
    }
  }
  final items = [...askNormalizeBuy(buy), ...moved];
  return AskFinishParts(lines, items.take(askBuyMax).toList());
}

// 새 옷을 권하는 말(사용자 결정 목록 — "구매"·"구입"은 "구매 제안"을 소개하는 말을 잡아 빼고 "구매하"·"구입하"로).
const askFinishWords = [
  '들이면', '들이는 것', '들이는 걸', '들이세요', '장만', '구매하', '구입하', '를 사면', '을 사면', '를 사는', '을 사는',
  '를 사두', '을 사두', '사세요', '사시면', '한 벌을 더하', '한 벌 더하', '한 벌 더 있', '하나 더 있', '있으면 좋',
  '있으면 더', '급해요',
];
// 한 줄 안에서 "있으면" 뒤 20자 안에 "더 잘"·"더 좋".
final askFinishPattern = RegExp(r'있으면.{0,20}?(더 잘|더 좋)');

bool askFinishLineHits(String line) => askFinishWords.any(line.contains) || askFinishPattern.hasMatch(line);

// 걸린 줄의 번호(0부터).
List<int> askFinishHits(List<String> answerLines) =>
    [for (var i = 0; i < answerLines.length; i++) if (askFinishLineHits(answerLines[i])) i];

String askFinishFeedback(List<String> hitLines) =>
    'answer의 이 줄이 새 옷을 권하는 말이에요: "${hitLines.join('" / "')}". 그 내용은 buy로 옮기거나 지우고 '
    'finish를 다시 내세요. 이 안내는 답에 언급하지 않아요.';

const askDisplayRevising = '답을 다듬고 있어요';
