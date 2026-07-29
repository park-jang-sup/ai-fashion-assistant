import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_colors.dart';
import '../models/outfit_history_entry.dart';
import '../models/wardrobe_item.dart';
import '../services/firestore_service.dart';

// 보드에 배치되는 슬롯 정의. key는 화면 내부 상태 식별자(및 selectedItems의
// 키)로 쓰이고, category는 wardrobeStream을 필터링할 때 쓰는 실제 등록
// 카테고리 — 모자/가방/시계/팔찌는 전부 "액세서리" 카테고리 안에서
// subCategory로 구분해서 고른다. subCategory가 null인 슬롯은 해당
// 카테고리 전체에서 고르면 된다는 뜻.
const outfitBoardSlots = [
  (key: '아우터', label: '아우터', category: '아우터', subCategory: null),
  (key: '상의', label: '상의', category: '상의', subCategory: null),
  (key: '하의', label: '하의', category: '하의', subCategory: null),
  (key: '신발', label: '신발', category: '신발', subCategory: null),
  (key: '모자', label: '모자', category: '액세서리', subCategory: '모자'),
  (key: '가방', label: '가방', category: '액세서리', subCategory: '가방'),
  (key: '시계', label: '시계', category: '액세서리', subCategory: '시계'),
  (key: '팔찌', label: '팔찌', category: '액세서리', subCategory: '팔찌'),
];

// 무신사 룩북 스타일 플랫레이 배치 좌표 — 전부 보드 크기(가로/세로) 대비
// 비율(0~1)이며 실측 옷을 넣어보며 조정하기 쉽도록 한곳에 모아둔다.
class _BoardLayout {
  const _BoardLayout._();

  static const double aspectRatio = 3 / 4;
  static const Color backgroundColor = Color(0xFF2A2A2A);

  // 상의 (아우터 없을 때 — 보드 상단 중앙). 박스 높이를 넉넉히 줘야
  // BoxFit.contain으로 렌더링될 때 실제 이미지가 목표 폭(55~60%)까지
  // 커질 여유가 생긴다 — 높이가 좁으면 세로로 긴 사진일수록 폭이
  // 의도보다 훨씬 작게 그려진다.
  static const double topLeft = 0.19;
  static const double topTop = 0.19;
  static const double topWidth = 0.55;
  static const double topHeight = 0.42;
  static const double topRotationDeg = 0.0;

  // 상의 (아우터 있을 때 — 아우터 오른쪽 뒤로 살짝 걸치게)
  static const double topWithOuterLeft = 0.36;
  static const double topWithOuterTop = 0.19;
  static const double topWithOuterWidth = 0.46;

  // 아우터 (상의 왼쪽, 상의보다 앞에 그려짐)
  static const double outerLeft = 0.04;
  static const double outerTop = 0.03;
  static const double outerWidth = 0.50;
  static const double outerHeight = 0.38;

  // 하의 — 상의 밑단과 15~20%가량 겹치도록 top을 당겨서 배치.
  // 겹침이 실제로 보이려면 상의는 박스 하단에, 하의는 박스 상단에
  // 붙여 그려야 한다(각 슬롯의 alignment 참고).
  static const double bottomLeft = 0.205;
  static const double bottomTop = 0.48;
  static const double bottomWidth = 0.52;
  static const double bottomHeight = 0.42;
  static const double bottomRotationDeg = 0.0;

  // 신발 — 하의 밑단과 살짝 겹치도록 오른쪽 아래에 배치.
  static const double shoesLeft = 0.51;
  static const double shoesTop = 0.76;
  static const double shoesWidth = 0.44;
  static const double shoesHeight = 0.24;
  static const double shoesRotationDeg = 0.0;

  // 액세서리 — 모자(상의 바로 위, 중앙) / 가방(오른쪽에 세로로 길게,
  // 상의 중간~하의 중간 높이) / 시계(왼쪽 상의 팔 높이) / 팔찌(시계 위쪽)
  static const double hatLeft = 0.335;
  static const double hatTop = 0.01;
  static const double hatWidth = 0.26;
  static const double hatHeight = 0.17;
  static const double hatRotationDeg = 0.0;

  static const double bagLeft = 0.58;
  static const double bagTop = 0.30;
  static const double bagWidth = 0.38;
  static const double bagHeight = 0.40;
  static const double bagRotationDeg = 0.0;

  static const double watchLeft = 0.11;
  static const double watchTop = 0.44;
  static const double watchWidth = 0.195;
  static const double watchHeight = 0.117;
  static const double watchRotationDeg = 0.0;

  static const double braceletLeft = 0.10;
  static const double braceletTop = 0.34;
  static const double braceletWidth = 0.13;
  static const double braceletHeight = 0.07;
  static const double braceletRotationDeg = 0.0;
}

// 슬롯의 사용자 편집 상태 — 보드 크기 대비 비율(0~1)인 left/top과,
// 기본 width/height에 곱해지는 scale(0.5~2.0)만 갖는다. rotationDeg는
// 슬롯마다 고정값(_BoardLayout)을 그대로 쓰고 편집 대상이 아니다.
class SlotTransform {
  final double left;
  final double top;
  final double scale;

  const SlotTransform({required this.left, required this.top, this.scale = 1.0});
}

// 코디보드 모양의 플랫레이 옷 선택 위젯. 탭하면 슬롯별 옷장 아이템 선택
// 시트가 뜨고, 편집 모드에서는 드래그로 이동·두 손가락으로 크기 조절이
// 가능하다. AI 피팅룸의 "코디 선택" 단계에 임베드해서 쓴다.
class OutfitBoard extends StatefulWidget {
  final Map<String, WardrobeItem?> slots;
  final void Function(String slotKey, WardrobeItem item) onSetItem;
  final ValueChanged<String>? onClearItem;

  const OutfitBoard({
    super.key,
    required this.slots,
    required this.onSetItem,
    this.onClearItem,
  });

  @override
  State<OutfitBoard> createState() => _OutfitBoardState();
}

class _OutfitBoardState extends State<OutfitBoard> {
  // slotKey가 이 맵에 없으면 _buildSlot에 전달된 기본 left/top/scale(1.0)을
  // 그대로 쓴다. 드래그/핀치로 편집한 슬롯만 여기 들어간다.
  final Map<String, SlotTransform> _transforms = {};

  // 핀치 제스처 도중 누적 scale(details.scale)의 기준점 — onScaleStart에서
  // 그 시점의 scale을 저장해두고, onScaleUpdate에서 곱해서 절대 scale을 구한다.
  final Map<String, double> _gestureStartScale = {};

  bool _editMode = false;

  // 마지막으로 이력에 기록한 조합의 서명(정렬된 옷 id 조합) — 편집 완료를
  // 여러 번 눌러도 같은 조합이면 중복 기록하지 않기 위한 용도.
  String? _lastLoggedBoardSignature;

  void _handleSlotGestureStart(String slotKey) {
    _gestureStartScale[slotKey] = (_transforms[slotKey] ?? const SlotTransform(left: 0, top: 0)).scale;
  }

  void _handleSlotGestureUpdate({
    required String slotKey,
    required ScaleUpdateDetails details,
    required double defaultLeft,
    required double defaultTop,
    required double defaultWidth,
    required double defaultHeight,
    required double boardWidth,
    required double boardHeight,
  }) {
    final current = _transforms[slotKey] ?? SlotTransform(left: defaultLeft, top: defaultTop);
    final baseScale = _gestureStartScale[slotKey] ?? current.scale;
    setState(() {
      final newScale = (baseScale * details.scale).clamp(0.5, 2.0);
      final widthFrac = defaultWidth * newScale;
      final heightFrac = defaultHeight * newScale;
      final maxLeft = (1.0 - widthFrac).clamp(0.0, 1.0);
      final maxTop = (1.0 - heightFrac).clamp(0.0, 1.0);
      final newLeft =
          (current.left + details.focalPointDelta.dx / boardWidth).clamp(0.0, maxLeft);
      final newTop =
          (current.top + details.focalPointDelta.dy / boardHeight).clamp(0.0, maxTop);
      _transforms[slotKey] = SlotTransform(left: newLeft, top: newTop, scale: newScale);
    });
  }

  void _handleSlotGestureEnd(String slotKey) {
    _gestureStartScale.remove(slotKey);
  }

  // 편집 모드를 끄는 순간(= "완료" 탭)을 "이 조합이 마음에 들어 저장했다"는
  // 의도로 간주해 이력에 남긴다. 켤 때나 드래그/핀치 도중에는 기록하지 않는다.
  void _toggleEditMode() {
    final wasEditing = _editMode;
    setState(() => _editMode = !_editMode);
    if (wasEditing && !_editMode) {
      _logBoardHistorySilently();
    }
  }

  void _logBoardHistorySilently() {
    final items = widget.slots.values.whereType<WardrobeItem>().toList();
    if (items.length < 2) return;

    final signature = (items.map((i) => i.id).toList()..sort()).join(',');
    if (signature == _lastLoggedBoardSignature) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _lastLoggedBoardSignature = signature;
    unawaited(FirestoreService.addHistoryEntrySilently(
      uid,
      OutfitHistoryEntry(
        type: OutfitHistoryEntry.typeBoard,
        items: items.map(HistoryItemSnapshot.fromWardrobeItem).toList(),
      ),
    ));
  }

  void _pickForSlot(String slotKey) {
    final slot = outfitBoardSlots.firstWhere((s) => s.key == slotKey);
    showModalBottomSheet<_PickResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BoardItemPickerSheet(
        category: slot.category,
        subCategory: slot.subCategory,
        slotLabel: slot.label,
        canClear: widget.slots[slotKey] != null,
      ),
    ).then((result) {
      if (result == null || !mounted) return;
      if (result.clear) {
        widget.onClearItem?.call(slotKey);
      } else if (result.item != null) {
        widget.onSetItem(slotKey, result.item!);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _editMode ? '드래그로 이동 · 두 손가락으로 크기 조절' : '슬롯을 탭해 옷장에서 바로 선택하세요',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
            TextButton.icon(
              onPressed: _toggleEditMode,
              style: TextButton.styleFrom(
                foregroundColor: _editMode ? AppColors.blue : AppColors.textMuted,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: Icon(_editMode ? Icons.check : Icons.edit_outlined, size: 16),
              label: Text(_editMode ? '완료' : '편집',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildBoard(),
      ],
    );
  }

  // ── 보드 본체: Stack + Positioned로 플랫레이 배치 ─────────
  Widget _buildBoard() {
    final hasOuter = widget.slots['아우터'] != null;

    return AspectRatio(
      aspectRatio: _BoardLayout.aspectRatio,
      child: Container(
        decoration: BoxDecoration(
          color: _BoardLayout.backgroundColor,
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            return Stack(
              children: [
                // z-order (뒤→앞): 하의 → 상의 → 아우터 → 모자 → 가방 → 시계 → 팔찌 → 신발
                // 하의 — 박스 상단에 붙여 그려서 상의 밑단과 실제로 겹쳐 보이게 한다.
                _buildSlot(
                  slotKey: '하의',
                  defaultLeft: _BoardLayout.bottomLeft,
                  defaultTop: _BoardLayout.bottomTop,
                  defaultWidth: _BoardLayout.bottomWidth,
                  defaultHeight: _BoardLayout.bottomHeight,
                  boardWidth: w,
                  boardHeight: h,
                  alignment: Alignment.topCenter,
                  rotationDeg: _BoardLayout.bottomRotationDeg,
                ),
                // 상의 — 아우터가 있으면 오른쪽으로 밀려 아우터 뒤에 걸친다.
                // 박스 하단에 붙여 그려서 하의와 겹치는 부분이 실제로 보이게 한다.
                _buildSlot(
                  slotKey: '상의',
                  defaultLeft: hasOuter ? _BoardLayout.topWithOuterLeft : _BoardLayout.topLeft,
                  defaultTop: hasOuter ? _BoardLayout.topWithOuterTop : _BoardLayout.topTop,
                  defaultWidth: hasOuter ? _BoardLayout.topWithOuterWidth : _BoardLayout.topWidth,
                  defaultHeight: _BoardLayout.topHeight,
                  boardWidth: w,
                  boardHeight: h,
                  alignment: Alignment.bottomCenter,
                  rotationDeg: _BoardLayout.topRotationDeg,
                ),
                // 아우터 — 상의보다 나중에 그려서 앞으로 나오게 한다.
                if (hasOuter)
                  _buildSlot(
                    slotKey: '아우터',
                    defaultLeft: _BoardLayout.outerLeft,
                    defaultTop: _BoardLayout.outerTop,
                    defaultWidth: _BoardLayout.outerWidth,
                    defaultHeight: _BoardLayout.outerHeight,
                    boardWidth: w,
                    boardHeight: h,
                  ),
                // 모자
                _buildSlot(
                  slotKey: '모자',
                  defaultLeft: _BoardLayout.hatLeft,
                  defaultTop: _BoardLayout.hatTop,
                  defaultWidth: _BoardLayout.hatWidth,
                  defaultHeight: _BoardLayout.hatHeight,
                  boardWidth: w,
                  boardHeight: h,
                  rotationDeg: _BoardLayout.hatRotationDeg,
                ),
                // 가방 — 오른쪽 중단을 크게 채움
                _buildSlot(
                  slotKey: '가방',
                  defaultLeft: _BoardLayout.bagLeft,
                  defaultTop: _BoardLayout.bagTop,
                  defaultWidth: _BoardLayout.bagWidth,
                  defaultHeight: _BoardLayout.bagHeight,
                  boardWidth: w,
                  boardHeight: h,
                  rotationDeg: _BoardLayout.bagRotationDeg,
                ),
                // 시계
                _buildSlot(
                  slotKey: '시계',
                  defaultLeft: _BoardLayout.watchLeft,
                  defaultTop: _BoardLayout.watchTop,
                  defaultWidth: _BoardLayout.watchWidth,
                  defaultHeight: _BoardLayout.watchHeight,
                  boardWidth: w,
                  boardHeight: h,
                  rotationDeg: _BoardLayout.watchRotationDeg,
                ),
                // 팔찌 — 시계 바로 위
                _buildSlot(
                  slotKey: '팔찌',
                  defaultLeft: _BoardLayout.braceletLeft,
                  defaultTop: _BoardLayout.braceletTop,
                  defaultWidth: _BoardLayout.braceletWidth,
                  defaultHeight: _BoardLayout.braceletHeight,
                  boardWidth: w,
                  boardHeight: h,
                  rotationDeg: _BoardLayout.braceletRotationDeg,
                ),
                // 신발 — 하의 밑단과 겹치게, 맨 앞
                _buildSlot(
                  slotKey: '신발',
                  defaultLeft: _BoardLayout.shoesLeft,
                  defaultTop: _BoardLayout.shoesTop,
                  defaultWidth: _BoardLayout.shoesWidth,
                  defaultHeight: _BoardLayout.shoesHeight,
                  boardWidth: w,
                  boardHeight: h,
                  rotationDeg: _BoardLayout.shoesRotationDeg,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSlot({
    required String slotKey,
    required double defaultLeft,
    required double defaultTop,
    required double defaultWidth,
    required double defaultHeight,
    required double boardWidth,
    required double boardHeight,
    double rotationDeg = 0,
    Alignment alignment = Alignment.center,
  }) {
    final transform = _transforms[slotKey] ?? SlotTransform(left: defaultLeft, top: defaultTop);
    final width = boardWidth * defaultWidth * transform.scale;
    final height = boardHeight * defaultHeight * transform.scale;

    final item = widget.slots[slotKey];
    Widget content = SizedBox(
      width: width,
      height: height,
      child: item != null
          ? CachedNetworkImage(
              imageUrl: item.cutoutImageUrl ?? item.imageUrl,
              fit: BoxFit.contain,
              alignment: alignment,
              placeholder: (_, __) => const SizedBox.shrink(),
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.image_outlined, color: Colors.white24, size: 28),
            )
          : _EmptySlotPlaceholder(label: slotKey),
    );

    if (rotationDeg != 0) {
      content = Transform.rotate(angle: rotationDeg * math.pi / 180, child: content);
    }

    return Positioned(
      left: boardWidth * transform.left,
      top: boardHeight * transform.top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _editMode ? null : () => _pickForSlot(slotKey),
        onScaleStart: _editMode ? (_) => _handleSlotGestureStart(slotKey) : null,
        onScaleUpdate: _editMode
            ? (details) => _handleSlotGestureUpdate(
                  slotKey: slotKey,
                  details: details,
                  defaultLeft: defaultLeft,
                  defaultTop: defaultTop,
                  defaultWidth: defaultWidth,
                  defaultHeight: defaultHeight,
                  boardWidth: boardWidth,
                  boardHeight: boardHeight,
                )
            : null,
        onScaleEnd: _editMode ? (_) => _handleSlotGestureEnd(slotKey) : null,
        child: content,
      ),
    );
  }
}

// ── 빈 슬롯 표시: 점선 테두리 + 안내 텍스트 ──────────────
class _EmptySlotPlaceholder extends StatelessWidget {
  final String label;

  const _EmptySlotPlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(),
      child: Center(
        // 시계처럼 매우 작은 슬롯에서도 두 줄 안내 문구가 넘치지 않도록
        // 박스 크기에 맞춰 통째로 축소한다.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              const Text('탭해서\n선택',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white24, fontSize: 10, height: 1.3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  static const _dashWidth = 6.0;
  static const _dashSpace = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final next = distance + _dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + _dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => false;
}

// ── 슬롯 탭 시 뜨는 가로 스크롤 아이템 선택 바텀시트 ─────
// 슬롯 선택 시트의 결과 — 아이템을 골랐는지, "비우기"를 눌렀는지, 그냥
// 닫았는지(둘 다 null)를 구분한다. WardrobeItem?만으로는 "비우기"와
// "그냥 닫음"을 구분할 수 없어서 별도로 감싼다.
class _PickResult {
  final WardrobeItem? item;
  final bool clear;

  const _PickResult.selected(WardrobeItem this.item) : clear = false;
  const _PickResult.cleared()
      : item = null,
        clear = true;
}

class _BoardItemPickerSheet extends StatelessWidget {
  final String category;
  final String? subCategory;
  final String slotLabel;
  final bool canClear;

  const _BoardItemPickerSheet({
    required this.category,
    required this.subCategory,
    required this.slotLabel,
    required this.canClear,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 0, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('$slotLabel 선택',
                                style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4)),
                            const SizedBox(height: 4),
                            Text('등록된 $category 아이템 중에서 골라보세요',
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                          ],
                        ),
                      ),
                      if (canClear)
                        GestureDetector(
                          onTap: () => Navigator.pop(context, const _PickResult.cleared()),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.red.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.red.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.remove_circle_outline,
                                    size: 15, color: AppColors.red),
                                const SizedBox(width: 4),
                                const Text('이 슬롯 비우기',
                                    style: TextStyle(
                                        color: AppColors.red,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 150,
              child: StreamBuilder<List<WardrobeItem>>(
                // uid를 못 구하면(인증 미복원) 빈 문자열/임의 값으로 조회하지
                // 않고 스트림 자체를 만들지 않는다 — "옷장이 비었다"는 잘못된
                // 화면을 막기 위함.
                stream: uid != null
                    ? FirestoreService.wardrobeStream(uid)
                    : const Stream<List<WardrobeItem>>.empty(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator(color: AppColors.navy, strokeWidth: 2));
                  }
                  // subCategory가 지정된 슬롯(모자/가방/시계/팔찌)이면 해당 타입과
                  // 정확히 일치하거나, 아직 세부 분류가 없는(null) 레거시
                  // 아이템까지 폴백으로 포함한다 — 등록 당시 미분류였다고
                  // 특정 슬롯에서 영영 안 보이면 안 되니까.
                  final items = (snapshot.data ?? [])
                      .where((i) =>
                          i.category == category &&
                          (subCategory == null ||
                              i.subCategory == subCategory ||
                              i.subCategory == null))
                      .toList();
                  if (items.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 20),
                        child: Text('등록된 $category 아이템이 없습니다',
                            style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                      ),
                    );
                  }
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 20),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      return GestureDetector(
                        onTap: () => Navigator.pop(context, _PickResult.selected(item)),
                        child: Container(
                          width: 110,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(9),
                            child: CachedNetworkImage(
                              imageUrl: item.cutoutImageUrl ?? item.imageUrl,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(color: AppColors.background),
                              errorWidget: (_, __, ___) => Container(
                                color: AppColors.background,
                                child: const Icon(Icons.image_outlined,
                                    color: AppColors.textDisabled),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
