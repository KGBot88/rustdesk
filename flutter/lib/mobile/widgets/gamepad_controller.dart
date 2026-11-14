// rustdesk-controller fork: drive the remote PC with a handheld's built-in
// controller (made for the AYN Thor, works with any Android gamepad).
//
// Android side: android/app/src/main/kotlin/com/carriez/flutter_hbb/GamepadBridge.kt
// Button table: README-CONTROLLER.md in the repo root.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

/// Android keycodes we care about.
class _K {
  static const dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22;
  static const dpadCenter = 23, back = 4;
  static const a = 96, b = 97, x = 99, y = 100;
  static const l1 = 102, r1 = 103, l2 = 104, r2 = 105;
  static const l3 = 106, r3 = 107, start = 108, select = 109;
}

class GamepadController {
  static const _channel = MethodChannel('rd_gamepad');

  // ---- Tuning (change here, rebuild) ----
  static const double stickDeadzone = 0.15;
  static const double maxCursorSpeed = 1600; // remote pixels / second at full tilt
  static const double minCursorSpeed = 40; // just past the deadzone
  static const double cursorCurve = 2.2; // >1 = more precision near centre
  static const double precisionFactor = 0.3; // R3 slow mode
  static const double maxScrollTicksPerSec = 22;
  static const double triggerDown = 0.55, triggerUp = 0.35;
  static const Duration repeatDelay = Duration(milliseconds: 380);
  static const Duration repeatEvery = Duration(milliseconds: 55);
  static const Duration tick = Duration(milliseconds: 8);
  static const Duration comboHold = Duration(seconds: 1); // hold Select+Start
  static const Duration bHoldForEsc = Duration(milliseconds: 500); // B tap = Undo, hold = Esc
  static const double zoomStep = 1.5; // D-pad Up zooms in by this much per press
  static const String _kOptMouseMode = 'rdpad-mouse-mode'; // 'N' = off

  final FFI ffi;
  final VoidCallback onToggleKeyboard;

  /// Called after the pad changes the PC's text, so the on-screen keyboard's text
  /// can follow: 'VK_BACK', 'VK_RETURN', 'undo' or 'paste'.
  final void Function(String vk)? onPadKeySent;

  GamepadController(
      {required this.ffi, required this.onToggleKeyboard, this.onPadKeySent});

  /// Controller-mouse mode. Off = the pad does nothing on the PC (Android keeps B/Back/Home).
  final ValueNotifier<bool> mouseMode = ValueNotifier<bool>(
      bind.getLocalFlutterOption(k: _kOptMouseMode) != 'N');

  // Select+Start combo state.
  bool _selectDown = false, _startDown = false, _bothWereDown = false;
  Timer? _comboTimer;

  InputModel get _input => ffi.inputModel;
  CursorModel get _cursor => ffi.cursorModel;

  double _lx = 0, _ly = 0, _rx = 0, _ry = 0;
  double _lt = 0, _rt = 0;
  int _hatX = 0, _hatY = 0;
  bool _ltAxisDown = false, _rtAxisDown = false;
  bool _l2KeyDown = false, _r2KeyDown = false;
  bool _leftHeld = false, _rightHeld = false;
  bool _precision = false;
  Timer? _bTimer; // B: tap = Undo, hold = Esc
  // Some pads report one D-pad press as a hat move AND a D-pad key; act on it once.
  final Map<int, Duration> _lastDpad = {};
  bool _bFiredEsc = false;
  double _scrollAccX = 0, _scrollAccY = 0;

  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  Duration _lastTick = Duration.zero;

  // Held keys that auto-repeat: Android keycode -> repeat timer.
  final Map<int, Timer> _repeat = {};

  void start() {
    _channel.setMethodCallHandler(_onCall);
    _channel.invokeMethod('set_mode', mouseMode.value);
    _channel.invokeMethod('set_active', true);
    _clock
      ..reset()
      ..start();
    _lastTick = Duration.zero;
    _timer = Timer.periodic(tick, (_) => _onTick());
  }

  void stop() {
    _channel.invokeMethod('set_active', false);
    _channel.setMethodCallHandler(null);
    _timer?.cancel();
    _timer = null;
    _comboTimer?.cancel();
    _releaseAll();
  }

  /// Let go of everything: held clicks, repeating keys, stick state.
  void _releaseAll() {
    _bTimer?.cancel();
    _bTimer = null;
    for (final t in _repeat.values) {
      t.cancel();
    }
    _repeat.clear();
    if (_leftHeld) _input.tapUp(MouseButtons.left);
    if (_rightHeld) _input.tapUp(MouseButtons.right);
    _leftHeld = _rightHeld = false;
    _lx = _ly = _rx = _ry = _lt = _rt = 0;
    _ltAxisDown = _rtAxisDown = _l2KeyDown = _r2KeyDown = false;
    _hatX = _hatY = 0;
    _scrollAccX = _scrollAccY = 0;
  }

  /// Turn controller-mouse mode on or off (toolbar button or Select+Start held).
  void setMouseMode(bool on) {
    if (!on) _releaseAll();
    mouseMode.value = on;
    bind.setLocalFlutterOption(k: _kOptMouseMode, v: on ? 'Y' : 'N');
    _channel.invokeMethod('set_mode', on);
    showToast(on ? 'Controller mouse ON' : 'Controller mouse OFF',
        timeout: const Duration(milliseconds: 1200));
  }

  void toggleMouseMode() => setMouseMode(!mouseMode.value);

  /// Select and Start: a tap does its normal job (on release); holding both toggles the mode.
  void _onComboKey(int code, bool down) {
    if (down) {
      if (code == _K.select) _selectDown = true;
      if (code == _K.start) _startDown = true;
      if (_selectDown && _startDown && !_bothWereDown) {
        _bothWereDown = true;
        _comboTimer?.cancel();
        _comboTimer = Timer(comboHold, toggleMouseMode);
      }
      return;
    }
    final wasDown = code == _K.select ? _selectDown : _startDown;
    if (code == _K.select) _selectDown = false;
    if (code == _K.start) _startDown = false;
    _comboTimer?.cancel();
    if (wasDown && !_bothWereDown && mouseMode.value) {
      if (code == _K.select) {
        _altTab();
      } else {
        _press('Meta'); // Windows key / Start menu
      }
    }
    if (!_selectDown && !_startDown) _bothWereDown = false;
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'axes':
        if (!mouseMode.value) break;
        final v = (call.arguments as List).cast<num>();
        _lx = v[0].toDouble();
        _ly = v[1].toDouble();
        _rx = v[2].toDouble();
        _ry = v[3].toDouble();
        _lt = v[4].toDouble();
        _rt = v[5].toDouble();
        _onTriggers();
        _onHat(v[6].round(), v[7].round());
        break;
      case 'key':
        final m = call.arguments as Map;
        _onKey(m['code'] as int, m['down'] as bool);
        break;
    }
    return null;
  }

  // ---------------- sticks ----------------

  /// Radial deadzone + response curve. Returns a vector with length 0..1.
  static Point<double> _shape(double x, double y, double curve) {
    final mag = sqrt(x * x + y * y);
    if (mag < stickDeadzone) return const Point(0.0, 0.0);
    final norm = ((min(mag, 1.0) - stickDeadzone) / (1 - stickDeadzone));
    final shaped = pow(norm, curve).toDouble();
    return Point(x / mag * shaped, y / mag * shaped);
  }

  void _onTick() {
    final now = _clock.elapsed;
    final dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    if (dt <= 0 || dt > 0.1) return;

    // Right stick -> cursor.
    final m = _shape(_rx, _ry, cursorCurve);
    if (m.x != 0 || m.y != 0) {
      final len = sqrt(m.x * m.x + m.y * m.y);
      var speed = minCursorSpeed + (maxCursorSpeed - minCursorSpeed) * len;
      if (_precision) speed *= precisionFactor;
      final scale = ffi.canvasModel.scale;
      final dx = m.x / len * speed * dt * scale;
      final dy = m.y / len * speed * dt * scale;
      if (_input.relativeMouseMode.value) {
        _input.sendMobileRelativeMouseMove(dx / scale, dy / scale);
      } else {
        // Same call RustDesk's on-screen joystick uses (screen pixels).
        _cursor.updatePan(Offset(dx, dy), Offset.zero, false);
      }
    }

    // Left stick -> wheel (linear feel is better for scrolling).
    final s = _shape(_lx, _ly, 1.6);
    _scrollAccX += -s.x * maxScrollTicksPerSec * dt;
    _scrollAccY += -s.y * maxScrollTicksPerSec * dt;
    final wx = _scrollAccX.truncate();
    final wy = _scrollAccY.truncate();
    if (s.x == 0) _scrollAccX = 0;
    if (s.y == 0) _scrollAccY = 0;
    if (wx != 0 || wy != 0) {
      _scrollAccX -= wx;
      _scrollAccY -= wy;
      _wheel(wx, wy);
    }
  }

  void _wheel(int x, int y) {
    if (!_input.keyboardPerm) return;
    bind.sessionSendMouse(
        sessionId: ffi.sessionId,
        msg: json.encode({'type': 'wheel', 'x': '$x', 'y': '$y'}));
  }

  // ---------------- triggers / mouse buttons ----------------

  void _onTriggers() {
    if (!_rtAxisDown && _rt > triggerDown) {
      _rtAxisDown = true;
    } else if (_rtAxisDown && _rt < triggerUp) {
      _rtAxisDown = false;
    }
    if (!_ltAxisDown && _lt > triggerDown) {
      _ltAxisDown = true;
    } else if (_ltAxisDown && _lt < triggerUp) {
      _ltAxisDown = false;
    }
    _syncButtons();
  }

  /// Triggers may arrive as an axis, a key (L2/R2) or both; either one holds the button.
  void _syncButtons() {
    final left = _rtAxisDown || _r2KeyDown;
    final right = _ltAxisDown || _l2KeyDown;
    if (left != _leftHeld) {
      _leftHeld = left;
      left ? _input.tapDown(MouseButtons.left) : _input.tapUp(MouseButtons.left);
    }
    if (right != _rightHeld) {
      _rightHeld = right;
      right
          ? _input.tapDown(MouseButtons.right)
          : _input.tapUp(MouseButtons.right);
    }
  }

  // ---------------- buttons ----------------

  void _onHat(int hx, int hy) {
    if (hx != _hatX) {
      if (_hatX != 0) _keyUp(_hatX < 0 ? _K.dpadLeft : _K.dpadRight);
      if (hx != 0) _keyDown(hx < 0 ? _K.dpadLeft : _K.dpadRight);
      _hatX = hx;
    }
    if (hy != _hatY) {
      if (_hatY != 0) _keyUp(_hatY < 0 ? _K.dpadUp : _K.dpadDown);
      if (hy != 0) _keyDown(hy < 0 ? _K.dpadUp : _K.dpadDown);
      _hatY = hy;
    }
  }

  void _onKey(int code, bool down) {
    if (code == _K.select || code == _K.start) {
      _onComboKey(code, down);
      return;
    }
    if (!mouseMode.value) return;
    down ? _keyDown(code) : _keyUp(code);
  }

  /// Keys that send a remote key and auto-repeat while held.
  static const Map<int, String> _repeatKeys = {
    _K.x: 'VK_BACK',
  };

  void _keyDown(int code) {
    final rk = _repeatKeys[code];
    if (rk != null) {
      _press(rk);
      _repeat[code]?.cancel();
      _repeat[code] = Timer(repeatDelay, () {
        _repeat[code] = Timer.periodic(repeatEvery, (_) => _press(rk));
      });
      return;
    }
    switch (code) {
      case _K.r2:
        _r2KeyDown = true;
        _syncButtons();
        break;
      case _K.l2:
        _l2KeyDown = true;
        _syncButtons();
        break;
      case _K.a:
      case _K.dpadCenter:
        _press('VK_RETURN');
        break;
      case _K.b:
        _bFiredEsc = false;
        _bTimer?.cancel();
        _bTimer = Timer(bHoldForEsc, () {
          _bFiredEsc = true;
          _press('VK_ESCAPE');
        });
        break;
      case _K.dpadUp:
        if (_dpadDup(code)) break;
        _zoomAtCursor();
        break;
      case _K.dpadDown:
        if (_dpadDup(code)) break;
        _fitScreen();
        break;
      case _K.dpadLeft:
        if (_dpadDup(code)) break;
        _ctrlKey('VK_C'); // Copy
        break;
      case _K.dpadRight:
        if (_dpadDup(code)) break;
        _ctrlKey('VK_V'); // Paste
        onPadKeySent?.call('paste');
        break;
      case _K.y:
        onToggleKeyboard();
        break;
      case _K.l1:
        _cycleMonitor(-1);
        break;
      case _K.r1:
        _cycleMonitor(1);
        break;
      case _K.l3:
        _input.tapDown(MouseButtons.wheel);
        break;
      case _K.r3:
        _precision = !_precision;
        showToast(_precision ? 'Precise cursor ON' : 'Precise cursor OFF',
            timeout: const Duration(milliseconds: 900));
        break;
      case _K.back:
        // Swallowed on purpose: no accidental "leave session".
        break;
    }
  }

  void _keyUp(int code) {
    final t = _repeat.remove(code);
    if (t != null) {
      t.cancel();
      return;
    }
    switch (code) {
      case _K.r2:
        _r2KeyDown = false;
        _syncButtons();
        break;
      case _K.l2:
        _l2KeyDown = false;
        _syncButtons();
        break;
      case _K.l3:
        _input.tapUp(MouseButtons.wheel);
        break;
      case _K.b:
        if (_bTimer != null && !_bFiredEsc) {
          _ctrlKey('VK_Z'); // Undo
          onPadKeySent?.call('undo');
        }
        _bTimer?.cancel();
        _bTimer = null;
        break;
    }
  }

  void _press(String name) {
    _input.inputKey(name);
    if (name == 'VK_BACK' || name == 'VK_RETURN') onPadKeySent?.call(name);
  }

  bool _dpadDup(int code) {
    final now = _clock.elapsed;
    final last = _lastDpad[code];
    _lastDpad[code] = now;
    return last != null && now - last < const Duration(milliseconds: 120);
  }

  void _ctrlKey(String name) {
    if (!_input.keyboardPerm) return;
    bind.sessionInputKey(
        sessionId: ffi.sessionId,
        name: name,
        down: false,
        press: true,
        alt: false,
        ctrl: true,
        shift: false,
        command: false);
  }

  // ---------------- view: zoom / fit ----------------

  /// Zoom the picture in around the mouse cursor (stops at RustDesk's max zoom).
  void _zoomAtCursor() {
    final canvas = ffi.canvasModel;
    final s = canvas.scale;
    final focal = Offset(canvas.x + _cursor.x * s,
        canvas.y + _cursor.y * s + canvas.getAdjustY());
    canvas.updateScale(zoomStep, focal);
    if ((canvas.scale - s).abs() < 1e-6) {
      showToast('Max zoom', timeout: const Duration(milliseconds: 700));
    }
  }

  /// Fit the whole PC monitor on the handheld's screen.
  void _fitScreen() {
    final canvas = ffi.canvasModel;
    final size = canvas.getSize();
    final w = canvas.getDisplayWidth(), h = canvas.getDisplayHeight();
    if (w <= 0 || h <= 0 || canvas.scale <= 0) return;
    final fit = min(size.width / w, size.height / h);
    canvas.updateScale(
        fit / canvas.scale, Offset(size.width / 2, size.height / 2));
    canvas.resetOffset();
  }

  void _altTab() {
    if (!_input.keyboardPerm) return;
    bind.sessionInputKey(
        sessionId: ffi.sessionId,
        name: 'VK_TAB',
        down: false,
        press: true,
        alt: true,
        ctrl: false,
        shift: false,
        command: false);
  }

  void _cycleMonitor(int dir) {
    final pi = ffi.ffiModel.pi;
    final n = pi.displays.length;
    if (n < 2) {
      showToast('Only one monitor',
          timeout: const Duration(milliseconds: 900));
      return;
    }
    final cur = pi.currentDisplay == kAllDisplayValue ? 0 : pi.currentDisplay;
    final next = (cur + dir + n) % n;
    openMonitorInTheSameTab(next, ffi, pi);
    showToast('Monitor ${next + 1} of $n',
        timeout: const Duration(milliseconds: 900));
  }
}
