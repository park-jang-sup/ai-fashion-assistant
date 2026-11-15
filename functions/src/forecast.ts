// getForecast — 서버가 Open-Meteo 예보를 대신 받아 지역별로 기억해 둔다.
// 폰에서 날씨 서버로 가는 길이 몇 분씩 끊기는 일이 있어(2026-11-15 실기기 시간 초과),
// 서울 지역 함수가 받아 오면 폰의 통신 경로와 무관해진다.
//
// 이 파일은 순수 로직(인자 해석, 기억 사용 판단, 상한)만 — Firestore·fetch는 index.ts가
// 의존성으로 넣는다. 테스트는 forecast.test.ts.
import {HttpsError} from "firebase-functions/v2/https";
import {FORECAST_REGIONS, ForecastRegion, SEOUL_REGION_KEY} from "./forecast_regions";

export const FORECAST_FRESH_MS = 30 * 60 * 1000; // 30분 안이면 기억한 것
export const FORECAST_STALE_MS = 6 * 60 * 60 * 1000; // 날씨 서버 실패 때 6시간 안의 기억
export const FORECAST_UPSTREAM_TIMEOUT_MS = 8000;
// 기억이 30분~6시간이면 짧게 한 번만 묻는다 — 실패하면 바로 기억을 준다. 앱의 서버 함수
// 시한(8초, lib/services/weather_service.dart) 안에 답하기 위해서다. 2026-11-15 날씨 서버가
// 답하지 않을 때 8초 × 2회를 기다리느라 약 16초 뒤에야 stale을 돌려줘 앱이 먼저 포기했다.
export const FORECAST_QUICK_TIMEOUT_MS = 2500;
export const FORECAST_RATE_LIMIT_PER_HOUR = 120;
export const FORECAST_REFRESH_CONCURRENCY = 4; // 미리 받아 두기 — 동시에 묻는 지역 수

const OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast";

// 앱이 직접 요청할 때와 같은 항목(lib/services/weather_service.dart).
export function forecastUrl(region: ForecastRegion): string {
  const q = new URLSearchParams({
    latitude: `${region.latitude}`,
    longitude: `${region.longitude}`,
    current: "temperature_2m,weather_code",
    daily: "temperature_2m_max,temperature_2m_min,precipitation_probability_max",
    timezone: "Asia/Seoul",
    forecast_days: "7",
  });
  return `${OPEN_METEO_URL}?${q.toString()}`;
}

// 앱의 해석 코드(WeatherSnapshot.fromOpenMeteo)가 읽는 부분만 — current, daily.
export interface ForecastBody {
  current: Record<string, unknown>;
  daily: Record<string, unknown>;
}

export function pickForecastBody(json: unknown): ForecastBody {
  const o = json as {current?: unknown; daily?: unknown} | null;
  if (!o || typeof o.current !== "object" || o.current === null ||
      typeof o.daily !== "object" || o.daily === null) {
    throw new Error("unexpected forecast shape");
  }
  return {current: o.current as Record<string, unknown>, daily: o.daily as Record<string, unknown>};
}

export interface ForecastCacheEntry {
  forecast: ForecastBody;
  fetchedAtMs: number;
}

// quick: FORECAST_QUICK_TIMEOUT_MS 한 번(다시 시도 없음), full: 8초 + 한 번 다시 시도.
export type UpstreamMode = "quick" | "full";

export interface ForecastDeps {
  now(): number;
  readCache(key: string): Promise<ForecastCacheEntry | undefined>;
  writeCache(key: string, entry: ForecastCacheEntry): Promise<void>;
  fetchUpstream(region: ForecastRegion, mode: UpstreamMode): Promise<ForecastBody>;
  // 상한 — 넘으면 false. 판정 자체가 실패하면 허용(fail-open)은 호출부 몫.
  allowCall(uid: string): Promise<boolean>;
  log(line: string): void;
}

export type ForecastSource = "fresh" | "cache" | "stale";

export interface ForecastResponse {
  forecast: ForecastBody;
  fetchedAt: string; // ISO — 받아 온 시각
  source: ForecastSource;
  region: string;
}

// 키가 없으면(undefined·null·빈 글자) 서울. 목록에 없는 글자나 글자가 아닌 값은 거부.
export function resolveRegionKey(raw: unknown): string {
  if (raw === undefined || raw === null || raw === "") return SEOUL_REGION_KEY;
  if (typeof raw !== "string" || !Object.prototype.hasOwnProperty.call(FORECAST_REGIONS, raw)) {
    throw new HttpsError("invalid-argument", "지원하지 않는 지역입니다.");
  }
  return raw;
}

export async function handleGetForecast(
  auth: {uid: string} | undefined,
  data: unknown,
  deps: ForecastDeps
): Promise<ForecastResponse> {
  if (!auth) throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
  const key = resolveRegionKey((data as {region?: unknown} | null)?.region);
  const started = deps.now();
  // 로그는 지역 키, 결과, 걸린 시간, (날씨 서버 실패 때) 실패 종류만 — uid는 남기지 않는다.
  const log = (result: string, err?: unknown): void =>
    deps.log(`[forecast] region=${key} result=${result} ms=${deps.now() - started}` +
      (err === undefined ? "" : ` upstream=${classifyUpstreamError(err)}`));
  if (!(await deps.allowCall(auth.uid))) {
    log("rate-limited");
    throw new HttpsError("resource-exhausted", "호출량이 많아 잠시 후 다시 시도해주세요.");
  }

  let cached: ForecastCacheEntry | undefined;
  try {
    cached = await deps.readCache(key);
  } catch (_) {
    cached = undefined; // 기억을 못 읽으면 새로 받는다
  }
  const now = deps.now();
  const respond = (entry: ForecastCacheEntry, source: ForecastSource): ForecastResponse => ({
    forecast: entry.forecast,
    fetchedAt: new Date(entry.fetchedAtMs).toISOString(),
    source,
    region: key,
  });

  const age = cached ? now - cached.fetchedAtMs : -1;
  if (cached && age >= 0 && age < FORECAST_FRESH_MS) {
    log("cache");
    return respond(cached, "cache");
  }

  const fresh = async (mode: UpstreamMode): Promise<ForecastResponse> => {
    const forecast = await deps.fetchUpstream(FORECAST_REGIONS[key], mode);
    const entry = {forecast, fetchedAtMs: now};
    try {
      await deps.writeCache(key, entry);
    } catch (_) {
      // 기억하지 못해도 이번 응답은 준다
    }
    log("fresh");
    return respond(entry, "fresh");
  };

  // 기억이 30분~6시간: 짧게 한 번만 묻고, 실패하면 바로 기억을 준다.
  if (cached && age >= 0 && age < FORECAST_STALE_MS) {
    try {
      return await fresh("quick");
    } catch (err) {
      log("stale", err);
      return respond(cached, "stale");
    }
  }

  // 기억이 없거나 6시간을 넘겼으면: 8초 + 한 번 다시 시도, 실패하면 unavailable.
  try {
    return await fresh("full");
  } catch (err) {
    log("fail", err);
    throw new HttpsError("unavailable", "예보를 받아 오지 못했습니다.");
  }
}

// 날씨 서버 실패의 종류(로그용). 200이 아닌 응답과 형태가 다른 응답은 status로 묶는다.
export type UpstreamFailure = "timeout" | "network" | "status";

export function classifyUpstreamError(err: unknown): UpstreamFailure {
  if (err instanceof UpstreamStatusError) return "status";
  if (err instanceof Error && err.message === "unexpected forecast shape") return "status";
  const name = (err as {name?: unknown} | null)?.name;
  if (name === "TimeoutError" || name === "AbortError") return "timeout";
  return "network";
}

// 시간 제한을 두고 한 번만 묻는다.
export async function fetchForecastOnce(
  region: ForecastRegion,
  fetchImpl: typeof fetch,
  timeoutMs: number
): Promise<ForecastBody> {
  const res = await fetchImpl(forecastUrl(region), {signal: AbortSignal.timeout(timeoutMs)});
  if (res.status !== 200) throw new UpstreamStatusError(res.status);
  return pickForecastBody(await res.json());
}

// getForecast의 fetchUpstream — quick은 짧게 한 번, full은 8초 + 한 번 다시 시도.
export function forecastFetcher(fetchImpl: typeof fetch): ForecastDeps["fetchUpstream"] {
  return (region, mode) => mode === "quick" ?
    fetchForecastOnce(region, fetchImpl, FORECAST_QUICK_TIMEOUT_MS) :
    fetchForecastWithRetry(region, fetchImpl);
}

// 미리 받아 두기(refreshForecastCache, 20분마다) — 모든 지역을 받아 기억을 늘 새것으로 둔다.
// 성공한 지역만 쓰고, 실패한 지역의 기존 기억은 건드리지 않는다. 어떤 지역이 실패해도 던지지 않는다.
export interface ForecastRefreshDeps {
  now(): number;
  fetchOnce(region: ForecastRegion): Promise<ForecastBody>; // 8초 한 번, 다시 시도 없음
  writeCache(key: string, entry: ForecastCacheEntry): Promise<void>;
  log(line: string): void;
}

export async function runForecastRefresh(
  deps: ForecastRefreshDeps,
  concurrency = FORECAST_REFRESH_CONCURRENCY
): Promise<{ok: number; fail: number}> {
  const started = deps.now();
  const keys = Object.keys(FORECAST_REGIONS);
  let next = 0;
  let ok = 0;
  let fail = 0;
  const worker = async (): Promise<void> => {
    while (next < keys.length) {
      const key = keys[next++];
      try {
        const forecast = await deps.fetchOnce(FORECAST_REGIONS[key]);
        await deps.writeCache(key, {forecast, fetchedAtMs: deps.now()});
        ok++;
      } catch (_) {
        fail++;
      }
    }
  };
  await Promise.all(Array.from({length: Math.min(concurrency, keys.length)}, worker));
  // 지역 이름은 남기지 않는다 — 수와 걸린 시간만.
  deps.log(`[forecast-refresh] ok=${ok} fail=${fail} ms=${deps.now() - started}`);
  return {ok, fail};
}

// 시간 제한을 두고, 시간 초과·통신 오류면 한 번 다시 시도한다. 200이 아닌 응답과
// 형태가 다른 응답은 다시 시도하지 않는다(앱의 직접 요청과 같은 결).
export async function fetchForecastWithRetry(
  region: ForecastRegion,
  fetchImpl: typeof fetch,
  timeoutMs = FORECAST_UPSTREAM_TIMEOUT_MS
): Promise<ForecastBody> {
  const once = (): Promise<ForecastBody> => fetchForecastOnce(region, fetchImpl, timeoutMs);
  try {
    return await once();
  } catch (err) {
    if (err instanceof UpstreamStatusError || (err instanceof Error && err.message === "unexpected forecast shape")) {
      throw err;
    }
    return await once();
  }
}

export class UpstreamStatusError extends Error {
  constructor(readonly status: number) {
    super(`upstream status ${status}`);
  }
}

// uid별 시간 버킷 카운터(가벼운 상한).
export interface ForecastRateState {
  bucket: string;
  count: number;
}

export function nextForecastRate(
  state: ForecastRateState | undefined,
  bucket: string,
  limit = FORECAST_RATE_LIMIT_PER_HOUR
): {allowed: boolean; next: ForecastRateState} {
  const count = state && state.bucket === bucket ? state.count : 0;
  if (count >= limit) return {allowed: false, next: {bucket, count}};
  return {allowed: true, next: {bucket, count: count + 1}};
}
