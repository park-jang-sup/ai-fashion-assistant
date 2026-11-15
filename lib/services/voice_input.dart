import 'package:flutter/widgets.dart';
import 'package:speech_to_text/speech_to_text.dart';

// 음성 입력 — 기기의 음성 인식을 글자로 바꿔 입력창에 채운다. 자동으로 보내지 않는다.
// 앱은 음성을 저장하지 않는다(글자만 입력창에 들어간다).
//
// VoiceEngine은 speech_to_text를 얇게 감싼 것 — 테스트에서 가짜로 바꿔 끼운다.
// VoiceInput은 화면 하나의 상태(버튼을 보일지, 듣는 중인지, 어느 입력창에 채울지)를 갖는다.

enum VoiceInitResult { ready, denied, unavailable }

abstract class VoiceEngine {
  // 권한을 묻지 않고 지금 마이크 권한이 있는지만.
  Future<bool> hasPermission();
  // 초기화 — 권한이 없으면 권한을 묻는다(버튼을 처음 누를 때만 부른다).
  Future<VoiceInitResult> init();
  // 듣기 시작 — 알아들은 글자(지금까지 전체)를 onWords로, 듣기가 끝나면 onDone.
  Future<void> listen({required void Function(String words) onWords, required VoidCallback onDone});
  Future<void> stop();
}

class SpeechToTextEngine implements VoiceEngine {
  SpeechToTextEngine._();
  static final SpeechToTextEngine instance = SpeechToTextEngine._();

  final SpeechToText _stt = SpeechToText();
  VoidCallback? _onDone;
  String? _localeId;
  bool _ready = false;

  @override
  Future<bool> hasPermission() async {
    try {
      return await _stt.hasPermission;
    } catch (e) {
      debugPrint('[VOICE] 권한 확인 실패: $e');
      return false;
    }
  }

  @override
  Future<VoiceInitResult> init() async {
    if (_ready) return VoiceInitResult.ready;
    try {
      // 블루투스(근처 기기) 권한은 묻지 않는다 — 마이크 권한만.
      _ready = await _stt.initialize(
        onStatus: (s) {
          if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) _finish();
        },
        onError: (e) {
          debugPrint('[VOICE] 인식 오류: ${e.errorMsg}');
          _finish();
        },
        options: [SpeechToText.androidNoBluetooth],
      );
    } catch (e) {
      // 기기에 음성 인식 서비스가 없으면 오류로 온다.
      debugPrint('[VOICE] 초기화 실패: $e');
      _ready = false;
      return VoiceInitResult.unavailable;
    }
    if (_ready) {
      _localeId = await _pickLocale();
      return VoiceInitResult.ready;
    }
    return await hasPermission() ? VoiceInitResult.unavailable : VoiceInitResult.denied;
  }

  // 한국어 — 기기에 없으면 null(기기 기본 언어).
  Future<String?> _pickLocale() async {
    try {
      final locales = await _stt.locales();
      for (final l in locales) {
        if (l.localeId.toLowerCase().startsWith('ko')) return l.localeId;
      }
    } catch (e) {
      debugPrint('[VOICE] 언어 목록 실패(기기 기본 언어): $e');
    }
    return null;
  }

  void _finish() {
    final done = _onDone;
    _onDone = null;
    done?.call();
  }

  @override
  Future<void> listen({required void Function(String words) onWords, required VoidCallback onDone}) async {
    _onDone = onDone;
    try {
      await _stt.listen(
        onResult: (r) => onWords(r.recognizedWords),
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint('[VOICE] 듣기 시작 실패: $e');
      _finish();
    }
  }

  @override
  Future<void> stop() async {
    _onDone = null;
    try {
      await _stt.stop();
    } catch (e) {
      debugPrint('[VOICE] 멈추기 실패(무시): $e');
    }
  }
}

const voiceDeniedMessage = '마이크 권한이 없어요. 글로 입력해 주세요';

enum VoiceToggle { started, stopped, denied, unavailable }

class VoiceInput extends ChangeNotifier {
  final VoiceEngine engine;
  VoiceInput(this.engine);

  bool _available = true; // 쓸 수 없다고 알게 되면 false — 버튼을 숨긴다
  bool _listening = false;
  bool _busy = false;
  TextEditingController? _target;
  String _base = '';
  bool _disposed = false;

  bool get available => _available;
  bool get listening => _listening;
  TextEditingController? get target => _target;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // 화면을 열 때 — 권한이 이미 있으면 묻지 않고 초기화해 지원 여부를 안다.
  // 권한이 없으면 지금은 묻지 않는다(지원 여부는 버튼을 처음 누를 때 안다).
  Future<void> prepare() async {
    if (!await engine.hasPermission()) return;
    final r = await engine.init();
    if (r == VoiceInitResult.unavailable) {
      _available = false;
      _notify();
    }
  }

  // 마이크 버튼 — 듣는 중이면 멈추고, 아니면 target에 채우며 듣는다.
  Future<VoiceToggle> toggle(TextEditingController target) async {
    if (_listening) {
      await stop();
      return VoiceToggle.stopped;
    }
    if (_busy || !_available) return VoiceToggle.unavailable;
    _busy = true;
    try {
      final r = await engine.init();
      if (_disposed) return VoiceToggle.stopped;
      if (r == VoiceInitResult.denied) return VoiceToggle.denied;
      if (r == VoiceInitResult.unavailable) {
        _available = false;
        _notify();
        return VoiceToggle.unavailable;
      }
      _target = target;
      _base = target.text.trimRight();
      _listening = true;
      _notify();
      await engine.listen(onWords: (w) => _fill(target, w), onDone: () => _ended(target));
      return VoiceToggle.started;
    } finally {
      _busy = false;
    }
  }

  void _fill(TextEditingController target, String words) {
    if (!_listening || _target != target || _disposed) return;
    final text = _base.isEmpty ? words : (words.isEmpty ? _base : '$_base $words');
    target.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _ended(TextEditingController target) {
    if (_target != target) return;
    _listening = false;
    _target = null;
    _notify();
  }

  // 멈추기 — 보내기, 턴 시작, 화면을 떠날 때. 이후 늦게 온 글자는 채우지 않는다.
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    _target = null;
    _notify();
    await engine.stop();
  }

  @override
  void dispose() {
    if (_listening) engine.stop();
    _listening = false;
    _target = null;
    _disposed = true;
    super.dispose();
  }
}
