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

  static Future<String> uploadWardrobeImage(XFile xFile) async {
    final file = File(xFile.path);
    final fileName = '${_randomFileStem()}.jpg';
    final ref = _storage.ref().child('$_folder/$fileName');

    await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    return ref.getDownloadURL();
  }

  // 온디바이스 배경 제거 결과(투명 PNG)를 업로드한다. 원본과 별도 경로에
  // 저장해 원본은 항상 보존되도록 한다.
  static Future<String> uploadWardrobeCutout(Uint8List pngBytes) async {
    final fileName = '${_randomFileStem()}.png';
    final ref = _storage.ref().child('$_cutoutFolder/$fileName');
    await ref.putData(pngBytes, SettableMetadata(contentType: 'image/png'));
    return ref.getDownloadURL();
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
  // 같은 조합이면 항상 같은 경로에 덮어쓰기(overwrite)되게 한다.
  static Future<String> uploadFittingResult(Uint8List bytes, String cacheKey) async {
    final ref = _storage.ref().child('$_fittingResultsFolder/$cacheKey.jpg');
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }
}