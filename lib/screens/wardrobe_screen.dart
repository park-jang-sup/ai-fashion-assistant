import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_background_remover/image_background_remover.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../constants/app_colors.dart';
import '../data/wardrobe_data.dart' show categories;
import '../models/agent_task.dart';
import '../models/clothing_attributes.dart';
import '../models/clothing_size.dart';
import '../models/user_profile.dart';
import '../models/wardrobe_item.dart';
import '../services/agent_planner.dart';
import '../services/embedding_service.dart';
import '../services/fit_predictor.dart';
import '../services/firestore_service.dart';
import '../services/gemini_service.dart';
import '../services/storage_service.dart';

const _uploadCategories = ['상의', '하의', '아우터', '신발', '액세서리', '전신'];

// 체형과 대조 가능한 치수 개념(가슴단면·허리단면 등)이 있는 카테고리만
// 치수 입력/수정을 노출한다. 신발·액세서리·전신에는 해당 개념이 없다.
const _sizeInputCategories = {'상의', '하의', '아우터'};

// 위젯과 무관하게 실행되는 백그라운드 작업 — 업로드 화면을 벗어나도
// 계속 진행되고, 실패한 지점은 조용히 삼키는 대신 재시도 태스크로 남긴다
// (AgentSweeper가 다음 앱 실행 때 발견해 재개한다). 파이프라인 자체(속성
// 추출 재시도 정책, 매칭→자기평가→저장)는 agent_planner.dart에 있다 —
// AgentSweeper도 같은 로직을 재사용해야 하기 때문.
Future<void> _extractAndCacheAttributes(
  String itemId,
  String imageUrl,
  String category,
) async {
  debugPrint('[RECOMMEND] 속성 추출 시작: id=$itemId, category=$category');
  final uid = FirebaseAuth.instance.currentUser?.uid;
  ClothingAttributes attributes;
  try {
    attributes = await AgentPlanner.extractAttributesWithRetry(imageUrl, category);
    debugPrint('[RECOMMEND] 속성 추출 완료: color=${attributes.color}, style=${attributes.style}');
  } catch (e) {
    // 업로드 자체는 이미 끝난 뒤라 실패를 사용자에게 노출하지 않는다.
    // 분석 시점 폴백(FittingJobController._resolveAttributes)이 나중에 채운다.
    debugPrint('[속성추출] 실패: $e');
    if (uid != null) {
      unawaited(FirestoreService.enqueueAgentTaskSilently(
        uid,
        AgentTask.create(
          type: AgentTask.typeExtractAttributes,
          payload: {'itemId': itemId},
          lastError: '$e',
        ),
      ));
    }
    return;
  }
  await FirestoreService.updateWardrobeAttributes(itemId, attributes);
  // "능동 추천"은 속성이 준비된 직후에만 의미가 있고, 실패해도 옷 등록
  // 자체를 막으면 안 되므로 별도의 조용한 백그라운드 작업으로 흘려보낸다.
  if (uid == null) return;
  final ok = await AgentPlanner.generateRecommendationForNewItem(
    uid,
    WardrobeItem(
      id: itemId,
      imageUrl: imageUrl,
      category: category,
      createdAt: DateTime.now(),
      attributes: attributes,
    ),
  );
  if (!ok) {
    unawaited(FirestoreService.enqueueAgentTaskSilently(
      uid,
      AgentTask.create(
        type: AgentTask.typeGenerateRecommendation,
        payload: {'itemId': itemId},
        lastError: '추천 파이프라인 실패(자기 평가 루프가 Gemini 폴백까지 모두 실패했거나 저장 실패)',
      ),
    ));
  }
}

// 사이즈표 OCR도 동일한 정책 적용. 그래도 실패하면 그대로 던져서 호출부가
// 손 입력 폴백으로 안내하게 한다.
Future<ClothingSize> _scanSizeChartWithRetry({
  required Uint8List imageBytes,
  required String category,
  required String sizeLabel,
}) {
  return GeminiService.withTextModelFallback(
    (model) => GeminiService.extractSizeFromChart(
      imageBytes: imageBytes,
      category: category,
      sizeLabel: sizeLabel,
      model: model,
    ),
  );
}

class WardrobeScreen extends StatefulWidget {
  final ValueChanged<WardrobeItem>? onSelectItem;

  const WardrobeScreen({super.key, this.onSelectItem});

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen> {
  String _activeCategory = '전체';
  bool _isUploading = false;
  String _busyTitle = '사진을 업로드 중입니다...';
  String _busySubtitle = '잠시만 기다려 주세요';

  // 카드 뱃지용 핏 예측에 쓰인다 — Gemini 호출 없이 로컬 계산만 하므로
  // 화면 진입 시 한 번만 불러오면 충분하다.
  UserProfile? _userProfile;

  // 온디바이스 배경 제거(ONNX) 준비 여부. 초기화 자체가 실패하면 이번
  // 세션에서는 배경 제거 단계를 건너뛰고 원본만 쓰는 흐름으로 조용히
  // 폴백한다 — 등록 자체를 막지 않는다.
  bool _isBgRemoverReady = false;

  // BackgroundRemover.instance는 앱 전역 싱글톤인데, 이 화면은 하단 탭을
  // 전환할 때마다(IndexedStack 없이 switch로 새로 생성/폐기됨) State가
  // 통째로 다시 만들어진다. 예전에는 initState에서 initializeOrt(),
  // dispose에서 dispose()를 매번 호출했는데, 탭을 나갔다 들어오면 이전
  // 화면의 비동기 dispose(세션 close)와 새 화면의 initializeOrt(세션
  // 재생성)가 같은 싱글톤 위에서 경합해 네이티브 ONNX 세션이 깨지고
  // JNI GetMethodID가 널 클래스 참조를 만나 SIGABRT로 죽는 크래시가
  // 있었다. static Future로 앱 수명 동안 초기화를 한 번만 수행하고,
  // 화면을 나가도 절대 dispose하지 않는 것으로 레이스 자체를 없앤다.
  static Future<void>? _bgRemoverInitFuture;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _initBackgroundRemover();
  }

  @override
  void dispose() {
    // BackgroundRemover.instance는 앱 전역 싱글톤이므로 여기서 dispose하지
    // 않는다 — 위 _bgRemoverInitFuture 주석 참고.
    super.dispose();
  }

  Future<void> _loadUserProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final profile = await FirestoreService.getUserProfileSilently(uid);
    if (mounted) setState(() => _userProfile = profile);
  }

  Future<void> _initBackgroundRemover() async {
    // release 빌드에서만 재현되는 네이티브 크래시로 배경 제거를 완전히
    // 건너뛴다. 2026-07-19 실기기(Galaxy S23 Ultra, SM_S918N) release APK로
    // 재현해서 logcat을 직접 확인한 결과:
    //   JNI DETECTED ERROR IN APPLICATION: java_class == null
    //       in call to GetMethodID
    //       from boolean[] ai.onnxruntime.OrtSession.run(...)
    // 네이티브 스택은 Java_ai_onnxruntime_OrtSession_run →
    // convertOrtValueToONNXValue → convertToTensorInfo → GetMethodID(널
    // 클래스) → SIGABRT 순서였고, 그 앞에 OrtException이나 OOM, 다른 잡을 수
    // 있는 Java 예외 로그가 전혀 없었다 — 즉 session.run() 내부의 ORT 자체
    // JNI 변환 코드(convertToTensorInfo)가 이전 JNI 호출 실패(pending
    // exception)를 확인하지 않고 그대로 다음 JNI API를 호출하다 죽는
    // 구조로, microsoft/onnxruntime#12679에 보고된 패턴과 일치한다.
    // R8/ProGuard(minifyEnabled 꺼짐), NNAPI(항상 CPU EP만 사용), 입력 텐서
    // shape(항상 고정 320x320), 동시 호출 경합(크래시 시점에 다른
    // flutter-worker 스레드는 전부 대기 중, session.run()은 단일 스레드에서만
    // 실행 중이었음)은 전부 원인에서 배제됐다. onnxruntime-android(1.23.0)
    // 네이티브 JNI 유틸 내부 버그로 확정 — 우리 쪽 코드/설정으로는 고칠 수
    // 없으므로 release에서는 아예 초기화하지 않고 원본 이미지로 등록한다.
    if (kReleaseMode) return;

    try {
      // 이미 다른 마운트에서 초기화를 시작/완료했으면 그 Future를 그대로
      // 재사용한다 — initializeOrt()를 중복 호출해 세션을 다시 만들지
      // 않는다(위 _bgRemoverInitFuture 주석 참고).
      _bgRemoverInitFuture ??= BackgroundRemover.instance.initializeOrt();
      await _bgRemoverInitFuture;
      if (mounted) setState(() => _isBgRemoverReady = true);
    } catch (e) {
      // 초기화 실패 — 이번 세션은 배경 제거 없이 원본만 사용. 다음 마운트에서
      // 재시도할 수 있도록 캐시된 실패 Future는 지운다.
      _bgRemoverInitFuture = null;
      debugPrint('[배경제거초기화] 실패: $e');
    }
  }

  List<WardrobeItem> _filter(List<WardrobeItem> all) {
    if (_activeCategory == '전체') return all;
    return all.where((item) => item.category == _activeCategory).toList();
  }

  // ── 카드 탭: 피팅룸 전송 · 치수 입력/수정 · 비슷한 옷 액션 시트 ─────
  // wardrobe는 옷장 전체 리스트(스트림에서 이미 로드된 것을 그대로 재사용,
  // 시트를 열 때마다 Firestore를 다시 조회하지 않는다) — "비슷한 옷" 섹션이
  // 현재 카테고리 필터와 무관하게 항상 전체 옷장에서 같은 카테고리를 찾도록
  // _filter()가 적용되지 않은 목록을 받는다.
  void _showCardOptions(BuildContext context, WardrobeItem item, List<WardrobeItem> wardrobe) {
    // 코사인 계산은 100여 벌×512차원이라 클라이언트에서 즉시 끝나므로 로딩
    // 인디케이터 없이 시트 빌드 전에 동기로 계산한다. embedding이 없거나
    // 같은 카테고리 비교 대상이 없으면(둘 다 findSimilarItems가 빈 리스트로
    // 알려줌) 섹션 자체를 렌더링하지 않는다 — 에러 문구/빈 박스 금지.
    final similarItems = EmbeddingService.findSimilarItems(item: item, wardrobe: wardrobe, topN: 3);
    final wardrobeById = {for (final w in wardrobe) w.id: w};

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              const SizedBox(height: 20),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.navy.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.category,
                      style: const TextStyle(
                        color: AppColors.navy,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '아이템 선택됨',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (widget.onSelectItem != null) ...[
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onSelectItem!(item);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.navy,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.checkroom, color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text(
                          '피팅룸에서 입어보기',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (_sizeInputCategories.contains(item.category))
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    _editSize(item);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.straighten, color: AppColors.navy, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          item.size != null ? '치수 수정' : '치수 입력',
                          style: const TextStyle(
                            color: AppColors.navy,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (similarItems.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text(
                  '옷장에 비슷한 옷이 있어요',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final s in similarItems)
                        if (wardrobeById[s.itemId] != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: GestureDetector(
                              onTap: () {
                                Navigator.pop(context);
                                _showCardOptions(context, wardrobeById[s.itemId]!, wardrobe);
                              },
                              child: _SimilarItemThumbnail(item: wardrobeById[s.itemId]!),
                            ),
                          ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── 등록된 옷의 치수를 나중에 입력하거나 수정 ────────────
  Future<void> _editSize(WardrobeItem item) async {
    final size = await showModalBottomSheet<ClothingSize>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SizeInputSheet(
        category: item.category,
        initialSize: item.size,
        isEditingExisting: true,
      ),
    );
    if (size == null || !mounted) return;

    try {
      await FirestoreService.updateWardrobeSize(item.id, size);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('치수를 저장했습니다.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('저장 실패: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  // ── 아이템 삭제 확인 ─────────────────────────────────────
  Future<void> _confirmDelete(WardrobeItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '아이템 삭제',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          '이 아이템을 삭제하시겠습니까?\n삭제 후 복구할 수 없습니다.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소',
                style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제',
                style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await StorageService.deleteWardrobeImage(item.imageUrl);
      if (item.cutoutImageUrl != null) {
        await StorageService.deleteWardrobeImage(item.cutoutImageUrl!);
      }
      await FirestoreService.deleteWardrobeItem(item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('아이템이 삭제되었습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('삭제 실패: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }

  // ── FAB: 소스 선택 → 사진 선택 → 카테고리 선택 → 업로드 ──
  void _showAddBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _AddBottomSheet(
        onPickSource: (source) async {
          Navigator.pop(sheetCtx); // 소스 선택 시트 닫기
          await _pickAndUpload(source);
        },
      ),
    );
  }

  // 크롭 화면에서 취소하면 null을 반환 — 호출부가 원본을 그대로 쓰게 한다.
  // 처리 자체가 실패해도(예외) 같은 방식으로 원본 폴백.
  Future<String?> _cropImage(String sourcePath) async {
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: sourcePath,
        compressQuality: 90,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '옷 영역만 잘라내기',
            toolbarColor: AppColors.navy,
            toolbarWidgetColor: Colors.white,
            backgroundColor: Colors.black,
            lockAspectRatio: false,
          ),
          IOSUiSettings(
            title: '옷 영역만 잘라내기',
            aspectRatioLockEnabled: false,
            resetAspectRatioEnabled: true,
          ),
        ],
      );
      return cropped?.path;
    } catch (e) {
      debugPrint('[이미지크롭] 실패: $e');
      return null;
    }
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    // 소유자 없이는 문서를 쓸 수 없다 — 업로드 흐름(사진 선택→크롭→카테고리
    // 선택→...)을 다 거치고 나서야 실패하면 사용자 입력이 낭비되므로 맨 앞에서
    // 확인한다.
    final ownerUid = _uid;
    if (ownerUid == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('로그인 상태를 확인할 수 없어 등록할 수 없습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    // 해상도를 미리 낮춰 두면 Storage 업로드는 물론, 이후 AI 분석/피팅 때마다
    // 반복되는 다운로드·base64 인코딩 페이로드도 함께 줄어든다.
    var xFile = await ImagePicker().pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 1440,
      maxHeight: 1440,
    );
    if (xFile == null || !mounted) return;

    // 크롭(선택) — 쇼핑몰 화면을 통캡처한 사진처럼 옷 외 영역(상태바·구매
    // 버튼 등)이 섞여 있으면 옷 부분만 잘라낼 수 있게 한다. 이미 깨끗한
    // 상품 사진이면 크롭 화면에서 취소해 건너뛰고 원본 그대로 진행하면 된다.
    final croppedPath = await _cropImage(xFile.path);
    if (!mounted) return;
    if (croppedPath != null) {
      xFile = XFile(croppedPath);
    }

    // 카테고리 선택
    final category = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CategoryPickerSheet(),
    );
    if (category == null || !mounted) return;

    // 액세서리 세부 타입(선택) — 코디 보드의 모자/가방/시계 슬롯을
    // 구분해서 채우려면 필요하다. 건너뛰면 세 슬롯 모두에 폴백으로 노출된다.
    String? subCategory;
    if (category == '액세서리') {
      subCategory = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const _AccessorySubCategoryPickerSheet(),
      );
      if (!mounted) return;
    }

    // 배경 제거(선택) — 전신 사진은 드래그 조합용 옷이 아니므로 건너뛴다.
    // 준비가 안 됐거나(초기화 실패) 처리 자체가 실패하면 조용히 원본만 쓴다.
    Uint8List? cutoutBytes;
    if (category != '전신' && _isBgRemoverReady) {
      final originalBytes = await xFile.readAsBytes();
      if (!mounted) return;
      cutoutBytes = await _removeBackgroundWithPreview(originalBytes);
      if (!mounted) return;
    }

    // 치수 입력(선택) — 신발/액세서리/전신은 핏 예측 대상이 아니므로 건너뛴다.
    ClothingSize? size;
    if (_sizeInputCategories.contains(category)) {
      size = await showModalBottomSheet<ClothingSize>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _SizeInputSheet(category: category),
      );
      if (!mounted) return;
    }

    setState(() {
      _busyTitle = '사진을 업로드 중입니다...';
      _busySubtitle = '잠시만 기다려 주세요';
      _isUploading = true;
    });
    try {
      final imageUrl = await StorageService.uploadWardrobeImage(xFile);
      String? cutoutImageUrl;
      if (cutoutBytes != null) {
        cutoutImageUrl = await StorageService.uploadWardrobeCutout(cutoutBytes);
      }
      final itemId = await FirestoreService.addWardrobeItem(
        imageUrl: imageUrl,
        cutoutImageUrl: cutoutImageUrl,
        category: category,
        subCategory: subCategory,
        size: size,
        ownerUid: ownerUid,
      );
      // 속성 추출은 업로드 완료를 기다리게 하지 않고 백그라운드로 흘려보낸다.
      // (배경 제거본이 아니라 항상 원본으로 분석 — 배경 제거 결과가 나빠도
      // 속성 추출 정확도에 영향이 없게 한다.)
      unawaited(_extractAndCacheAttributes(itemId, imageUrl, category));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$category 아이템이 등록되었습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('업로드 실패: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // 배경 제거 실행 + 결과 미리보기. 처리 자체가 실패하면 null(원본 폴백).
  // 처리에 성공하면 사용자가 미리보기에서 "원본 사용"/"배경 제거본 사용"을
  // 직접 고르게 한다 — 저대비 사진 등에서 마스크가 깨질 수 있어 자동
  // 품질 판별 대신 사람이 눈으로 보고 고르는 쪽을 택했다.
  Future<Uint8List?> _removeBackgroundWithPreview(Uint8List originalBytes) async {
    setState(() {
      _busyTitle = 'AI가 배경을 제거하는 중입니다...';
      _busySubtitle = '옷 사진을 분석하고 있어요';
      _isUploading = true;
    });

    Uint8List? cutoutBytes;
    try {
      final resultImage = await BackgroundRemover.instance.removeBg(originalBytes);
      final byteData = await resultImage.toByteData(format: ui.ImageByteFormat.png);
      resultImage.dispose();
      cutoutBytes = byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[배경제거] 실패: $e');
      cutoutBytes = null;
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }

    if (cutoutBytes == null || !mounted) return null;

    final useCutout = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CutoutPreviewSheet(
        originalBytes: originalBytes,
        cutoutBytes: cutoutBytes!,
      ),
    );
    return useCutout == true ? cutoutBytes : null;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        StreamBuilder<List<WardrobeItem>>(
          // uid를 못 구하면 스트림을 만들지 않는다(빈 문자열/임의 값 조회로
          // "옷장이 비었다"는 잘못된 화면을 막기 위함).
          stream: _uid != null
              ? FirestoreService.wardrobeStream(_uid!)
              : const Stream<List<WardrobeItem>>.empty(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _LoadingView();
            }
            if (snapshot.hasError) {
              return _ErrorView(message: snapshot.error.toString());
            }

            final allItems = snapshot.data ?? [];
            final items = _filter(allItems);

            return Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(allItems.length),
                    Expanded(
                      child: items.isEmpty
                          ? _buildEmptyState()
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 14,
                                childAspectRatio: 0.72,
                              ),
                              itemCount: items.length,
                              itemBuilder: (ctx, i) => GestureDetector(
                                onTap: () => _showCardOptions(ctx, items[i], allItems),
                                child: _WardrobeCard(
                                  item: items[i],
                                  userProfile: _userProfile,
                                  onDelete: () => _confirmDelete(items[i]),
                                ),
                              ),
                            ),
                    ),
                    _buildCategoryBar(),
                  ],
                ),
                _buildFab(),
              ],
            );
          },
        ),
        if (_isUploading) _buildUploadOverlay(),
      ],
    );
  }

  Widget _buildHeader(int totalCount) {
    return Container(
      width: double.infinity,
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '내 옷장',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '총 $totalCount벌의 아이템',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 카테고리 필터 바: 화면 하단에 고정된 가로 스크롤 칩 목록 ──
  Widget _buildCategoryBar() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: categories.map((cat) {
              final isActive = _activeCategory == cat;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _activeCategory = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isActive ? Colors.black : AppColors.background,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      cat,
                      style: TextStyle(
                        color: isActive ? Colors.white : AppColors.textMuted,
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // F'.1.4 — 데모 옷장(demo_wardrobe) 118벌을 현재 계정으로 복사한다.
  // items.isEmpty일 때만 렌더링되는 _buildEmptyState() 안에만 두어(700~701행),
  // 시드 후 이 자리가 그리드로 교체되며 버튼이 자연히 사라진다 — 별도의
  // 중복 시드 경로를 만들지 않는다. _isUploading으로 잠가 연타를 막는다
  // (기존 업로드 오버레이를 재사용 — F'.1.4의 "로딩 상태 필수" 요구).
  Future<void> _seedDemoWardrobe() async {
    final uid = _uid;
    if (uid == null) return;
    setState(() {
      _busyTitle = '데모 옷장을 불러오는 중입니다...';
      _busySubtitle = '118벌을 준비하고 있어요, 잠시만 기다려 주세요';
      _isUploading = true;
    });
    try {
      final count = await FirestoreService.seedDemoWardrobe(uid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데모 옷장 $count벌을 불러왔습니다.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      // 이 경로는 폴백이 "아무것도 하지 않음"이면 안 된다(F'.1.4) — 실패를
      // 조용히 삼키지 않고 재시도 가능한 안내를 낸다.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데모 옷장을 불러오지 못했습니다: $e — 다시 시도해 주세요'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.checkroom_outlined,
                color: AppColors.textDisabled, size: 26),
          ),
          const SizedBox(height: 20),
          const Text(
            '아직 등록된 옷이 없습니다',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '새 옷을 등록해 보세요!',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _isUploading ? null : _seedDemoWardrobe,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Text(
                '데모 옷장 불러오기',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '내 옷을 등록하기 전에 기능을 먼저 확인할 수 있어요',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildFab() {
    return Positioned(
      bottom: 74,
      right: 20,
      child: GestureDetector(
        onTap: _showAddBottomSheet,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.black,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 26),
        ),
      ),
    );
  }

  Widget _buildUploadOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppColors.navy, strokeWidth: 2.5),
              const SizedBox(height: 20),
              Text(
                _busyTitle,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _busySubtitle,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 소스 선택 바텀시트 ──────────────────────────────────
// ── 배경 제거 결과 미리보기 (선택) ───────────────────────
class _CutoutPreviewSheet extends StatefulWidget {
  final Uint8List originalBytes;
  final Uint8List cutoutBytes;

  const _CutoutPreviewSheet({required this.originalBytes, required this.cutoutBytes});

  @override
  State<_CutoutPreviewSheet> createState() => _CutoutPreviewSheetState();
}

class _CutoutPreviewSheetState extends State<_CutoutPreviewSheet> {
  bool _showCutout = true;

  Widget _buildToggleTab(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.navy : AppColors.background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 20),
            const Text(
              '배경 제거 결과 확인',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '결과가 이상하면 원본을 그대로 사용할 수 있어요',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildToggleTab(
                      '배경 제거본', _showCutout, () => setState(() => _showCutout = true)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildToggleTab(
                      '원본', !_showCutout, () => setState(() => _showCutout = false)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 320,
              width: double.infinity,
              decoration: BoxDecoration(
                color: _showCutout ? const Color(0xFF808080) : AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Image.memory(
                _showCutout ? widget.cutoutBytes : widget.originalBytes,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('원본 사용',
                        style: TextStyle(
                            color: AppColors.textMuted, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.navy,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        '배경 제거본 사용',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddBottomSheet extends StatelessWidget {
  final ValueChanged<ImageSource> onPickSource;

  const _AddBottomSheet({required this.onPickSource});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 20),
            const Text(
              '새 옷 등록',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '사진을 선택해 옷장에 추가하세요',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 24),
            _SourceButton(
              icon: Icons.camera_alt_outlined,
              label: '카메라로 촬영하기',
              sublabel: '지금 바로 사진을 찍어 등록',
              onTap: () => onPickSource(ImageSource.camera),
            ),
            const SizedBox(height: 12),
            _SourceButton(
              icon: Icons.photo_library_outlined,
              label: '갤러리에서 가져오기',
              sublabel: '저장된 사진을 선택해 등록',
              onTap: () => onPickSource(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 카테고리 선택 바텀시트 ──────────────────────────────
class _CategoryPickerSheet extends StatelessWidget {
  const _CategoryPickerSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 20),
            const Text(
              '카테고리 선택',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '이 옷의 카테고리를 선택해 주세요',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            ..._uploadCategories.map((cat) {
              final icons = {
                '상의': Icons.checkroom_outlined,
                '하의': Icons.straighten,
                '아우터': Icons.layers_outlined,
                '신발': Icons.hiking,
                '액세서리': Icons.watch_outlined,
                '전신': Icons.person_outline,
              };
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () => Navigator.pop(context, cat),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: AppColors.navy,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icons[cat]!, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          cat,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        const Icon(Icons.arrow_forward_ios,
                            color: AppColors.textDisabled, size: 14),
                      ],
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── 치수 입력 바텀시트 (선택) ─────────────────────────────
class _SizeInputSheet extends StatefulWidget {
  final String category;
  final ClothingSize? initialSize; // 이미 등록된 옷의 치수 수정 시 미리 채울 값
  final bool isEditingExisting; // true면 "치수 수정" 문구, false면 등록 흐름의 "치수 입력(선택)"

  const _SizeInputSheet({
    required this.category,
    this.initialSize,
    this.isEditingExisting = false,
  });

  @override
  State<_SizeInputSheet> createState() => _SizeInputSheetState();
}

class _SizeInputSheetState extends State<_SizeInputSheet> {
  static const _bottomFields = [
    (key: 'waistWidth', label: '허리단면'),
    (key: 'hipWidth', label: '엉덩이단면'),
    (key: 'thighWidth', label: '허벅지단면'),
    (key: 'pantsLength', label: '총장'),
  ];
  static const _topFields = [
    (key: 'totalLength', label: '총장'),
    (key: 'shoulderWidth', label: '어깨너비'),
    (key: 'chestWidth', label: '가슴단면'),
    (key: 'sleeveLength', label: '소매길이'),
  ];

  late final _fields = widget.category == '하의' ? _bottomFields : _topFields;
  final _controllers = <String, TextEditingController>{};
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _controllers[f.key] = TextEditingController();
    }
    final initial = widget.initialSize;
    if (initial != null) _fillControllers(initial);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _parse(String key) {
    final text = _controllers[key]?.text.trim();
    if (text == null || text.isEmpty) return null;
    return double.tryParse(text);
  }

  void _submit() {
    final size = ClothingSize(
      totalLength: _parse('totalLength'),
      shoulderWidth: _parse('shoulderWidth'),
      chestWidth: _parse('chestWidth'),
      sleeveLength: _parse('sleeveLength'),
      waistWidth: _parse('waistWidth'),
      hipWidth: _parse('hipWidth'),
      thighWidth: _parse('thighWidth'),
      pantsLength: _parse('pantsLength'),
    );
    Navigator.pop(context, size.hasAnyData ? size : null);
  }

  // 사이즈표 캡처 → 사이즈 행 선택 → 촬영/선택 → OCR → 필드 자동 채움.
  // 실패해도 필드는 비어있는 채로 남아 손 입력으로 자연스럽게 폴백된다.
  Future<void> _scanSizeChart() async {
    final sizeLabel = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SizeLabelPickerSheet(),
    );
    if (sizeLabel == null || !mounted) return;

    final source = await _pickImageSourceChoice(context);
    if (source == null || !mounted) return;

    final xFile = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (xFile == null || !mounted) return;

    setState(() => _isScanning = true);
    try {
      final bytes = await xFile.readAsBytes();
      final result = await _scanSizeChartWithRetry(
        imageBytes: bytes,
        category: widget.category,
        sizeLabel: sizeLabel,
      );
      if (!mounted) return;
      _fillControllers(result);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.hasAnyData
            ? 'AI가 읽은 값이에요. 확인 후 저장해 주세요.'
            : '사이즈표에서 인식된 값이 없어요. 사진을 다시 확인하거나 직접 입력해 주세요.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('자동 인식 실패: 직접 입력해 주세요. ($e)'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  void _fillControllers(ClothingSize size) {
    void set(String key, double? value) {
      _controllers[key]?.text = value?.toString() ?? '';
    }

    set('totalLength', size.totalLength);
    set('shoulderWidth', size.shoulderWidth);
    set('chestWidth', size.chestWidth);
    set('sleeveLength', size.sleeveLength);
    set('waistWidth', size.waistWidth);
    set('hipWidth', size.hipWidth);
    set('thighWidth', size.thighWidth);
    set('pantsLength', size.pantsLength);
  }

  Future<ImageSource?> _pickImageSourceChoice(BuildContext context) {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: AppColors.navy),
              title: const Text('카메라로 촬영'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppColors.navy),
              title: const Text('갤러리에서 선택'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
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
              const SizedBox(height: 20),
              Text(
                widget.isEditingExisting ? '치수 수정' : '치수 입력 (선택)',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '무신사 사이즈표를 참고해 입력하면 체형과 비교한 예상 핏을 보여드려요',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _isScanning ? null : _scanSizeChart,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.bluePale,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.blue.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isScanning)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(color: AppColors.blue, strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.document_scanner_outlined, color: AppColors.blue, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _isScanning ? 'AI가 사이즈표를 읽는 중...' : '사이즈표 캡처로 자동 입력',
                        style: const TextStyle(
                            color: AppColors.blue, fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              ..._fields.map((f) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _controllers[f.key],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: '${f.label} (cm)',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                      ),
                    ),
                  )),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: Text(widget.isEditingExisting ? '취소' : '건너뛰기',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _submit,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.navy,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          '완료',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 사이즈표 OCR용 사이즈 행 선택 바텀시트 ───────────────
// ── 액세서리 세부 타입 선택 (선택) ────────────────────────
class _AccessorySubCategoryPickerSheet extends StatelessWidget {
  const _AccessorySubCategoryPickerSheet();

  static const _options = ['모자', '가방', '시계', '팔찌'];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 20),
            const Text(
              '어떤 액세서리인가요? (선택)',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '코디 보드에서 모자/가방/시계 슬롯을 구분해서 채우는 데 쓰여요',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            ..._options.map((option) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, option),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        option,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                )),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('해당 없음 / 건너뛰기',
                  style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SizeLabelPickerSheet extends StatefulWidget {
  const _SizeLabelPickerSheet();

  @override
  State<_SizeLabelPickerSheet> createState() => _SizeLabelPickerSheetState();
}

class _SizeLabelPickerSheetState extends State<_SizeLabelPickerSheet> {
  static const _quickLabels = ['S', 'M', 'L', 'XL', 'XXL'];
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _controller.text.trim();
    if (label.isEmpty) return;
    Navigator.pop(context, label);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                const SizedBox(height: 20),
                const Text(
                  '어떤 사이즈 행을 읽을까요?',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '사이즈표에서 이 옷에 해당하는 사이즈를 알려주세요',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _quickLabels.map((label) {
                    final isSelected = _controller.text == label;
                    return ChoiceChip(
                      label: Text(label),
                      selected: isSelected,
                      onSelected: (_) => setState(() => _controller.text = label),
                      selectedColor: AppColors.bluePale,
                      labelStyle: TextStyle(
                          color: isSelected ? AppColors.blue : AppColors.textSecondary,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500),
                      backgroundColor: AppColors.background,
                      side: BorderSide(color: isSelected ? AppColors.blue : AppColors.border),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: '예: L, 100, Free',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: _submit,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.navy,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '다음: 사진 선택',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final VoidCallback onTap;

  const _SourceButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.navy,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 2),
                Text(sublabel,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    )),
              ],
            ),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios,
                color: AppColors.textDisabled, size: 14),
          ],
        ),
      ),
    );
  }
}

// ── 공통 뷰 ──────────────────────────────────────────
// ── "비슷한 옷" 썸네일 한 장 — 카드 액션 시트 전용.
// 코사인 유사도 수치는 사용자에게 그대로 노출하지 않는다(해석 불가/오해
// 소지) — EmbeddingService가 이미 상대 순위(topN)로만 골라준 결과라
// 여기서도 순위 정보 없이 이미지+짧은 라벨만 보여준다.
class _SimilarItemThumbnail extends StatelessWidget {
  final WardrobeItem item;

  const _SimilarItemThumbnail({required this.item});

  String get _label {
    final color = item.attributes?.color;
    return (color != null && color.isNotEmpty) ? '$color ${item.category}' : item.category;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: item.cutoutImageUrl ?? item.imageUrl,
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(width: 64, height: 64, color: AppColors.background),
              errorWidget: (_, __, ___) => Container(
                width: 64,
                height: 64,
                color: AppColors.background,
                child: const Icon(Icons.image_not_supported_outlined,
                    size: 18, color: AppColors.textDisabled),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: AppColors.navy, strokeWidth: 2),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;

  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_outlined,
                color: AppColors.textDisabled, size: 40),
            const SizedBox(height: 16),
            const Text(
              '데이터를 불러오지 못했습니다',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── 옷장 카드 ─────────────────────────────────────────
class _WardrobeCard extends StatelessWidget {
  final WardrobeItem item;
  final UserProfile? userProfile;
  final VoidCallback onDelete;

  const _WardrobeCard({required this.item, required this.userProfile, required this.onDelete});

  String _formatDate(DateTime dt) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';

  Color _fitColor(FitLevel level) {
    switch (level) {
      case FitLevel.slim:
        return AppColors.red;
      case FitLevel.regular:
        return AppColors.greenDark;
      case FitLevel.semiOversized:
        return AppColors.amber;
      case FitLevel.oversized:
      case FitLevel.loose:
        return AppColors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fitResult = FitPredictor.predict(
      category: item.category,
      size: item.size,
      profile: userProfile,
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(10)),
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
                // 카테고리 뱃지
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.navy.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.category,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                // 삭제 버튼
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: onDelete,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.delete_outline,
                          color: Colors.white, size: 15),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.category,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _formatDate(item.createdAt),
                        style: const TextStyle(
                          color: AppColors.textPlaceholder,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (fitResult != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: _fitColor(fitResult.level).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: _fitColor(fitResult.level).withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      fitResult.label,
                      style: TextStyle(
                        color: _fitColor(fitResult.level),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
