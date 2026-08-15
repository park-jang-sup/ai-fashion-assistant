// cadence_gate.ts 단위 테스트 — 다른 *.test.ts와 동일 관례
// (rate_limit.test.ts 참고, node:assert 직접 사용).
import * as assert from "node:assert";
import {evaluateCadenceGate} from "./cadence_gate";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

const NOW_MS = new Date("2026-08-15T12:00:00Z").getTime();

run("adjustedIntervalHours 없음 — 막지 않는다(diff 0)", () => {
  const blocked = evaluateCadenceGate({
    nowMs: NOW_MS,
    adjustedIntervalHours: undefined,
    serverLastSentAtMs: NOW_MS - 1000,
  });
  assert.strictEqual(blocked, false);
});

run("serverLastSentAt 없음(한 번도 발송 안 함) — 막지 않는다(diff 0)", () => {
  const blocked = evaluateCadenceGate({
    nowMs: NOW_MS,
    adjustedIntervalHours: 6,
    serverLastSentAtMs: undefined,
  });
  assert.strictEqual(blocked, false);
});

run("조정 간격 미달(6시간 중 3시간만 경과) — 막는다", () => {
  const threeHoursAgo = NOW_MS - 3 * 60 * 60 * 1000;
  const blocked = evaluateCadenceGate({
    nowMs: NOW_MS,
    adjustedIntervalHours: 6,
    serverLastSentAtMs: threeHoursAgo,
  });
  assert.strictEqual(blocked, true);
});

run("조정 간격 정확히 경과(경계값) — 막지 않는다", () => {
  const sixHoursAgo = NOW_MS - 6 * 60 * 60 * 1000;
  const blocked = evaluateCadenceGate({
    nowMs: NOW_MS,
    adjustedIntervalHours: 6,
    serverLastSentAtMs: sixHoursAgo,
  });
  assert.strictEqual(blocked, false);
});

run("조정 간격 충분히 경과(6시간 중 7시간 경과) — 막지 않는다", () => {
  const sevenHoursAgo = NOW_MS - 7 * 60 * 60 * 1000;
  const blocked = evaluateCadenceGate({
    nowMs: NOW_MS,
    adjustedIntervalHours: 6,
    serverLastSentAtMs: sevenHoursAgo,
  });
  assert.strictEqual(blocked, false);
});

run("하한(3시간)으로 조정된 경우 — 3시간 크론 틱마다 항상 통과(막지 않음)", () => {
  const threeHoursAgo = NOW_MS - 3 * 60 * 60 * 1000;
  const blocked = evaluateCadenceGate({
    nowMs: NOW_MS,
    adjustedIntervalHours: 3,
    serverLastSentAtMs: threeHoursAgo,
  });
  assert.strictEqual(blocked, false);
});
