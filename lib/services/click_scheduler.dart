import 'dart:async';

import '../services/ntp_time_engine.dart';
import '../services/win32_mouse.dart';

/// 调度器状态
enum SchedulerState { idle, waiting, firing, done, cancelled, error }
/// 高精度点击触发器
///
/// 时间基准完全来自 [NtpTimeEngine]（NTP 服务器时间）。
/// - 粗等阶段：用 async Future.delayed 等待，UI 保持响应
/// - 末段（目标前约 100ms）：进入忙等循环，跨越目标瞬间立即点击，达到亚毫秒精度
class ClickScheduler {
  final NtpTimeEngine _engine;
  ClickScheduler(this._engine);

  SchedulerState _state = SchedulerState.idle;
  SchedulerState get state => _state;

  Timer? _tickTimer;
  bool _cancelFlag = false;

  /// 启动定时触发。
  ///
  /// [targetNtpTime] 目标服务器绝对时间（UTC）。
  /// [repeatCount] 到点后连续点击次数（≥1）。
  /// [intervalMs] 两次点击之间的间隔毫秒数（≥2）。
  /// [onTick] 倒计时回调（粗等阶段每 50ms 触发一次，报告剩余时长）。
  /// [onProgress] 连击进度回调（已完成次数 / 总次数）。
  /// [onFired] 全部点击完成后回调，附带首次触发时刻的服务器时间。
  /// [onError] 出错回调。
  Future<void> start({
    required DateTime targetNtpTime,
    required int x,
    required int y,
    required MouseButton button,
    required int repeatCount,
    required int intervalMs,
    required void Function(Duration remaining) onTick,
    required void Function(int done, int total) onProgress,
    required void Function(DateTime firedAt) onFired,
    required void Function(String message) onError,
  }) async {
    if (!_engine.isSynced) {
      _state = SchedulerState.error;
      onError('NTP 尚未同步，请先校时');
      return;
    }

    final count = repeatCount < 1 ? 1 : repeatCount;
    final interval = intervalMs < 2 ? 2 : intervalMs;

    _cancelFlag = false;
    _state = SchedulerState.waiting;

    final targetSwMicros = _engine.targetToSwMicros(targetNtpTime);

    // 倒计时驱动：每 50ms 报告剩余时长
    _tickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_cancelFlag) return;
      final nowSw = _engine.swMicros();
      final remainingMicros = targetSwMicros - nowSw;
      if (remainingMicros > 0) {
        onTick(Duration(microseconds: remainingMicros));
      }
    });

    // 检查目标是否已过
    final nowSw = _engine.swMicros();
    if (nowSw >= targetSwMicros) {
      _tickTimer?.cancel();
      _state = SchedulerState.error;
      onError('目标时间已过，无法触发');
      return;
    }

    // 粗等：等到目标前约 100ms
    const coarseLeadMicros = 100000; // 100ms
    var remaining = targetSwMicros - _engine.swMicros();
    while (remaining > coarseLeadMicros && !_cancelFlag) {
      final sleepMicros = remaining - coarseLeadMicros;
      // 分段等待，便于及时响应取消
      final chunk = sleepMicros > 500000 ? 500000 : sleepMicros;
      await Future.delayed(Duration(microseconds: chunk));
      remaining = targetSwMicros - _engine.swMicros();
    }

    _tickTimer?.cancel();

    if (_cancelFlag) {
      _state = SchedulerState.cancelled;
      return;
    }

    // 末段忙等：跨越目标瞬间立即触发
    _state = SchedulerState.firing;
    while (_engine.swMicros() < targetSwMicros) {
      if (_cancelFlag) {
        _state = SchedulerState.cancelled;
        return;
      }
    }

    // 记录首次触发时刻（服务器时间）
    final firedAt = _engine.now();

    // 连续点击 count 次，间隔 interval 毫秒（忙等保证精度）
    // 点击期间光标固定在目标坐标，结束后恢复原位
    final saved = getCursorPos();
    setCursorPos(x, y);
    final intervalMicros = interval * 1000;
    for (var i = 0; i < count; i++) {
      if (_cancelFlag) {
        setCursorPos(saved[0], saved[1]);
        _state = SchedulerState.cancelled;
        return;
      }
      click(button);
      onProgress(i + 1, count);
      // 最后一次不需要等间隔
      if (i < count - 1) {
        busyWaitMicros(intervalMicros);
      }
    }
    setCursorPos(saved[0], saved[1]);

    _state = SchedulerState.done;
    onFired(firedAt);
  }

  /// 取消触发
  void cancel() {
    _cancelFlag = true;
    _tickTimer?.cancel();
    if (_state == SchedulerState.waiting || _state == SchedulerState.firing) {
      _state = SchedulerState.cancelled;
    }
  }

  void dispose() {
    _tickTimer?.cancel();
  }
}
