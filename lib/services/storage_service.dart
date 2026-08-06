import 'dart:io';
import 'dart:math';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

class StorageService {
  static final _storage = FirebaseStorage.instance;
  static const _folder = 'wardrobe_images';
  static const _cutoutFolder = 'wardrobe_cutouts';
  static const _fittingResultsFolder = 'fitting_results';

  // 파일명이 밀리초 타임스탬프였을 때는 (1) 인증만 하면 순회로 남의 사진을
  // 읽을 수 있었고 (2) 다중 선택 업로드에서 같은 밀리초 충돌로 덮어써졌다.
  // 규칙(storage.rules)에 소유자 검사를 넣는 쪽은 demo_wardrobe가 원본
  // imageUrl 재사용에 의존해 데모를 깨뜨리므로, 마이그레이션 0인 파일명
  // 난수화를 먼저 한다. 128비트면 충돌·추측 둘 다 실질적으로 불가능하다.
  static String _randomFileStem() {
    final rnd = Random.secure();
    return List<int>.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  // 반환을 (url, path) 레코드로 바꿨다(서명 URL 이행 A-3, docs/
  // task_signed_urls_v1.md). path는 getSignedImageUrls가 서명할 대상을
  // 직접 알려주는 필드고, url은 그대로 폴백용으로 계속 저장한다(§1의
  // "URL 필드는 건드리지 않는다" — 이중 기록, 기존 필드 무변).
  //
  // [C-4b, 2026-08-06] url(→ imageUrl/cutoutImageUrl/fittingImageUrl로
  // Firestore에 저장됨)은 **업로드 직후 서버 트리거(functions/src/index.ts의
  // revokeTokenOnUpload)가 발화하기 전까지만 유효한 잔여물이다.** 트리거가
  // 돌면 이 URL의 다운로드 토큰이 곧 사라져 죽은 링크가 된다(§12 C-4b
  // 참고). 정식 접근 경로는 path + getSignedImageUrls(서명 URL)이고, url은
  // 그 좁은 창(업로드~트리거 발화 사이) 동안의 최후 폴백일 뿐이다 — 새
  // 코드에서 이 URL 필드를 직접 fetch하거나 "유효한 이미지 주소"로
  // 가정하지 말 것. 다음 사람이 이 필드를 정식 경로로 오인하는 건
  // 5.13.2/5.13.3 계열의 재발이다.
  static Future<({String url, String path})> uploadWardrobeImage(XFile xFile) async {
    final file = File(xFile.path);
    final fileName = '${_randomFileStem()}.jpg';
    final ref = _storage.ref().child('$_folder/$fileName');

    await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    final url = await ref.getDownloadURL();
    return (url: url, path: ref.fullPath);
  }

  // 온디바이스 배경 제거 결과(투명 PNG)를 업로드한다. 원본과 별도 경로에
  // 저장해 원본은 항상 보존되도록 한다.
  static Future<({String url, String path})> uploadWardrobeCutout(Uint8List pngBytes) async {
    final fileName = '${_randomFileStem()}.png';
    final ref = _storage.ref().child('$_cutoutFolder/$fileName');
    await ref.putData(pngBytes, SettableMetadata(contentType: 'image/png'));
    final url = await ref.getDownloadURL();
    return (url: url, path: ref.fullPath);
  }

  static Future<void> deleteWardrobeImage(String imageUrl) async {
    try {
      final ref = _storage.refFromURL(imageUrl);
      await ref.delete();
    } catch (e) {
      // Storage 파일이 없어도 Firestore 삭제는 계속 진행
      debugPrint('[스토리지삭제] 실패: $e');
    }
  }

  // 캐시 키(사용자 사진 + 옷 조합의 SHA-256 해시)를 파일명으로 써서
  // 같은 조합이면 항상 같은 경로에 덮어쓰기(overwrite)되게 한다. path는
  // signed_url_policy.ts가 fitting_cache에 대해 하는 것과 동일하게
  // 문서 id(=cacheKey)로도 유도 가능하지만, 호출부가 이미 들고 있는
  // ref.fullPath를 그대로 반환해 유도 규칙을 두 곳에 중복하지 않는다.
  static Future<({String url, String path})> uploadFittingResult(
      Uint8List bytes, String cacheKey) async {
    final ref = _storage.ref().child('$_fittingResultsFolder/$cacheKey.jpg');
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    final url = await ref.getDownloadURL();
    return (url: url, path: ref.fullPath);
  }
}