import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/image_url_resolver.dart';

// 서명 URL 이행 A-4(docs/task_signed_urls_v1.md) — 킬 스위치. 기본
// false면 이 위젯은 항상 fallbackUrl(기존 imageUrl/cutoutImageUrl)만
// 쓰고 ImageUrlResolver를 아예 건드리지 않는다 — off 경로 비용 0,
// 산출물이 CachedNetworkImage(imageUrl: fallbackUrl)와 100% 동일하다
// (useEmbeddingRecovery/fillOptionalFromRelaxed와 같은 "기본 비활성
// 도입" 패턴).
//
//   flutter run --dart-define=SIGNED_URLS=true
const bool signedUrlsEnabled =
    bool.fromEnvironment('SIGNED_URLS', defaultValue: false);

// wardrobe/demo_wardrobe/fitting_cache 이미지를 그리는 공통 위젯 —
// CachedNetworkImage를 감싸 SIGNED_URLS on일 때만 ImageUrlResolver를
// 거친다. 화면들은 CachedNetworkImage(imageUrl: item.cutoutImageUrl ??
// item.imageUrl, ...)를 이 위젯으로 바꿔 쓴다.
class SignedNetworkImage extends StatefulWidget {
  final String collection;
  final String id;
  // signed_url_policy.ts decideSignedUrlAccess의 paths 순서와 동일 —
  // wardrobe/demo_wardrobe는 0=이미지, 1=컷아웃. fitting_cache는 0뿐.
  final int urlIndex;
  final String fallbackUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  const SignedNetworkImage({
    super.key,
    required this.collection,
    required this.id,
    this.urlIndex = 0,
    required this.fallbackUrl,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<SignedNetworkImage> createState() => _SignedNetworkImageState();
}

class _SignedNetworkImageState extends State<SignedNetworkImage> {
  String? _resolvedUrl;

  @override
  void initState() {
    super.initState();
    if (signedUrlsEnabled) _resolve();
  }

  @override
  void didUpdateWidget(covariant SignedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 그리드가 재사용(리스트 재정렬 등)되며 같은 위젯 인스턴스가 다른
    // 문서를 가리키게 되면 다시 해석한다.
    if (signedUrlsEnabled &&
        (oldWidget.collection != widget.collection || oldWidget.id != widget.id)) {
      _resolvedUrl = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final urls = await ImageUrlResolver.resolve(
      collection: widget.collection,
      id: widget.id,
    );
    if (!mounted) return;
    if (urls != null && widget.urlIndex < urls.length) {
      setState(() => _resolvedUrl = urls[widget.urlIndex]);
    }
    // null이거나 인덱스 밖이면 _resolvedUrl은 null로 남아 build()가
    // fallbackUrl을 쓴다 — ImageUrlResolver.fallbackCount는 이미
    // resolve() 안에서 증가했다.
  }

  @override
  Widget build(BuildContext context) {
    final url =
        signedUrlsEnabled ? (_resolvedUrl ?? widget.fallbackUrl) : widget.fallbackUrl;
    return CachedNetworkImage(
      imageUrl: url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
    );
  }
}
