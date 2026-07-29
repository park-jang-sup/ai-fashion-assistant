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
}
