import 'dart:ffi';

import 'package:ffi/ffi.dart';

final _user32 = DynamicLibrary.open('user32.dll');

// ===== 鼠标控制 =====

typedef _SetCursorPosNative = Int32 Function(Int32 x, Int32 y);
typedef _SetCursorPosDart = int Function(int x, int y);
final _setCursorPos =
    _user32.lookupFunction<_SetCursorPosNative, _SetCursorPosDart>('SetCursorPos');

typedef _MouseEventNative = Void Function(
    Uint32 dwFlags, Uint32 dx, Uint32 dy, Uint32 dwData, IntPtr dwExtraInfo);
typedef _MouseEventDart = void Function(
    int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
final _mouseEvent =
    _user32.lookupFunction<_MouseEventNative, _MouseEventDart>('mouse_event');

typedef _GetCursorPosNative = Int32 Function(Pointer<POINT> lpPoint);
typedef _GetCursorPosDart = int Function(Pointer<POINT> lpPoint);
final _getCursorPos =
    _user32.lookupFunction<_GetCursorPosNative, _GetCursorPosDart>('GetCursorPos');

// mouse_event 标志位
const int _mouseeventfLeftdown = 0x0002;
const int _mouseeventfLeftup = 0x0004;
const int _mouseeventfRightdown = 0x0008;
const int _mouseeventfRightup = 0x0010;

/// Win32 POINT 结构
base class POINT extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

/// 鼠标按键类型
enum MouseButton { left, right }

/// 获取当前光标物理像素坐标
List<int> getCursorPos() {
  final p = calloc<POINT>();
  try {
    _getCursorPos(p);
    return [p.ref.x, p.ref.y];
  } finally {
    calloc.free(p);
  }
}

/// 移动光标到指定物理像素坐标
void setCursorPos(int x, int y) {
  _setCursorPos(x, y);
}

/// 精确等待指定微秒数（忙等，避免 sleep 抖动）
void busyWaitMicros(int micros) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMicroseconds < micros) {}
}

/// 在当前光标位置执行一次点击（按下 15ms 后抬起）。
///
/// 调用前应先调用 [setCursorPos] 移动到目标坐标。
/// 按下与抬起之间固定间隔 15 毫秒。
void click(MouseButton button) {
  final downFlag = button == MouseButton.left ? _mouseeventfLeftdown : _mouseeventfRightdown;
  final upFlag = button == MouseButton.left ? _mouseeventfLeftup : _mouseeventfRightup;

  _mouseEvent(downFlag, 0, 0, 0, 0);
  busyWaitMicros(15000); // 固定 15ms 按下保持
  _mouseEvent(upFlag, 0, 0, 0, 0);
}

// ===== 异步按键状态检测（用于坐标拾取） =====

typedef _GetAsyncKeyStateNative = Int16 Function(Int32 vKey);
typedef _GetAsyncKeyStateDart = int Function(int vKey);
final _getAsyncKeyState =
    _user32.lookupFunction<_GetAsyncKeyStateNative, _GetAsyncKeyStateDart>('GetAsyncKeyState');

const int vkF6 = 0x75;

/// 某虚拟键当前是否按下（全局，不论焦点窗口）
bool isKeyDown(int vKey) {
  final state = _getAsyncKeyState(vKey);
  return (state & 0x8000) != 0;
}

// ===== 窗口尺寸 =====

typedef _FindWindowANative = IntPtr Function(Pointer<Utf8> lpClassName, Pointer<Utf8> lpWindowName);
typedef _FindWindowADart = int Function(Pointer<Utf8> lpClassName, Pointer<Utf8> lpWindowName);
final _findWindowA =
    _user32.lookupFunction<_FindWindowANative, _FindWindowADart>('FindWindowA');

typedef _SetWindowPosNative = Int32 Function(
    IntPtr hWnd, IntPtr hWndInsertAfter, Int32 x, Int32 y, Int32 cx, Int32 cy, Uint32 uFlags);
typedef _SetWindowPosDart = int Function(
    int hWnd, int hWndInsertAfter, int x, int y, int cx, int cy, int uFlags);
final _setWindowPos =
    _user32.lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');

const int _swpNomove = 0x0002;
const int _swpNozorder = 0x0004;
const int _swpNoactivate = 0x0010;

typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);
final _showWindow =
    _user32.lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');

const int _swHide = 0;
const int _swShow = 5;

/// 设置窗口逻辑像素尺寸，不改变位置。
/// 调用后将窗口隐藏再显示以强制刷新（修复 Release 模式空白 Bug）。
void setWindowSize({required double width, required double height}) {
  final clsName = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf8(allocator: calloc);
  final hwnd = _findWindowA(clsName, nullptr);
  calloc.free(clsName);
  if (hwnd == 0) return;
  _setWindowPos(hwnd, 0, 0, 0, width.round(), height.round(),
      _swpNomove | _swpNozorder | _swpNoactivate);
  _showWindow(hwnd, _swHide);
  _showWindow(hwnd, _swShow);
}


