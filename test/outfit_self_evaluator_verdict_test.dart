// OutfitSelfEvaluator.judgeCandidate의 순수 로직 단위 테스트.
// docs/task_selfeval_followup_v1.md 2단계 — 폴백(주 모델이 아닌) 모델이
// 응답한 후보는 점수가 있어도 통과/미달 판정에 쓰지 않고 판정을 유보
// (verdictWithheld)한다. Firestore/Gemini 없이 결정적으로 검증한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:ai_fashion_assistant/services/outfit_self_evaluator.dart';

void main() {
  group('judgeCandidate', () {
    test('주 모델 응답 + 임계값 이상이면 통과, 판정 유보 아님', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: 75,
        respondingModel: GeminiService.primaryTextModel,
      );
      expect(r.passed, isTrue);
      expect(r.verdictWithheld, isFalse);
    });

    test('주 모델 응답 + 임계값과 정확히 같으면 통과(>=)', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: OutfitSelfEvaluator.threshold,
        respondingModel: GeminiService.primaryTextModel,
      );
      expect(r.passed, isTrue);
      expect(r.verdictWithheld, isFalse);
    });

    test('주 모델 응답 + 임계값 미만이면 미달, 판정 유보 아님', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: 65,
        respondingModel: GeminiService.primaryTextModel,
      );
      expect(r.passed, isFalse);
      expect(r.verdictWithheld, isFalse);
    });

    test('주 모델 응답인데 점수 파싱 실패(score=null)면 미달 취급하되 '
        '판정 유보는 아니다 — 모델을 못 믿어서가 아니라 응답을 못 읽어서다', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: null,
        respondingModel: GeminiService.primaryTextModel,
      );
      expect(r.passed, isFalse);
      expect(r.verdictWithheld, isFalse);
    });

    test('알려진 폴백 모델이 응답하면 점수가 높아도(임계값 이상) 통과로 '
        '쓰지 않는다 — fail-closed', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: 85,
        respondingModel: GeminiService.textModelFallback,
      );
      expect(r.passed, isFalse);
      expect(r.verdictWithheld, isTrue);
    });

    // 화이트리스트(주 모델과 같은지) 방식임을 직접 검증하는 테스트 —
    // 블랙리스트(textModelFallback과 같은지)였다면 이 값은 "폴백이
    // 아니니까 신뢰"로 잘못 판정됐을 것이다. 세 번째 모델이 붙거나
    // 폴백 상수가 바뀌어도 안전한 쪽으로 무너지는지 이 테스트가 고정한다.
    test('주 모델도 알려진 폴백 모델도 아닌 미지의 모델명이면 판정을 '
        '유보한다(블랙리스트였다면 신뢰됐을 값)', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: 90,
        respondingModel: 'gemini-9-hypothetical-future-model',
      );
      expect(r.passed, isFalse);
      expect(r.verdictWithheld, isTrue);
    });

    test('응답 모델이 null이면 판정을 유보한다', () {
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: 90,
        respondingModel: null,
      );
      expect(r.passed, isFalse);
      expect(r.verdictWithheld, isTrue);
    });

    test('보정 오프셋을 쓰지 않는다 — 폴백 응답의 점수는 그대로 반환하지 '
        '않고(judgeCandidate가 점수를 바꾸지 않음을 간접 확인) 판정만 '
        '유보한다', () {
      // judgeCandidate는 (passed, verdictWithheld) 튜플만 반환하고 점수
      // 자체를 다루지 않는다 — 호출부(run())가 candidateScores/bestScore에
      // 원점수를 그대로 쓰는지는 run() 통합 동작이라 여기서 재확인하지
      // 않는다(이 테스트는 judgeCandidate 자체가 점수를 변형하는 필드를
      // 반환하지 않는다는 시그니처 계약만 고정한다).
      final r = OutfitSelfEvaluator.judgeCandidate(
        score: 62,
        respondingModel: GeminiService.textModelFallback,
      );
      expect(r.verdictWithheld, isTrue);
      // (passed, verdictWithheld) 둘뿐이라는 반환 형태 자체가 "점수를
      // 조정한 새 값"을 만들어 낼 자리가 없음을 보여준다.
    });
  });

  // docs/task_selfeval_bestmatch_v1.md — bestMatch(최종 추천) 갱신 판정.
  // "할인이 아니라 제외": 신뢰 후보가 있으면 신뢰 후보끼리만 최댓값을
  // 겨루고, 신뢰 후보가 하나도 없을 때만 판정 불가 후보 중 최댓값을
  // 임시로 채택한다. run()은 Gemini를 호출해 직접 단위 테스트할 수
  // 없으므로, 이 비교 로직만 뽑은 shouldReplaceBest로 강제 재현해
  // 검증한다(자연 발생 폴백은 희소함이 1단계 실측으로 확인됨 — n=154,
  // 관측 0건).
  group('shouldReplaceBest', () {
    test('현재 최선이 없으면(첫 후보) 무조건 채택', () {
      final r = OutfitSelfEvaluator.shouldReplaceBest(
        hasCurrentBest: false,
        currentBestTrusted: false,
        currentBestScore: 0,
        candidateTrusted: false,
        candidateScore: 10,
      );
      expect(r, isTrue);
    });

    test('폴백(미신뢰) 후보가 최고점이어도, 신뢰 후보가 이미 있으면 밀어내지 못한다 — '
        '이번 수정의 핵심(구 로직은 여기서 반대로 동작했다)', () {
      final r = OutfitSelfEvaluator.shouldReplaceBest(
        hasCurrentBest: true,
        currentBestTrusted: true,
        currentBestScore: 60, // 신뢰 후보지만 점수는 낮음
        candidateTrusted: false,
        candidateScore: 95, // 폴백 후보, 원점수는 훨씬 높음
      );
      expect(r, isFalse);
    });

    test('신뢰 후보가 나중에 나오면, 현재 최선이 더 높은 점수의 폴백이어도 '
        '즉시 교체된다(신뢰 우선이 점수보다 앞선다)', () {
      final r = OutfitSelfEvaluator.shouldReplaceBest(
        hasCurrentBest: true,
        currentBestTrusted: false,
        currentBestScore: 95, // 폴백 후보, 원점수 높음
        candidateTrusted: true,
        candidateScore: 60, // 신뢰 후보지만 점수는 낮음
      );
      expect(r, isTrue);
    });

    test('신뢰 후보끼리는 기존과 동일하게 원점수 최댓값으로 비교한다(회귀 없음)', () {
      expect(
        OutfitSelfEvaluator.shouldReplaceBest(
          hasCurrentBest: true,
          currentBestTrusted: true,
          currentBestScore: 70,
          candidateTrusted: true,
          candidateScore: 75,
        ),
        isTrue,
      );
      expect(
        OutfitSelfEvaluator.shouldReplaceBest(
          hasCurrentBest: true,
          currentBestTrusted: true,
          currentBestScore: 80,
          candidateTrusted: true,
          candidateScore: 75,
        ),
        isFalse,
      );
    });

    test('신뢰 후보가 하나도 없으면(전부 폴백) 그때만 폴백 후보 중 최댓값을 '
        '임시로 채택한다', () {
      expect(
        OutfitSelfEvaluator.shouldReplaceBest(
          hasCurrentBest: true,
          currentBestTrusted: false,
          currentBestScore: 60,
          candidateTrusted: false,
          candidateScore: 65,
        ),
        isTrue,
      );
      expect(
        OutfitSelfEvaluator.shouldReplaceBest(
          hasCurrentBest: true,
          currentBestTrusted: false,
          currentBestScore: 65,
          candidateTrusted: false,
          candidateScore: 60,
        ),
        isFalse,
      );
    });
  });
}
