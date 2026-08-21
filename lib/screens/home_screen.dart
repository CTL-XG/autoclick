import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/click_scheduler.dart';
import '../services/ntp_time_engine.dart';
import '../services/win32_mouse.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final NtpTimeEngine _engine = NtpTimeEngine();
  late final ClickScheduler _scheduler = ClickScheduler(_engine);

  bool _syncing = false;
  SyncResult? _syncResult;
  bool _autoSynced = false;

  Timer? _clockTimer;
  String _clockText = '--:--:--.---';

  DateTime? _date;
  final _hourCtrl = TextEditingController();
  final _minuteCtrl = TextEditingController();
  final _secondCtrl = TextEditingController();
  final _msCtrl = TextEditingController();
  final _xCtrl = TextEditingController();
  final _yCtrl = TextEditingController();
  final _repeatCtrl = TextEditingController(text: '1');
  final _intervalCtrl = TextEditingController(text: '100');
  final _offsetCtrl = TextEditingController(text: '0');
  bool _offsetEarly = true;
  MouseButton _button = MouseButton.left;

  SchedulerState _schedState = SchedulerState.idle;
  Duration? _remaining;
  DateTime? _firedAt;
  String? _schedError;
  int _clickDone = 0;
  int _clickTotal = 0;

  Timer? _pickTimer;
  bool _picking = false;
  bool _f6WasDown = false;

  @override
  void initState() {
    super.initState();
    if (Platform.environment['FLUTTER_TEST'] != 'true') {
      _clockTimer = Timer.periodic(const Duration(milliseconds: 50), _onClockTick);
      _syncNow(auto: true);
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _pickTimer?.cancel();
    _scheduler.dispose();
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    _secondCtrl.dispose();
    _msCtrl.dispose();
    _xCtrl.dispose();
    _yCtrl.dispose();
    _repeatCtrl.dispose();
    _intervalCtrl.dispose();
    _offsetCtrl.dispose();
    super.dispose();
  }

  void _onClockTick(Timer t) {
    if (!_engine.isSynced) return;
    setState(() {
      _clockText = _fmt(_engine.now());
    });
  }

  Future<void> _syncNow({bool auto = false}) async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncResult = null;
    });
    final result = await _engine.synchronize();
    setState(() {
      _syncing = false;
      _syncResult = result;
      if (result.success) {
        if (!_autoSynced) {
          _autoSynced = true;
          _seedDefaults();
        }
      }
    });
  }

  void _seedDefaults() {
    final now = _engine.now().toLocal();
    final target = now.add(const Duration(minutes: 1));
    _date = DateTime(target.year, target.month, target.day);
    _hourCtrl.text = target.hour.toString().padLeft(2, '0');
    _minuteCtrl.text = target.minute.toString().padLeft(2, '0');
    _secondCtrl.text = '00';
    _msCtrl.text = '000';
  }

  DateTime? _assembleTargetLocal() {
    if (_date == null) return null;
    final h = int.tryParse(_hourCtrl.text);
    final m = int.tryParse(_minuteCtrl.text);
    final s = int.tryParse(_secondCtrl.text);
    final ms = int.tryParse(_msCtrl.text);
    if (h == null || m == null || s == null || ms == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59 || ms < 0 || ms > 999) return null;
    return DateTime(_date!.year, _date!.month, _date!.day, h, m, s, ms);
  }

  bool _validateTask() {
    if (!_engine.isSynced) {
      _showSnack('请先同步 NTP 时间');
      return false;
    }
    final target = _assembleTargetLocal();
    if (target == null) {
      _showSnack('请填写有效的目标时间');
      return false;
    }
    final x = int.tryParse(_xCtrl.text);
    final y = int.tryParse(_yCtrl.text);
    if (x == null || y == null) {
      _showSnack('请填写有效的坐标');
      return false;
    }
    final targetUtc = target.toUtc();
    if (!targetUtc.isAfter(_engine.now())) {
      _showSnack('目标时间已过，请设置未来时间');
      return false;
    }
    final repeat = int.tryParse(_repeatCtrl.text);
    if (repeat == null || repeat < 1) {
      _showSnack('点击次数需 ≥ 1');
      return false;
    }
    final interval = int.tryParse(_intervalCtrl.text);
    if (interval == null || interval < 2) {
      _showSnack('间隔需 ≥ 2ms');
      return false;
    }
    final offset = int.tryParse(_offsetCtrl.text);
    if (offset == null || offset < 0) {
      _showSnack('偏移量需 ≥ 0ms');
      return false;
    }
    return true;
  }

  Future<void> _startTask() async {
    if (!_validateTask()) return;
    var target = _assembleTargetLocal()!.toUtc();
    final x = int.parse(_xCtrl.text);
    final y = int.parse(_yCtrl.text);
    final repeat = int.tryParse(_repeatCtrl.text) ?? 1;
    final interval = int.tryParse(_intervalCtrl.text) ?? 100;
    final offsetMs = int.tryParse(_offsetCtrl.text) ?? 0;
    if (offsetMs > 0) {
      target = _offsetEarly
          ? target.subtract(Duration(milliseconds: offsetMs))
          : target.add(Duration(milliseconds: offsetMs));
    }

    setState(() {
      _schedState = SchedulerState.waiting;
      _remaining = null;
      _firedAt = null;
      _schedError = null;
      _clickDone = 0;
      _clickTotal = repeat < 1 ? 1 : repeat;
    });

    await _scheduler.start(
      targetNtpTime: target,
      x: x,
      y: y,
      button: _button,
      repeatCount: repeat,
      intervalMs: interval,
      onTick: (rem) {
        if (mounted) setState(() => _remaining = rem);
      },
      onProgress: (done, total) {
        if (mounted) setState(() => _clickDone = done);
      },
      onFired: (fired) {
        if (mounted) {
          setState(() {
            _schedState = SchedulerState.done;
            _firedAt = fired;
          });
        }
      },
      onError: (msg) {
        if (mounted) {
          setState(() {
            _schedState = SchedulerState.error;
            _schedError = msg;
          });
        }
      },
    );
  }

  void _stopTask() {
    _scheduler.cancel();
    setState(() {
      _schedState = SchedulerState.cancelled;
    });
  }

  void _testClick() {
    final x = int.tryParse(_xCtrl.text);
    final y = int.tryParse(_yCtrl.text);
    if (x == null || y == null) {
      _showSnack('请先填写坐标');
      return;
    }
    final repeat = (int.tryParse(_repeatCtrl.text) ?? 1).clamp(1, 9999);
    final interval = (int.tryParse(_intervalCtrl.text) ?? 100).clamp(2, 99999);
    final saved = getCursorPos();
    setCursorPos(x, y);
    final intervalMicros = interval * 1000;
    for (var i = 0; i < repeat; i++) {
      click(_button);
      if (i < repeat - 1) {
        busyWaitMicros(intervalMicros);
      }
    }
    setCursorPos(saved[0], saved[1]);
    _showSnack('已测试 $repeat 次点击 ($x, $y) '
        '${_button == MouseButton.left ? "左键" : "右键"}  间隔${interval}ms');
  }

  void _pickCoordinate() {
    if (_picking) return;
    setState(() => _picking = true);
    _f6WasDown = isKeyDown(vkF6);
    final pos = getCursorPos();
    _xCtrl.text = pos[0].toString();
    _yCtrl.text = pos[1].toString();
    _pickTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (!_picking) return;
      final p = getCursorPos();
      _xCtrl.text = p[0].toString();
      _yCtrl.text = p[1].toString();
      final f6Down = isKeyDown(vkF6);
      if (f6Down && !_f6WasDown) {
        _f6WasDown = true;
        final latest = getCursorPos();
        _xCtrl.text = latest[0].toString();
        _yCtrl.text = latest[1].toString();
        _stopPicking();
        _showSnack('已拾取坐标 (${latest[0]}, ${latest[1]})');
        return;
      }
      if (!f6Down) _f6WasDown = false;
    });
  }

  void _stopPicking() {
    _pickTimer?.cancel();
    _pickTimer = null;
    setState(() => _picking = false);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmt(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}.${three(l.millisecond)}';
  }

  String _fmtDur(Duration d) {
    if (d.isNegative) return '00:00:00.000';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final ms = d.inMilliseconds.remainder(1000);
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(h)}:${two(m)}:${two(s)}.${three(ms)}';
  }

  @override
  Widget build(BuildContext context) {
    final running = _schedState == SchedulerState.waiting ||
        _schedState == SchedulerState.firing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NTP 自动点击器'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSyncHeader(),
            const Divider(height: 24),
            _buildTimeRow(),
            const SizedBox(height: 14),
            _buildCoordRow(),
            const SizedBox(height: 14),
            _buildOffsetRow(),
            const SizedBox(height: 14),
            _buildClickRow(),
            const SizedBox(height: 24),
            _buildActionButton(running),
            const SizedBox(height: 12),
            if (running && _remaining != null)
              Text(
                '倒计时  ${_fmtDur(_remaining!)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.deepPurple),
              ),
            if (_schedState == SchedulerState.firing && _clickTotal > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '连击  $_clickDone / $_clickTotal',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.orange),
                ),
              ),
            _buildStatus(),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncHeader() {
    final synced = _engine.isSynced;

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              synced ? _clockText : '未同步',
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Consolas'),
            ),
            const SizedBox(width: 8),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: synced ? Colors.green : Colors.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                (_syncResult != null &&
                        _syncResult!.success &&
                        _syncResult!.chosenSource != null)
                    ? '源: ${_syncResult!.chosenSource}'
                    : '源: 自动 (${kNtpServers.length} 选 1)',
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: FilledButton.icon(
                onPressed: _syncing ? null : () => _syncNow(),
                icon: _syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync, size: 16),
                label: Text(_syncing ? '同步中' : '同步'),
              ),
            ),
          ],
        ),
        if (_syncResult != null && _syncResult!.success)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '不确定度 ±${_syncResult!.uncertainty?.inMilliseconds ?? 0}ms  '
              '延迟 ${_syncResult!.bestNetDelay?.inMilliseconds ?? 0}ms  '
              '源 S${_syncResult!.chosenStratum ?? '-'}',
              style: const TextStyle(color: Colors.blue, fontSize: 12),
            ),
          )
        else if (_syncResult != null && !_syncResult!.success)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('同步失败：${_syncResult!.error}',
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _buildTimeRow() {
    return Row(
      children: [
        _label('目标'),
        const SizedBox(width: 8),
        SizedBox(
          width: 110,
          child: OutlinedButton(
            onPressed: _engine.isSynced
                ? () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date ?? DateTime.now().toLocal(),
                      firstDate: DateTime.now().toLocal(),
                      lastDate:
                          DateTime.now().toLocal().add(const Duration(days: 365)),
                    );
                    if (picked != null) {
                      setState(() {
                        _date =
                            DateTime(picked.year, picked.month, picked.day);
                      });
                    }
                  }
                : null,
            child: Text(
              _date == null ? '选择日期' : '${_date!.month}/${_date!.day}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        const SizedBox(width: 4),
        _f(_hourCtrl, width: 56),
        const Text(' : ', style: TextStyle(fontWeight: FontWeight.bold)),
        _f(_minuteCtrl, width: 56),
        const Text(' : ', style: TextStyle(fontWeight: FontWeight.bold)),
        _f(_secondCtrl, width: 56),
        const Text(' . ', style: TextStyle(fontWeight: FontWeight.bold)),
        _f(_msCtrl, width: 66),
      ],
    );
  }

  Widget _buildCoordRow() {
    return Row(
      children: [
        _label('坐标'),
        const SizedBox(width: 8),
        SizedBox(
          width: 85,
          child: TextField(
            controller: _xCtrl,
            readOnly: _picking,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'X',
              isDense: true,
              border: const OutlineInputBorder(),
              fillColor: _picking
                  ? Colors.amber.withValues(alpha: 0.2)
                  : null,
              filled: _picking,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 85,
          child: TextField(
            controller: _yCtrl,
            readOnly: _picking,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Y',
              isDense: true,
              border: const OutlineInputBorder(),
              fillColor: _picking
                  ? Colors.amber.withValues(alpha: 0.2)
                  : null,
              filled: _picking,
            ),
          ),
        ),
        const SizedBox(width: 6),
        if (_picking)
          FilledButton.icon(
            onPressed: _stopPicking,
            icon: const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white)),
            label: const Text('拾取中…F6'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: _engine.isSynced ? _pickCoordinate : null,
            icon: const Icon(Icons.my_location, size: 16),
            label: const Text('拾取'),
          ),
      ],
    );
  }

  Widget _buildOffsetRow() {
    return Row(
      children: [
        _label('偏移'),
        const SizedBox(width: 8),
        const Text('比实际时间', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        _buildEarlyToggle(),
        const SizedBox(width: 4),
        _f(_offsetCtrl, width: 56),
        const SizedBox(width: 2),
        const Text('毫秒', style: TextStyle(fontSize: 13)),
      ],
    );
  }

  Widget _buildEarlyToggle() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segEarly('早', true),
          Container(width: 1, height: 24, color: Colors.grey.shade400),
          _segEarly('晚', false),
        ],
      ),
    );
  }

  Widget _segEarly(String label, bool value) {
    final selected = _offsetEarly == value;
    return GestureDetector(
      onTap: () => setState(() => _offsetEarly = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        color: selected ? Colors.indigo.withValues(alpha: 0.12) : null,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildClickRow() {
    return Row(
      children: [
        _label('点击'),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: TextField(
            controller: _repeatCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
                isDense: true, border: OutlineInputBorder(), hintText: '1'),
          ),
        ),
        const SizedBox(width: 2),
        const Text('次', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 10),
        SizedBox(
          width: 62,
          child: TextField(
            controller: _intervalCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
                isDense: true, border: OutlineInputBorder(), hintText: '100'),
          ),
        ),
        const SizedBox(width: 2),
        const Text('ms', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 10),
        _buildButtonToggle(),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _testClick,
          icon: const Icon(Icons.flash_on, size: 16),
          label: const Text('测试'),
        ),
      ],
    );
  }

  Widget _buildButtonToggle() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg('左', MouseButton.left),
          Container(width: 1, height: 24, color: Colors.grey.shade400),
          _seg('右', MouseButton.right),
        ],
      ),
    );
  }

  Widget _seg(String label, MouseButton value) {
    final selected = _button == value;
    return GestureDetector(
      onTap: () => setState(() => _button = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        color: selected ? Colors.indigo.withValues(alpha: 0.12) : null,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(bool running) {
    return FilledButton.icon(
      onPressed: running ? _stopTask : _startTask,
      icon: Icon(running ? Icons.stop : Icons.play_arrow),
      label: Text(running ? '停止' : '启动定时点击',
          style: const TextStyle(fontSize: 16)),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        backgroundColor: running ? Colors.red : null,
      ),
    );
  }

  Widget _buildStatus() {
    switch (_schedState) {
      case SchedulerState.idle:
        return const SizedBox.shrink();
      case SchedulerState.waiting:
        return const SizedBox.shrink();
      case SchedulerState.firing:
        return const SizedBox.shrink();
      case SchedulerState.done:
        final t = _firedAt != null ? _fmt(_firedAt!) : '';
        return Text(
          '已完成  $_clickTotal 次点击    $t',
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.green, fontWeight: FontWeight.w600, fontSize: 15),
        );
      case SchedulerState.cancelled:
        return Text(
          '已取消',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        );
      case SchedulerState.error:
        return Text(
          '$_schedError',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.red, fontSize: 13),
        );
    }
  }

  Widget _label(String text) {
    return Text(text, style: const TextStyle(fontWeight: FontWeight.w500));
  }

  Widget _f(TextEditingController ctrl, {double width = 56}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        decoration: const InputDecoration(
            isDense: true, border: OutlineInputBorder()),
      ),
    );
  }
}
