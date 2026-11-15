// 앱의 지역 목록(lib/data/region_presets.dart)과 같은 표 — 이름이 지역 키다.
// 바꿀 때는 두 파일을 같은 커밋에서 함께 바꾼다(test/forecast_regions_sync_test.dart가 대조).
export interface ForecastRegion {
  latitude: number;
  longitude: number;
}

export const SEOUL_REGION_KEY = "서울특별시";

export const FORECAST_REGIONS: Record<string, ForecastRegion> = {
  "서울특별시": {latitude: 37.57, longitude: 126.98},
  "부산광역시": {latitude: 35.1796, longitude: 129.0756},
  "대구광역시": {latitude: 35.8714, longitude: 128.6014},
  "인천광역시": {latitude: 37.4563, longitude: 126.7052},
  "광주광역시": {latitude: 35.1595, longitude: 126.8526},
  "대전광역시": {latitude: 36.3504, longitude: 127.3845},
  "울산광역시": {latitude: 35.5384, longitude: 129.3114},
  "세종특별자치시": {latitude: 36.4800, longitude: 127.2890},
  "경기도": {latitude: 37.4138, longitude: 127.5183},
  "강원특별자치도": {latitude: 37.8228, longitude: 128.1555},
  "충청북도": {latitude: 36.6357, longitude: 127.4917},
  "충청남도": {latitude: 36.5184, longitude: 126.8000},
  "전북특별자치도": {latitude: 35.7175, longitude: 127.1530},
  "전라남도": {latitude: 34.8161, longitude: 126.4630},
  "경상북도": {latitude: 36.4919, longitude: 128.8889},
  "경상남도": {latitude: 35.4606, longitude: 128.2132},
  "제주특별자치도": {latitude: 33.4996, longitude: 126.5312},
};
