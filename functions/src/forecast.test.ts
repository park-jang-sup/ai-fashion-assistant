// forecast.ts 단위 테스트 — node:assert(rate_limit.test.ts와 같은 방식).
import * as assert from "node:assert";
import {HttpsError} from "firebase-functions/v2/https";
import {
  FORECAST_FRESH_MS,
  FORECAST_STALE_MS,
  ForecastBody,
  ForecastCacheEntry,
  ForecastDeps,
  UpstreamMode,
  UpstreamStatusError,
  classifyUpstreamError,
  fetchForecastWithRetry,
  forecastFetcher,
  forecastUrl,
  handleGetForecast,
  nextForecastRate,
  resolveRegionKey,
  runForecastRefresh,
} from "./forecast";
import {FORECAST_REGIONS, SEOUL_REGION_KEY} from "./forecast_regions";

const tests: Array<[string, () => Promise<void> | void]> = [];
function run(name: string, fn: () => Promise<void> | void): void {
  tests.push([name, fn]);
}

const BODY: ForecastBody = {
  current: {temperature_2m: 17.2, weather_code: 0},
  daily: {time: ["2026-11-15"], temperature_2m_max: [18], temperature_2m_min: [9], precipitation_probability_max: [10]},
};
const NOW = Date.parse("2026-11-15T05:00:00Z");
const USER = {uid: "u"};

function deps(opts: {
  cache?: ForecastCacheEntry;
  upstream?: (mode: UpstreamMode) => Promise<ForecastBody>;
  allow?: boolean;
} = {}) {
  const store = new Map<string, ForecastCacheEntry>();
  const logs: string[] = [];
  let upstreamCalls = 0;
  const fetched: string[] = [];
  const modes: UpstreamMode[] = [];
  const d: ForecastDeps = {
    now: () => NOW,
    readCache: async (key) => store.get(key),
    writeCache: async (key, entry) => {
      store.set(key, entry);
    },
    fetchUpstream: async (region, mode) => {
      upstreamCalls++;
      modes.push(mode);
      fetched.push(Object.keys(FORECAST_REGIONS).find((k) => FORECAST_REGIONS[k] === region) ?? "?");
      return (opts.upstream ?? (async () => BODY))(mode);
    },
    allowCall: async () => opts.allow ?? true,
    log: (l) => logs.push(l),
  };
  if (opts.cache) store.set(SEOUL_REGION_KEY, opts.cache);
  return {d, store, logs, calls: () => upstreamCalls, fetched, modes};
}

async function rejectsWith(p: Promise<unknown>, code: string): Promise<void> {
  try {
    await p;
  } catch (err) {
    assert.ok(err instanceof HttpsError, `HttpsError가 아님: ${err}`);
    assert.strictEqual((err as HttpsError).code, code);
    return;
  }
  assert.fail(`거부되지 않음(기대 ${code})`);
}

const failing = async (): Promise<ForecastBody> => {
  throw new Error("timeout");
};

run("로그인이 없으면 거부 — 날씨 서버도 기억도 쓰지 않는다", async () => {
  const t = deps();
  await rejectsWith(handleGetForecast(undefined, {region: SEOUL_REGION_KEY}, t.d), "unauthenticated");
  assert.strictEqual(t.calls(), 0);
});

run("목록에 없는 키는 invalid-argument, 키가 없으면 서울", async () => {
  assert.strictEqual(resolveRegionKey(undefined), SEOUL_REGION_KEY);
  assert.strictEqual(resolveRegionKey(null), SEOUL_REGION_KEY);
  assert.strictEqual(resolveRegionKey(""), SEOUL_REGION_KEY);
  assert.strictEqual(resolveRegionKey("부산광역시"), "부산광역시");
  const t = deps();
  await rejectsWith(handleGetForecast(USER, {region: "없는 지역"}, t.d), "invalid-argument");
  await rejectsWith(handleGetForecast(USER, {region: 37.5}, t.d), "invalid-argument");
  await rejectsWith(handleGetForecast(USER, {region: "toString"}, t.d), "invalid-argument");
  assert.strictEqual(t.calls(), 0);
  const r = await handleGetForecast(USER, {}, t.d);
  assert.strictEqual(r.region, SEOUL_REGION_KEY);
  assert.deepStrictEqual(t.fetched, [SEOUL_REGION_KEY]);
});

run("기억이 없으면 받아 와서 기억하고, 받아 온 시각을 넣는다", async () => {
  const t = deps();
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "fresh");
  assert.deepStrictEqual(r.forecast, BODY);
  assert.strictEqual(r.fetchedAt, new Date(NOW).toISOString());
  assert.strictEqual(t.store.get(SEOUL_REGION_KEY)?.fetchedAtMs, NOW);
  assert.deepStrictEqual(t.logs, [`[forecast] region=${SEOUL_REGION_KEY} result=fresh ms=0`]);
});

run("30분 안이면 기억한 것을 주고 날씨 서버를 부르지 않는다", async () => {
  const at = NOW - FORECAST_FRESH_MS + 1000;
  const t = deps({cache: {forecast: BODY, fetchedAtMs: at}});
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "cache");
  assert.strictEqual(r.fetchedAt, new Date(at).toISOString());
  assert.strictEqual(t.calls(), 0);
});

run("30분이 지났으면 새로 받는다", async () => {
  const t = deps({cache: {forecast: BODY, fetchedAtMs: NOW - FORECAST_FRESH_MS}});
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "fresh");
  assert.strictEqual(t.calls(), 1);
});

run("날씨 서버 실패 때 6시간 안의 기억을 준다", async () => {
  const at = NOW - FORECAST_STALE_MS + 1000;
  const t = deps({cache: {forecast: BODY, fetchedAtMs: at}, upstream: failing});
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "stale");
  assert.strictEqual(r.fetchedAt, new Date(at).toISOString());
  assert.deepStrictEqual(t.logs, [`[forecast] region=${SEOUL_REGION_KEY} result=stale ms=0 upstream=network`]);
});

run("날씨 서버가 실패하고 기억도 없으면(또는 6시간 지남) 실패를 돌려준다", async () => {
  const none = deps({upstream: failing});
  await rejectsWith(handleGetForecast(USER, {region: SEOUL_REGION_KEY}, none.d), "unavailable");
  const old = deps({cache: {forecast: BODY, fetchedAtMs: NOW - FORECAST_STALE_MS}, upstream: failing});
  await rejectsWith(handleGetForecast(USER, {region: SEOUL_REGION_KEY}, old.d), "unavailable");
  assert.deepStrictEqual(old.logs, [`[forecast] region=${SEOUL_REGION_KEY} result=fail ms=0 upstream=network`]);
});

const MIN = 60 * 1000;

run("기억 31분 + 짧은 요청 실패 → stale, 짧은 요청 1번만(긴 요청 없음)", async () => {
  const at = NOW - 31 * MIN;
  const t = deps({cache: {forecast: BODY, fetchedAtMs: at}, upstream: failing});
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "stale");
  assert.strictEqual(r.fetchedAt, new Date(at).toISOString());
  assert.deepStrictEqual(t.modes, ["quick"]);
  assert.strictEqual(t.store.get(SEOUL_REGION_KEY)?.fetchedAtMs, at); // 기억은 그대로
});

run("기억 31분 + 짧은 요청 성공 → fresh, 기억 갱신", async () => {
  const t = deps({cache: {forecast: BODY, fetchedAtMs: NOW - 31 * MIN}});
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "fresh");
  assert.strictEqual(r.fetchedAt, new Date(NOW).toISOString());
  assert.deepStrictEqual(t.modes, ["quick"]);
  assert.strictEqual(t.store.get(SEOUL_REGION_KEY)?.fetchedAtMs, NOW);
  assert.deepStrictEqual(t.logs, [`[forecast] region=${SEOUL_REGION_KEY} result=fresh ms=0`]);
});

run("기억 없음 → 긴 요청(8초 + 다시 시도)", async () => {
  const t = deps();
  const r = await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.strictEqual(r.source, "fresh");
  assert.deepStrictEqual(t.modes, ["full"]);
});

run("기억 6시간 넘김 + 요청 실패 → unavailable, 긴 요청", async () => {
  const t = deps({cache: {forecast: BODY, fetchedAtMs: NOW - FORECAST_STALE_MS - MIN}, upstream: failing});
  await rejectsWith(handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d), "unavailable");
  assert.deepStrictEqual(t.modes, ["full"]);
});

run("로그의 실패 종류 — timeout·network·status, 걸린 시간", async () => {
  const timeout = new DOMException("The operation was aborted due to timeout", "TimeoutError");
  assert.strictEqual(classifyUpstreamError(timeout), "timeout");
  assert.strictEqual(classifyUpstreamError(new TypeError("fetch failed")), "network");
  assert.strictEqual(classifyUpstreamError(new UpstreamStatusError(503)), "status");
  assert.strictEqual(classifyUpstreamError(new Error("unexpected forecast shape")), "status");
  let clock = NOW;
  const t = deps({
    cache: {forecast: BODY, fetchedAtMs: NOW - 31 * MIN},
    upstream: async () => {
      clock += 2710;
      throw timeout;
    },
  });
  t.d.now = () => clock;
  await handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d);
  assert.deepStrictEqual(t.logs, [`[forecast] region=${SEOUL_REGION_KEY} result=stale ms=2710 upstream=timeout`]);
});

run("상한을 넘으면 resource-exhausted", async () => {
  const t = deps({allow: false});
  await rejectsWith(handleGetForecast(USER, {region: SEOUL_REGION_KEY}, t.d), "resource-exhausted");
  assert.strictEqual(t.calls(), 0);
  assert.deepStrictEqual(nextForecastRate(undefined, "b", 2), {allowed: true, next: {bucket: "b", count: 1}});
  assert.deepStrictEqual(nextForecastRate({bucket: "b", count: 2}, "b", 2), {allowed: false, next: {bucket: "b", count: 2}});
  assert.deepStrictEqual(nextForecastRate({bucket: "a", count: 2}, "b", 2), {allowed: true, next: {bucket: "b", count: 1}});
});

run("로그에는 지역 키와 결과만 — uid가 없다", async () => {
  const t = deps();
  await handleGetForecast({uid: "secret-uid-123"}, {region: SEOUL_REGION_KEY}, t.d);
  assert.ok(t.logs.every((l) => !l.includes("secret-uid-123")));
});

run("요청 주소는 앱과 같은 항목(7일, Asia/Seoul)", () => {
  const u = new URL(forecastUrl(FORECAST_REGIONS[SEOUL_REGION_KEY]));
  assert.strictEqual(u.origin + u.pathname, "https://api.open-meteo.com/v1/forecast");
  assert.strictEqual(u.searchParams.get("current"), "temperature_2m,weather_code");
  assert.strictEqual(u.searchParams.get("daily"), "temperature_2m_max,temperature_2m_min,precipitation_probability_max");
  assert.strictEqual(u.searchParams.get("timezone"), "Asia/Seoul");
  assert.strictEqual(u.searchParams.get("forecast_days"), "7");
});

function fakeFetch(steps: Array<() => Response | Promise<Response>>): {f: typeof fetch; calls: () => number} {
  let i = 0;
  const f = (async () => steps[Math.min(i++, steps.length - 1)]()) as unknown as typeof fetch;
  return {f, calls: () => i};
}
const ok = () => new Response(JSON.stringify({latitude: 1, longitude: 2, ...BODY}), {status: 200});

run("직접 받기 — 시간 초과·통신 오류면 한 번 다시, 응답은 current·daily만", async () => {
  const t = fakeFetch([() => {
    throw new TypeError("fetch failed");
  }, ok]);
  const body = await fetchForecastWithRetry(FORECAST_REGIONS[SEOUL_REGION_KEY], t.f);
  assert.deepStrictEqual(body, BODY);
  assert.strictEqual(t.calls(), 2);
  const twice = fakeFetch([() => {
    throw new TypeError("fetch failed");
  }]);
  await assert.rejects(fetchForecastWithRetry(FORECAST_REGIONS[SEOUL_REGION_KEY], twice.f));
  assert.strictEqual(twice.calls(), 2);
});

run("직접 받기 — 200이 아닌 응답은 다시 시도하지 않는다", async () => {
  const t = fakeFetch([() => new Response("busy", {status: 429}), ok]);
  await assert.rejects(fetchForecastWithRetry(FORECAST_REGIONS[SEOUL_REGION_KEY], t.f));
  assert.strictEqual(t.calls(), 1);
});

run("직접 받기 — 시간 제한이 걸린다", async () => {
  // AbortSignal.timeout의 타이머는 이벤트 루프를 붙잡지 않는다 — 붙잡는 타이머를 같이 둔다.
  const slow = (async (_u: unknown, init?: {signal?: AbortSignal}) =>
    new Promise<Response>((_, reject) => {
      const hold = setTimeout(() => reject(new Error("abort가 오지 않음")), 5000);
      init?.signal?.addEventListener("abort", () => {
        clearTimeout(hold);
        reject(init.signal?.reason);
      });
    })) as unknown as typeof fetch;
  const started = Date.now();
  await assert.rejects(fetchForecastWithRetry(FORECAST_REGIONS[SEOUL_REGION_KEY], slow, 50));
  assert.ok(Date.now() - started < 2000);
});

run("짧은 요청은 다시 시도하지 않고, 긴 요청은 한 번 다시 시도한다", async () => {
  const region = FORECAST_REGIONS[SEOUL_REGION_KEY];
  const quick = fakeFetch([() => {
    throw new TypeError("fetch failed");
  }, ok]);
  await assert.rejects(forecastFetcher(quick.f)(region, "quick"));
  assert.strictEqual(quick.calls(), 1);
  const full = fakeFetch([() => {
    throw new TypeError("fetch failed");
  }, ok]);
  assert.deepStrictEqual(await forecastFetcher(full.f)(region, "full"), BODY);
  assert.strictEqual(full.calls(), 2);
});

function refreshDeps(failKeys: Set<string> = new Set()) {
  const store = new Map<string, ForecastCacheEntry>();
  const logs: string[] = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const keyOf = (region: unknown) => Object.keys(FORECAST_REGIONS).find((k) => FORECAST_REGIONS[k] === region) ?? "?";
  return {
    store,
    logs,
    maxInFlight: () => maxInFlight,
    d: {
      now: () => NOW,
      fetchOnce: async (region: (typeof FORECAST_REGIONS)[string]) => {
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await new Promise((r) => setTimeout(r, 1));
        inFlight--;
        if (failKeys.has(keyOf(region))) throw new TypeError("fetch failed");
        return BODY;
      },
      writeCache: async (key: string, entry: ForecastCacheEntry) => {
        store.set(key, entry);
      },
      log: (l: string) => logs.push(l),
    },
  };
}

run("미리 받아 두기 — 전부 성공하면 지역 수만큼 기록, 동시 4개까지", async () => {
  const n = Object.keys(FORECAST_REGIONS).length;
  const t = refreshDeps();
  const r = await runForecastRefresh(t.d);
  assert.deepStrictEqual(r, {ok: n, fail: 0});
  assert.strictEqual(t.store.size, n);
  for (const e of t.store.values()) assert.deepStrictEqual(e, {forecast: BODY, fetchedAtMs: NOW});
  assert.ok(t.maxInFlight() <= 4, `동시 ${t.maxInFlight()}개`);
  assert.deepStrictEqual(t.logs, [`[forecast-refresh] ok=${n} fail=0 ms=0`]);
});

run("미리 받아 두기 — 일부 실패: 성공한 것만 기록, 실패한 지역의 기억은 그대로, 예외 없음", async () => {
  const keys = Object.keys(FORECAST_REGIONS);
  const n = keys.length;
  const failKeys = new Set([keys[0], keys[n - 1]]);
  const t = refreshDeps(failKeys);
  const old = {forecast: BODY, fetchedAtMs: NOW - 3 * 60 * MIN};
  t.store.set(keys[0], old);
  const r = await runForecastRefresh(t.d);
  assert.deepStrictEqual(r, {ok: n - 2, fail: 2});
  assert.strictEqual(t.store.get(keys[0]), old);
  assert.strictEqual(t.store.has(keys[n - 1]), false);
  assert.strictEqual(t.store.size, n - 1);
  assert.deepStrictEqual(t.logs, [`[forecast-refresh] ok=${n - 2} fail=2 ms=0`]);
  assert.ok(t.logs.every((l) => keys.every((k) => !l.includes(k))), "로그에 지역 이름이 없다");
});

let finished = 0;
// 이벤트 루프가 비어 중간에 끝나면(약속이 풀리지 않음) 통과로 보이지 않게.
process.on("exit", () => {
  if (finished !== tests.length) {
    console.error(`FAIL: ${tests.length - finished}개 테스트가 끝나지 않음`);
    process.exitCode = 1;
  }
});
(async () => {
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`PASS: ${name}`);
      finished++;
    } catch (err) {
      console.error(`FAIL: ${name}`, err);
      throw err;
    }
  }
})().catch(() => process.exit(1));
