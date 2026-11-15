import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

// 음성 입력 — 기기의 음성 인식을 글자로 바꿔 입력창에 채운다. 자동으로 보내지 않는다.
// 앱은 음성을 저장하지 않는다(글자만 입력창에 들어간다).
//
// VoiceEngine은 speech_to_text를 얇게 감싼 것 — 테스트에서 가짜로 바꿔 끼운다.
// VoiceInput은 화면 하나의 상태(버튼을 보일지, 듣는 중인지, 어느 입력창에 채울지)를 갖는다.
//
// 입력창 = 듣기를 시작할 때 있던 글 + 이번 듣기에서 확정된 글 + 지금 인식 중인 임시 글.
// 확정된 글은 인식 결과 때문에 지워지지 않는다. (예전에는 결과가 올 때마다 "시작 글 + 최신
// 결과"로 입력창 전체를 바꿔 썼다. 안드로이드 인식기는 말이 잠깐 끊기면 그 앞을 한 구간으로
// 확정하고 다음 결과에는 새 구간만 담아 보내서, 앞에 말한 부분이 사라졌다.)

enum VoiceInitResult { ready, denied, unavailable }

abstract class VoiceEngine {
  // 권한을 묻지 않고 지금 마이크 권한이 있는지만.
  Future<bool> hasPermission();
  // 초기화 — 권한이 없으면 권한을 묻는다(버튼을 처음 누를 때만 부른다).
  Future<VoiceInitResult> init();
  // 한 번 듣기(기기 인식기 한 세션). onWords(글, 확정 여부) — 확정이 아니면 임시 글.
  // onLevel(0~1) — 소리 크기. onDone — 기기 인식기가 이 세션을 끝냄(말이 끊김 등).
  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
    required void Function(double level) onLevel,
    required VoidCallback onDone,
  });
  Future<void> stop();
}

// 안드로이드 onRmsChanged 값(대략 -2~10dB)을 0~1로.
double voiceLevelFromRms(double rmsDb) => ((rmsDb + 2) / 12).clamp(0.0, 1.0);

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
          // 'notListening'은 마지막 결과보다 먼저 올 수 있어 'done'(결과까지 끝남)을 기다린다.
          if (s == SpeechToText.doneStatus || s == 'doneNoResult') _finish();
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
  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
    required void Function(double level) onLevel,
    required VoidCallback onDone,
  }) async {
    _onDone = onDone;
    try {
      await _stt.listen(
        // partial이 아니면(구간 확정 intermediate, 마지막 final) 확정.
        onResult: (SpeechRecognitionResult r) =>
            onWords(r.recognizedWords, r.resultTypeValue != ResultType.partial),
        onSoundLevelChange: (db) => onLevel(voiceLevelFromRms(db)),
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          // 끊김·전체 시간은 VoiceInput이 잰다(6초 조용, 60초 전체).
          listenFor: const Duration(seconds: 60),
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
const voiceSilenceLimit = Duration(seconds: 6); // 새 말이 이만큼 없으면 끈다
const voiceTotalLimit = Duration(seconds: 60); // 한 번 켠 뒤 전체
const voiceRestartDelay = Duration(milliseconds: 250); // 기기 인식기가 끝난 뒤 다시 듣기까지

enum VoiceToggle { started, stopped, denied, unavailable }

// a 뒤에 b를 한 칸 띄워 잇는다(둘 중 하나가 비면 그대로).
String _join(String a, String b) => a.isEmpty ? b : (b.isEmpty ? a : '$a $b');

class VoiceInput extends ChangeNotifier {
  final VoiceEngine engine;
  VoiceInput(this.engine);

  bool _available = true; // 쓸 수 없다고 알게 되면 false — 버튼을 숨긴다
  bool _listening = false;
  bool _busy = false;
  TextEditingController? _target;
  bool _disposed = false;

  String _base = ''; // 듣기를 시작할 때 있던 글
  String _committed = ''; // 이번 듣기에서 확정된 글(세션을 넘어 이어짐)
  String _sessionCommitted = ''; // 지금 세션에서 확정된 글 — 누적형 결과의 앞부분을 걸러 낸다
  String _partial = ''; // 지금 인식 중인 임시 글
  String? _written; // 마지막으로 입력창에 쓴 글 — 다르면 사용자가 고친 것
  int _session = 0;
  Timer? _silenceTimer;
  Timer? _totalTimer;
  Timer? _restartTimer;

  // 소리 크기(0~1) — 화면 전체를 다시 그리지 않게 따로 알린다.
  final ValueNotifier<double> level = ValueNotifier(0);
  // 소리 크기 값이 한 번이라도 왔는지(이번 듣기) — 안 오는 기기에서는 일정한 맥박으로 그린다.
  bool _levelSeen = false;
  bool get levelSeen => _levelSeen;

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
      _committed = '';
      _partial = '';
      _written = target.text;
      _levelSeen = false;
      level.value = 0;
      target.addListener(_onTargetChanged);
      _listening = true;
      _notify();
      _totalTimer = Timer(voiceTotalLimit, stop);
      _bumpSilence();
      await _listenOnce();
      return VoiceToggle.started;
    } finally {
      _busy = false;
    }
  }

  Future<void> _listenOnce() async {
    if (!_listening) return;
    final session = ++_session;
    _sessionCommitted = '';
    await engine.listen(
      onWords: (w, isFinal) {
        if (session == _session) _onWords(w, isFinal);
      },
      onLevel: (v) {
        if (session != _session || !_listening) return;
        _levelSeen = true;
        level.value = v;
      },
      onDone: () {
        if (session == _session) _onSessionDone();
      },
    );
  }

  // 누적형 결과(세션 안에서 앞 구간을 다시 담아 보냄)면 이미 확정한 앞부분을 떼어 낸다.
  String _fresh(String words) {
    final w = words.trim();
    if (_sessionCommitted.isNotEmpty && w.startsWith(_sessionCommitted)) {
      return w.substring(_sessionCommitted.length).trim();
    }
    return w;
  }

  void _onWords(String words, bool isFinal) {
    if (!_listening || _disposed) return;
    final fresh = _fresh(words);
    final changed = fresh != _partial || isFinal;
    if (isFinal) {
      _committed = _join(_committed, fresh);
      _sessionCommitted = _join(_sessionCommitted, fresh);
      _partial = '';
    } else {
      _partial = fresh;
    }
    if (changed && fresh.isNotEmpty) _bumpSilence();
    _write();
  }

  // 기기 인식기가 세션을 끝냄(말이 끊김) — 남은 임시 글을 확정하고, 마이크가 켜져 있으면 이어서 듣는다.
  void _onSessionDone() {
    if (!_listening) return;
    if (_partial.isNotEmpty) {
      _committed = _join(_committed, _partial);
      _partial = '';
      _write();
    }
    _restartTimer?.cancel();
    _restartTimer = Timer(voiceRestartDelay, _listenOnce);
  }

  void _write() {
    final t = _target;
    if (t == null) return;
    final text = _join(_join(_base, _committed), _partial);
    _written = text;
    t.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  // 듣는 중에 사용자가 입력창을 손으로 고치면 멈춘다(지금 글은 그대로 둔다).
  void _onTargetChanged() {
    final t = _target;
    if (!_listening || t == null) return;
    if (t.text != _written) stop();
  }

  void _bumpSilence() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(voiceSilenceLimit, stop);
  }

  void _clear() {
    _listening = false;
    _session++;
    _silenceTimer?.cancel();
    _totalTimer?.cancel();
    _restartTimer?.cancel();
    _target?.removeListener(_onTargetChanged);
    _target = null;
    _partial = '';
    level.value = 0;
  }

  // 멈추기 — 사용자가 끔, 보내기, 턴 시작, 손으로 고침, 6초 조용, 60초, 화면을 떠날 때.
  // 이후 늦게 온 글자는 채우지 않는다. 입력창의 글은 그대로 둔다.
  Future<void> stop() async {
    if (!_listening) return;
    _clear();
    _notify();
    await engine.stop();
  }

  @override
  void dispose() {
    if (_listening) engine.stop();
    _clear();
    _disposed = true;
    level.dispose();
    super.dispose();
  }
}
