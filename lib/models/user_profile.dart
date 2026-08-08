class UserProfile {
  final int? heightCm;
  final double? weightKg;
  final String? personalColor; // 봄웜/여름쿨/가을웜/겨울쿨
  final String? bodyType; // 마른 체형/보통 체형/통통한 체형/근육질 체형
  final int? waistCm;
  final int? chestCm;
  final List<String> preferredStyles; // 캐주얼/포멀/스트릿/미니멀/스포티 중 다중 선택
  final String? regionName; // 광역시도 이름(lib/data/region_presets.dart 중 하나)
  final double? regionLatitude;
  final double? regionLongitude;

  const UserProfile({
    this.heightCm,
    this.weightKg,
    this.personalColor,
    this.bodyType,
    this.waistCm,
    this.chestCm,
    this.preferredStyles = const [],
    this.regionName,
    this.regionLatitude,
    this.regionLongitude,
  });

  UserProfile copyWith({
    int? heightCm,
    double? weightKg,
    String? personalColor,
    String? bodyType,
    int? waistCm,
    int? chestCm,
    List<String>? preferredStyles,
    String? regionName,
    double? regionLatitude,
    double? regionLongitude,
  }) {
    return UserProfile(
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
      personalColor: personalColor ?? this.personalColor,
      bodyType: bodyType ?? this.bodyType,
      waistCm: waistCm ?? this.waistCm,
      chestCm: chestCm ?? this.chestCm,
      preferredStyles: preferredStyles ?? this.preferredStyles,
      regionName: regionName ?? this.regionName,
      regionLatitude: regionLatitude ?? this.regionLatitude,
      regionLongitude: regionLongitude ?? this.regionLongitude,
    );
  }

  // 코디 분석 프롬프트에서 "이 사용자가 뭐라도 입력했는지" 판단하는 기준.
  // 하나라도 채워져 있으면 프로필 텍스트를 쓰고, 전부 비어 있으면
  // 기존처럼 전신 사진 폴백으로 넘어간다(gemini_service.dart의
  // !hasProfile && userPhotoUrl != null 분기).
  //
  // regionName/regionLatitude/regionLongitude는 **의도적으로 여기서
  // 뺐다.** 이 게터는 "체형/취향 정보가 있어 프로필 텍스트로 대체
  // 가능한가"를 판단하는 것이지 "프로필 문서에 뭐라도 들어있는가"가
  // 아니다 — 지역은 체형 정보가 아니라 코디 분석과 무관하다. 지역만
  // 설정하고 체형은 입력 안 한 사용자가 여기 걸려 전신 사진 경로를
  // 잃으면 안 된다(사진이 없어야 할 이유가 없는데 없어짐). 새 필드를
  // 추가할 때 무조건 여기 넣지 말 것 — "체형/취향 정보인가"를 먼저
  // 물을 것.
  bool get hasAnyData =>
      heightCm != null ||
      weightKg != null ||
      personalColor != null ||
      bodyType != null ||
      waistCm != null ||
      chestCm != null ||
      preferredStyles.isNotEmpty;

  factory UserProfile.fromFirestore(Map<String, dynamic> data) {
    return UserProfile(
      heightCm: data['heightCm'] as int?,
      weightKg: (data['weightKg'] as num?)?.toDouble(),
      personalColor: data['personalColor'] as String?,
      bodyType: data['bodyType'] as String?,
      waistCm: data['waistCm'] as int?,
      chestCm: data['chestCm'] as int?,
      preferredStyles:
          (data['preferredStyles'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      regionName: data['regionName'] as String?,
      regionLatitude: (data['regionLatitude'] as num?)?.toDouble(),
      regionLongitude: (data['regionLongitude'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        if (heightCm != null) 'heightCm': heightCm,
        if (weightKg != null) 'weightKg': weightKg,
        if (personalColor != null) 'personalColor': personalColor,
        if (bodyType != null) 'bodyType': bodyType,
        if (waistCm != null) 'waistCm': waistCm,
        if (chestCm != null) 'chestCm': chestCm,
        if (preferredStyles.isNotEmpty) 'preferredStyles': preferredStyles,
        if (regionName != null) 'regionName': regionName,
        if (regionLatitude != null) 'regionLatitude': regionLatitude,
        if (regionLongitude != null) 'regionLongitude': regionLongitude,
      };

  // 코디 분석 프롬프트에 그대로 삽입할 한 줄 요약. 입력된 필드만 포함한다.
  String toPromptLine() {
    final parts = <String>[];
    if (heightCm != null) parts.add('키 ${heightCm}cm');
    if (weightKg != null) parts.add('몸무게 ${weightKg}kg');
    if (personalColor != null) parts.add('퍼스널 컬러 $personalColor');
    if (bodyType != null) parts.add('체형 $bodyType');
    if (waistCm != null) parts.add('허리둘레 ${waistCm}cm');
    if (chestCm != null) parts.add('가슴둘레 ${chestCm}cm');
    if (preferredStyles.isNotEmpty) parts.add('선호 스타일 ${preferredStyles.join(', ')}');
    return parts.join(', ');
  }
}
