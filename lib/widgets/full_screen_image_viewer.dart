import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import 'signed_network_image.dart';

// 핀치 확대/축소가 가능한 전체 화면 이미지 뷰어 — fitting_room_screen(가상
// 피팅 결과)과 scrap_screen(스크랩한 착장)에서 공용으로 쓴다.
//
// A-5 군 (b)(docs/task_signed_urls_v1.md §10): signedCollection/signedId를
// 같이 넘기면 서명 경로로 로드하고, 없으면(호출부가 캐시 키를 못 구한
// 경우 — 군 (c)) 기존 CachedNetworkImage(imageUrl) 그대로 유지한다.
class FullScreenImageViewer extends StatelessWidget {
  final Uint8List? imageBytes;
  final String? imageUrl;
  final String label;
  final String? signedCollection;
  final String? signedId;

  const FullScreenImageViewer({
    super.key,
    this.imageBytes,
    this.imageUrl,
    required this.label,
    this.signedCollection,
    this.signedId,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 5.0,
              child: imageBytes != null
                  ? Image.memory(imageBytes!, fit: BoxFit.contain)
                  : (signedCollection != null && signedId != null)
                      ? SignedNetworkImage(
                          collection: signedCollection!,
                          id: signedId!,
                          fallbackUrl: imageUrl!,
                          fit: BoxFit.contain,
                          placeholder: (_, __) => const Center(
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2)),
                          errorWidget: (_, __, ___) => const Icon(
                              Icons.image_outlined,
                              color: Colors.white54,
                              size: 48),
                        )
                      : CachedNetworkImage(
                          imageUrl: imageUrl!,
                          fit: BoxFit.contain,
                          placeholder: (_, __) => const Center(
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2)),
                          errorWidget: (_, __, ___) => const Icon(
                              Icons.image_outlined,
                              color: Colors.white54,
                              size: 48),
                        ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                        color: AppColors.navy.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_awesome, color: Colors.white, size: 12),
                        const SizedBox(width: 5),
                        Text(label,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
