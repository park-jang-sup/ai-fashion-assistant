// 광역시도 17개 대표 좌표 — 지오코딩 없이 옷차림 판단에 쓸 날씨 조회
// 해상도(시도 단위)만 맞추면 충분하다는 판단으로 하드코딩한다(신규
// 의존성 금지). 각 시도 청사·중심지 부근 좌표.
class RegionPreset {
  final String name;
  final double latitude;
  final double longitude;

  const RegionPreset({required this.name, required this.latitude, required this.longitude});
}

// '서울특별시'는 WeatherService의 미설정 폴백 좌표(37.57, 126.98)와
// 일부러 같은 값을 쓴다 — 서울이 두 가지 서로 다른 좌표로 존재하지
// 않게 하기 위함.
const regionPresets = [
  RegionPreset(name: '서울특별시', latitude: 37.57, longitude: 126.98),
  RegionPreset(name: '부산광역시', latitude: 35.1796, longitude: 129.0756),
  RegionPreset(name: '대구광역시', latitude: 35.8714, longitude: 128.6014),
  RegionPreset(name: '인천광역시', latitude: 37.4563, longitude: 126.7052),
  RegionPreset(name: '광주광역시', latitude: 35.1595, longitude: 126.8526),
  RegionPreset(name: '대전광역시', latitude: 36.3504, longitude: 127.3845),
  RegionPreset(name: '울산광역시', latitude: 35.5384, longitude: 129.3114),
  RegionPreset(name: '세종특별자치시', latitude: 36.4800, longitude: 127.2890),
  RegionPreset(name: '경기도', latitude: 37.4138, longitude: 127.5183),
  RegionPreset(name: '강원특별자치도', latitude: 37.8228, longitude: 128.1555),
  RegionPreset(name: '충청북도', latitude: 36.6357, longitude: 127.4917),
  RegionPreset(name: '충청남도', latitude: 36.5184, longitude: 126.8000),
  RegionPreset(name: '전북특별자치도', latitude: 35.7175, longitude: 127.1530),
  RegionPreset(name: '전라남도', latitude: 34.8161, longitude: 126.4630),
  RegionPreset(name: '경상북도', latitude: 36.4919, longitude: 128.8889),
  RegionPreset(name: '경상남도', latitude: 35.4606, longitude: 128.2132),
  RegionPreset(name: '제주특별자치도', latitude: 33.4996, longitude: 126.5312),
];
