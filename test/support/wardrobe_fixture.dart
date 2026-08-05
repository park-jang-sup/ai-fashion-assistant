import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// 두 파일은 **서로 다른 산출물이고 존재 여부도 독립적**이다.
//  - items.json     : export.py가 만드는 103벌 스냅샷(속성·카테고리)
//  - embeddings.json: Kaggle 노트북이 만드는 FashionCLIP 벡터
// items.json은 output/ 디렉터리째, embeddings.json은 개별 항목으로 각각
// .gitignore에 걸려 있다. 따라서 "items는 있는데 embeddings는 없는" 상태가
// 정상적으로 존재하며, 그 경우 조인은 전량 실패한다 — 그래도 예외를 던지지
// 않는다(폴백 방향은 항상 "아무것도 하지 않음"). 대신 그 사실이 숫자로
// 드러나도록 EmbeddingJoinReport를 함께 돌려준다.
const kFixtureItemsPath = 'tools/export_for_kaggle/output/items.json';
const kFixtureEmbeddingsPath = 'tools/export_for_kaggle/embeddings.json';

// backfill_embeddings/backfill.py와 **같은 값**이어야 한다. 다르면 같은
// 파일을 두 도구가 다른 기준으로 받아들여, Firestore에는 실렸는데 하네스
// 에서는 빠지는(또는 그 반대) 벡터가 조용히 생긴다. 서버·클라이언트 판정
// 조건이 한 글자만 달라도 갈린다는 것을 이 저장소는 이미 겪었다
// (findNextUntriggeredDate의 userChoice 조건).
const _normLow = 0.99;
const _normHigh = 1.01;
const _expectedDim = 512;

/// 임베딩 조인의 결과. **호출부가 이 값을 보지 않고 지나가지 못하게** 하려고
/// 아이템 목록과 한 묶음으로 반환한다.
///
/// 이게 없으면 "임베딩 축을 켰는데 산출물이 안 바뀐다"가 (a) 축 구현 문제인지
/// (b) 애초에 벡터가 안 실린 것인지 구분되지 않는다. 5.15.2에서 안전망이
/// 결함을 흡수해 스트리밍 실패가 매번 일어나는데도 관측되지 않았던 것과
/// 같은 구조라, 조인 단계에서 미리 끊어둔다.
class EmbeddingJoinReport {
  /// embeddings.json 파일 자체의 존재 여부. false면 아래 수치는 전부 0이다.
  final bool fileExists;

  /// items.json이 실은 아이템 수(조인 모수).
  final int itemCount;

  /// 벡터를 실제로 얻은 아이템 수.
  final int joined;

  /// embeddings.json에 항목 자체가 없던 아이템 수.
  /// 배치 백필 이후 등록된 아이템이 여기 잡힌다(논문 7.2-5 미해결 항목).
  final int missing;

  /// 항목은 있었으나 검증(차원·유한성·L2 norm)에서 탈락한 수.
  /// **missing과 절대 합치지 않는다** — 전자는 "데이터가 없다", 후자는
  /// "데이터가 있는데 못 쓴다"로 원인도 대응도 다르다.
  final int rejected;

  /// 탈락 사유(아이템 id 포함). 전량 탈락 같은 사고를 눈으로 잡기 위한 것이라
  /// 앞쪽 몇 건만 남긴다.
  final List<String> rejectionSamples;

  /// 파일이 래핑 형식일 때만 채워진다(평면 형식에는 메타가 없다).
  final String? modelName;
  final int? declaredDim;

  const EmbeddingJoinReport({
    required this.fileExists,
    required this.itemCount,
    required this.joined,
    required this.missing,
    required this.rejected,
    required this.rejectionSamples,
    this.modelName,
    this.declaredDim,
  });

  /// 조인 커버리지. 3번 리포트(모수 상한 측정)가 이 값을 함께 실어야
  /// "모수 0인 구간"이 데이터 부재 때문인지 정책 때문인지 사후에 갈린다.
  double get coverage => itemCount == 0 ? 0 : joined / itemCount;

  /// 벡터가 하나도 안 실린 상태. 임베딩 축을 켠 측정을 이 상태에서 돌리면
  /// 결과가 전부 "변화 없음"으로 나오므로, 호출부는 측정 대신 skip 해야 한다.
  bool get isEmpty => joined == 0;

  String describe() {
    if (!fileExists) {
      return '[임베딩조인] $kFixtureEmbeddingsPath 없음 — 벡터 0건, '
          '임베딩 축 측정 불가';
    }
    final meta = modelName == null
        ? '평면 형식(모델 정보 없음)'
        : 'model=$modelName, dim=$declaredDim';
    final buf = StringBuffer()
      ..writeln('[임베딩조인] $meta')
      ..writeln('  모수 $itemCount벌 중 조인 $joined벌 '
          '(${(coverage * 100).toStringAsFixed(1)}%)')
      ..writeln('  항목 없음 $missing벌 / 검증 탈락 $rejected벌');
    for (final r in rejectionSamples) {
      buf.writeln('  - $r');
    }
    return buf.toString().trimRight();
  }
}

/// 기존 시그니처 — **동작을 한 비트도 바꾸지 않는다.**
///
/// 임베딩을 여기서 자동으로 실어버리면, 기존 A/B 리포트(표1~15)를 다시 돌렸을
/// 때 "산출물 변화 0"을 주장하는 근거가 '아무도 embedding을 안 읽는다'는
/// 논증으로 약해진다. 933f322가 정책 주입을 넣을 때 기본값을 현행과 완전히
/// 동일하게 둔 것과 같은 이유로, 조인은 명시적으로 부른 쪽만 받는다.
List<WardrobeItem> loadWardrobeFixture() => _parseItems(_readItemsJson());

/// 임베딩까지 조인해 돌려준다. 7-b 하네스와 모수 상한 리포트 전용.
///
/// items.json이 없으면 호출 자체가 성립하지 않으므로 호출부에서 먼저
/// 존재 여부를 보고 skip 해야 한다(기존 두 테스트와 같은 패턴).
({List<WardrobeItem> items, EmbeddingJoinReport report})
    loadWardrobeFixtureWithEmbeddings() {
  final rows = _readItemsJson();
  final items = _parseItems(rows);

  final file = File(kFixtureEmbeddingsPath);
  if (!file.existsSync()) {
    return (
      items: items,
      report: EmbeddingJoinReport(
        fileExists: false,
        itemCount: items.length,
        joined: 0,
        missing: items.length,
        rejected: 0,
        rejectionSamples: const [],
      ),
    );
  }

  final decoded = jsonDecode(file.readAsStringSync());

  // 형식 판정 규칙을 backfill.py:87과 **글자 단위로 맞춘다.**
  //   래핑: {"model": ..., "dim": ..., "embeddings": {itemId: [...]}}
  //   평면: {itemId: [...]}
  // 한쪽만 지원하면, 노트북이 형식을 바꿔 내보낸 순간 백필은 성공하는데
  // 하네스만 전량 조인 실패하는 상태가 된다 — 그리고 그건 "임베딩 축이
  // 효과 없음"으로 보인다.
  String? modelName;
  int? declaredDim;
  Map<String, dynamic> vectors;
  if (decoded is Map<String, dynamic> && decoded['embeddings'] is Map) {
    modelName = decoded['model'] as String?;
    declaredDim = (decoded['dim'] as num?)?.toInt();
    vectors = Map<String, dynamic>.from(decoded['embeddings'] as Map);
  } else if (decoded is Map<String, dynamic>) {
    vectors = decoded;
  } else {
    // 배열 등 예상 밖 형식. 던지지 않고 "0건 조인"으로 보고한다 —
    // 하네스의 목적은 측정이지 데이터 검증이 아니고, 실패 방향은
    // 언제나 "아무것도 하지 않음"이다.
    return (
      items: items,
      report: EmbeddingJoinReport(
        fileExists: true,
        itemCount: items.length,
        joined: 0,
        missing: 0,
        rejected: items.length,
        rejectionSamples: [
          '파일 최상위가 맵이 아님(type=${decoded.runtimeType}) — '
              'backfill.py가 기대하는 두 형식 중 어느 쪽도 아님',
        ],
      ),
    );
  }

  final dim = declaredDim ?? _expectedDim;
  var joined = 0;
  var missing = 0;
  var rejected = 0;
  final samples = <String>[];

  final merged = <WardrobeItem>[];
  for (final item in items) {
    final raw = vectors[item.id];
    if (raw == null) {
      missing++;
      merged.add(item);
      continue;
    }
    final validated = _validateVector(raw, dim);
    if (validated == null) {
      rejected++;
      if (samples.length < 5) {
        samples.add('${item.id}: ${_rejectionReason(raw, dim)}');
      }
      merged.add(item);
      continue;
    }
    joined++;
    merged.add(_withEmbedding(item, validated));
  }

  return (
    items: merged,
    report: EmbeddingJoinReport(
      fileExists: true,
      itemCount: items.length,
      joined: joined,
      missing: missing,
      rejected: rejected,
      rejectionSamples: samples,
      modelName: modelName,
      declaredDim: declaredDim,
    ),
  );
}

// ── 내부 ──────────────────────────────────────────────────────────

List<dynamic> _readItemsJson() {
  final file = File(kFixtureItemsPath);
  return jsonDecode(file.readAsStringSync()) as List;
}

List<WardrobeItem> _parseItems(List<dynamic> raw) {
  return raw.map((e) {
    final m = e as Map<String, dynamic>;
    final tagsRaw = m['tags'] as String? ?? '';
    final tags = tagsRaw.isEmpty ? <String>[] : tagsRaw.split(';');
    return WardrobeItem(
      id: m['itemId'] as String,
      imageUrl: '',
      category: m['category'] as String? ?? '상의',
      subCategory: m['subCategory'] as String?,
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
          DateTime(2026, 1, 1),
      attributes: ClothingAttributes(
        color: m['color'] as String? ?? '',
        style: m['style'] as String? ?? '',
        pattern: m['pattern'] as String? ?? '',
        formality: m['formality'] as String? ?? '',
        fit: m['fit'] as String? ?? '',
        tags: tags,
      ),
    );
  }).toList();
}

// WardrobeItem에 copyWith가 없다(모델이 Firestore 직렬화 전용으로만 쓰여
// 필요가 없었다). 하네스 하나 때문에 프로덕션 모델에 메서드를 얹지 않고
// 여기서 재구성한다 — tools/eval_harness를 독립 디렉터리로 두기로 한 것과
// 같은 판단(일회성 저자 도구를 프로덕션 코드에 안 얹는다).
WardrobeItem _withEmbedding(WardrobeItem item, List<double> vector) {
  return WardrobeItem(
    id: item.id,
    imageUrl: item.imageUrl,
    cutoutImageUrl: item.cutoutImageUrl,
    category: item.category,
    subCategory: item.subCategory,
    createdAt: item.createdAt,
    attributes: item.attributes,
    size: item.size,
    embedding: vector,
    ownerUid: item.ownerUid,
  );
}

/// backfill.py:validate_vector와 같은 검사. 통과하면 벡터, 아니면 null.
///
/// 여기서 다시 재는 이유: items.json 스냅샷(2026-07-25)과 embeddings.json의
/// 생성 시점이 다를 수 있고, JSON 직렬화를 한 번 더 거친다. 정규화가 깨진
/// 벡터가 섞이면 코사인 순위가 조용히 왜곡되는데, 그 왜곡은 "임베딩 축이
/// 이상한 결과를 낸다"로만 보여 원인 추적이 어렵다.
List<double>? _validateVector(dynamic raw, int dim) {
  if (raw is! List || raw.length != dim) return null;
  final out = <double>[];
  var sumSq = 0.0;
  for (final v in raw) {
    if (v is! num) return null;
    final d = v.toDouble();
    if (!d.isFinite) return null;
    out.add(d);
    sumSq += d * d;
  }
  final norm = math.sqrt(sumSq);
  if (norm < _normLow || norm > _normHigh) return null;
  return out;
}

String _rejectionReason(dynamic raw, int dim) {
  if (raw is! List) return '배열이 아님(type=${raw.runtimeType})';
  if (raw.length != dim) return '길이 불일치(기대 $dim, 실제 ${raw.length})';
  var sumSq = 0.0;
  for (final v in raw) {
    if (v is! num) return '숫자 아닌 값 포함';
    final d = v.toDouble();
    if (!d.isFinite) return 'NaN/inf 포함';
    sumSq += d * d;
  }
  return 'L2 norm이 1에서 벗어남'
      '(${math.sqrt(sumSq).toStringAsFixed(4)}, 허용 $_normLow~$_normHigh)';
}
