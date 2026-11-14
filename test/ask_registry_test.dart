// 도구 등록부(docs/task_agent_ask_v2.md §2-0) — 프롬프트·검증·엔진·화면이 같은 정의를 쓰는지.
import 'package:ai_fashion_assistant/services/ask_engine.dart';
import 'package:ai_fashion_assistant/services/ask_prompt.dart';
import 'package:ai_fashion_assistant/services/ask_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('도구 이름 목록·프롬프트 [도구] 절·화면 이름이 등록부에서 나온다', () {
    expect(askActions, [for (final t in askToolRegistry) t.name]);
    final prompt = buildAskPrompt(request: 'x', steps: const [], today: DateTime(2026, 11, 16));
    for (final t in askToolRegistry) {
      expect(prompt, contains(t.promptLine));
      if (t.name != 'finish') expect(askToolDisplayName(t.name), t.displayName);
    }
    expect(askToolDisplayName('finish'), isNull);
    expect(askToolDisplayName('없는 도구'), isNull);
  });

  test('실행 함수·상한·쓰기 표시', () {
    for (final t in askToolRegistry) {
      expect(t.run == null, t.name == 'finish', reason: t.name);
      expect(t.limitPerRequest == null, t.limitMessage == null, reason: t.name);
    }
    // 모델 출력으로 실행되는 쓰기는 확인을 받는 add_plan뿐이다.
    expect([for (final t in askToolRegistry) if (t.writes) t.name], ['add_plan']);
    expect([for (final t in askToolRegistry) if (t.writes) t.needsConfirm], [true]);
    expect(askToolSpec('search_wardrobe')!.limitPerRequest, askMaxWardrobeSearches);
  });
}
