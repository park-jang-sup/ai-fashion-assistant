import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

// login_screen(미인증 상태 → signInWithCredential)과 settings_screen(이미
// 익명 인증됨 → linkWithCredential)이 "구글 계정 선택 → AuthCredential 생성"
// 부분만 공유한다. 링크냐 사인인이냐는 호출부가 currentUser 유무로 결정한다.
class GoogleAuthService {
  static final _googleSignIn = GoogleSignIn();

  // 사용자가 계정 선택 창에서 취소하면 null.
  static Future<AuthCredential?> pickCredential() async {
    final account = await _googleSignIn.signIn();
    if (account == null) return null;
    final auth = await account.authentication;
    return GoogleAuthProvider.credential(
      idToken: auth.idToken,
      accessToken: auth.accessToken,
    );
  }

  // 로그아웃과 함께 호출해야 한다 — 이게 없으면 _googleSignIn이 마지막으로
  // 로그인한 계정을 세션에 캐시해 두고 있어, 다음 pickCredential()이 계정
  // 선택 창 없이 그 계정을 그대로 돌려준다("로그아웃했는데 다른 계정으로
  // 못 들어간다", 2026-07-31 실기기로 확인된 결함).
  //
  // disconnect()가 아니라 signOut()을 쓴다 — disconnect()는 앱에 대한 계정
  // 인가 자체를 해제해 다음 로그인에서 권한 재동의 화면을 띄우므로 부작용이
  // 크다. signOut()으로 계정 선택 창이 다시 뜨는지 먼저 확인하고, 그걸로
  // 부족할 때만 아래로 바꾸는 걸 검토한다:
  //   static Future<void> signOut() async => _googleSignIn.disconnect();
  static Future<void> signOut() async {
    await _googleSignIn.signOut();
  }
}
