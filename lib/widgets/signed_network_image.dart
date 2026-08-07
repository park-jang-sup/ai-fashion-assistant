import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/image_url_resolver.dart';

export '../services/image_url_resolver.dart'
    show signedUrlsEnabled, resolveFittingImageTarget;

// 서명 URL 이행 A-4(docs/task_signed_urls_v1.md) — 킬 스위치. 기본
// false면 이 위젯은 항상 fallbackUrl(기존 imageUrl/cutoutImageUrl)만
// 쓰고 ImageUrlResolver를 아예 건드리지 않는다 — off 경로 비용 0,
// 산출물이 CachedNetworkImage(imageUrl: fallbackUrl)와 100% 동일하다
// (useEmbeddingRecovery/fillOptionalFromRelaxed와 같은 "기본 비활성
// 도입" 패턴). 플래그 자체는 services/image_url_resolver.dart에 있다
// — A-5(군 (a))에서 GeminiService도 이 플래그로 게이팅해야 해서
// 서비스 계층으로 옮기고 여기서는 재수출만 한다(기존 import부
// 호환 유지).

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
  final Alignment alignment;
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
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<SignedNetworkImage> createState() => _SignedNetworkImageState();
}

class _SignedNetworkImageState extends State<SignedNetworkImage> {
  String? _resolvedUrl;
  // A-6 — 서명 해석이 최종 실패했다(재시도까지 소진). Phase C 이후에는
  // fallbackUrl도 죽어있을 수 있으므로, 이 경우 errorWidget을 탭하면
  // 다시 시도할 수 있게 한다 — "폴백이라 괜찮다"가 회수 후엔 성립하지
  // 않는다는 §10 재감사 지적에 대한 조치.
  bool _resolveFailed = false;

  @override
  void initState() {
    super.initState();
    if (signedUrlsEnabled) _resolve();
  }

  @override
  void didUpdateWidget(covariant SignedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!signedUrlsEnabled) return;

    // 그리드가 재사용(리스트 재정렬 등)되며 같은 위젯 인스턴스가 다른
    // 문서를 가리키게 되면 다시 해석한다.
    if (oldWidget.collection != widget.collection || oldWidget.id != widget.id) {
      _resolvedUrl = null;
      _resolveFailed = false;
      _resolve();
      return;
    }

    // 갱신 결함 수정(2026-08-07, 실기기 실측 확인 — 등록 직후 컷아웃이
    // 반영돼도 화면을 유지한 채로는 깨진 이미지로 남고 앱 재시작
    // 후에만 정상화됐다) — 같은 문서라도 fallbackUrl(cutoutImageUrl
    // ?? imageUrl)이 바뀌면 서명 대상 경로 집합이 바뀐 것이다(컷아웃이
    // 새로 생기면 이 코드베이스 모든 호출부가 urlIndex도 함께
    // `item.cutoutImageUrl != null`에서 그대로 유도해 0→1로 바뀐다 —
    // urlIndex는 fallbackUrl의 파생값이다). fallbackUrl 쪽을 보는 게
    // 더 일반적인 신호다: 컷아웃이 재처리로 값만 바뀌고 urlIndex는
    // 1→1로 그대로인 경우도 urlIndex 비교로는 놓치지만 fallbackUrl
    // 비교로는 잡힌다. ImageUrlResolver의 캐시는 문서 단위로 만료
    // 80% 시점까지 유지되므로(§3-3) 여기서 바로 _resolve()만 부르면
    // 그 캐시가 옛(더 짧은) urls 배열을 그대로 돌려줘 urlIndex가
    // 범위를 벗어나 오히려 깨진 상태가 재현된다 — 그래서 재해석
    // 전에 캐시를 먼저 비운다.
    if (oldWidget.fallbackUrl != widget.fallbackUrl) {
      ImageUrlResolver.invalidate(widget.id);
      _resolvedUrl = null;
      _resolveFailed = false;
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
      setState(() {
        _resolvedUrl = urls[widget.urlIndex];
        _resolveFailed = false;
      });
    } else {
      // null이거나 인덱스 밖 — _resolvedUrl은 null로 남아 build()가
      // fallbackUrl을 쓴다(ImageUrlResolver.fallbackCount는 이미
      // resolve() 안에서 증가했다). 재시도 가능 상태로 표시한다.
      setState(() => _resolveFailed = true);
    }
  }

  void _retry() {
    setState(() => _resolveFailed = false);
    _resolve();
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
      alignment: widget.alignment,
      placeholder: widget.placeholder,
      errorWidget: (context, url, error) {
        final inner = widget.errorWidget?.call(context, url, error) ??
            const Icon(Icons.image_not_supported_outlined);
        // 서명 해석이 실패해서 여기 온 경우에만 재시도를 건다 —
        // fallbackUrl 자체가 유효한 이미지가 아닌 경우(진짜 깨진
        // 이미지)까지 재시도 버튼을 붙이면 오해를 준다.
        if (!signedUrlsEnabled || !_resolveFailed) return inner;
        return GestureDetector(
          onTap: _retry,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              inner,
              const Positioned(
                bottom: 2,
                right: 2,
                child: Icon(Icons.refresh, size: 14, color: Colors.white70),
              ),
            ],
          ),
        );
      },
    );
  }
}
