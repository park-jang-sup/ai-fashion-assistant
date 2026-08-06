import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/image_url_resolver.dart';

// A-6(docs/task_signed_urls_v1.md §10-1) — resolveFittingImageTarget이
// (c)군 표시 지점들의 raw CachedNetworkImage 폴백 조건을 얼마나
// 좁히는지 검증한다. 순수 함수라 네트워크/Firebase 없이 테스트한다.
void main() {
  const fittingUrl =
      'https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/fitting_results%2Fabc123.jpg?alt=media&token=t';
  const wardrobeUrl =
      'https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/wardrobe_images%2F1234567.jpg?alt=media&token=t';
  const cutoutUrl =
      'https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/wardrobe_cutouts%2Fitem_norm_9.png?alt=media&token=t';

  test('fittingCacheKey가 있으면 그걸 그대로 쓴다(URL은 안 본다)', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: fittingUrl,
      fittingCacheKey: 'explicitKey',
    );
    expect(target, (collection: 'fitting_cache', id: 'explicitKey'));
  });

  test('cacheKey 없고 fitting_results/ URL이면 파일명을 역산해 fitting_cache로 서명한다', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: fittingUrl,
      fittingCacheKey: null,
    );
    expect(target, (collection: 'fitting_cache', id: 'abc123'));
  });

  test('cacheKey 없고 wardrobe_images/ URL이면 itemIds의 첫 항목으로 wardrobe 서명한다', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: wardrobeUrl,
      fittingCacheKey: null,
      itemIds: ['wItem1', 'wItem2'],
    );
    expect(target, (collection: 'wardrobe', id: 'wItem1'));
  });

  test('cacheKey 없고 wardrobe_cutouts/ URL이어도 동일하게 wardrobe로 서명한다', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: cutoutUrl,
      fittingCacheKey: null,
      itemIds: ['wItem1'],
    );
    expect(target, (collection: 'wardrobe', id: 'wItem1'));
  });

  test('wardrobe 패턴인데 itemIds가 비어있으면 서명 불가(null)', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: wardrobeUrl,
      fittingCacheKey: null,
      itemIds: const [],
    );
    expect(target, isNull);
  });

  test('URL도 cacheKey도 없으면 null', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: null,
      fittingCacheKey: null,
      itemIds: ['x'],
    );
    expect(target, isNull);
  });

  test('알 수 없는 경로 패턴이면 null(안전하게 폴백)', () {
    final target = resolveFittingImageTarget(
      fittingImageUrl: 'https://images.unsplash.com/photo-123?x=1',
      fittingCacheKey: null,
      itemIds: ['x'],
    );
    expect(target, isNull);
  });
}
