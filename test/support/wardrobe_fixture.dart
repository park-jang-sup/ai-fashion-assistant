import 'dart:convert';
import 'dart:io';

import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// 궁합 규칙 전/후 검증용 — tools/export_for_kaggle/output/items.json(실제
// wardrobe 103벌 export본)을 Firestore 없이 WardrobeItem으로 로드한다.
List<WardrobeItem> loadWardrobeFixture() {
  final file = File('tools/export_for_kaggle/output/items.json');
  final raw = jsonDecode(file.readAsStringSync()) as List;
  return raw.map((e) {
    final m = e as Map<String, dynamic>;
    final tagsRaw = m['tags'] as String? ?? '';
    final tags = tagsRaw.isEmpty ? <String>[] : tagsRaw.split(';');
    return WardrobeItem(
      id: m['itemId'] as String,
      imageUrl: '',
      category: m['category'] as String? ?? '상의',
      subCategory: m['subCategory'] as String?,
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime(2026, 1, 1),
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
