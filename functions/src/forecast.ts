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
export const FORECAST_RATE_LIMIT_PER_HOUR = 120;

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

export interface ForecastDeps {
  now(): number;
  readCache(key: string): Promise<ForecastCacheEntry | undefined>;
  writeCache(key: string, entry: ForecastCacheEntry): Promise<void>;
  fetchUpstream(region: ForecastRegion): Promise<ForecastBody>;
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
  if (!(await deps.allowCall(auth.uid))) {
    deps.log(`[forecast] region=${key} result=rate-limited`);
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

  if (cached && now - cached.fetchedAtMs >= 0 && now - cached.fetchedAtMs < FORECAST_FRESH_MS) {
    deps.log(`[forecast] region=${key} result=cache`);
    return respond(cached, "cache");
  }

  try {
    const forecast = await deps.fetchUpstream(FORECAST_REGIONS[key]);
    const entry = {forecast, fetchedAtMs: now};
    try {
      await deps.writeCache(key, entry);
    } catch (_) {
      // 기억하지 못해도 이번 응답은 준다
    }
    deps.log(`[forecast] region=${key} result=fresh`);
    return respond(entry, "fresh");
  } catch (_) {
    if (cached && now - cached.fetchedAtMs >= 0 && now - cached.fetchedAtMs < FORECAST_STALE_MS) {
      deps.log(`[forecast] region=${key} result=stale`);
      return respond(cached, "stale");
    }
    deps.log(`[forecast] region=${key} result=fail`);
    throw new HttpsError("unavailable", "예보를 받아 오지 못했습니다.");
  }
}

// 시간 제한을 두고, 시간 초과·통신 오류면 한 번 다시 시도한다. 200이 아닌 응답과
// 형태가 다른 응답은 다시 시도하지 않는다(앱의 직접 요청과 같은 결).
export async function fetchForecastWithRetry(
  region: ForecastRegion,
  fetchImpl: typeof fetch,
  timeoutMs = FORECAST_UPSTREAM_TIMEOUT_MS
): Promise<ForecastBody> {
  const once = async (): Promise<ForecastBody> => {
    const res = await fetchImpl(forecastUrl(region), {signal: AbortSignal.timeout(timeoutMs)});
    if (res.status !== 200) throw new UpstreamStatusError(res.status);
    return pickForecastBody(await res.json());
  };
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
