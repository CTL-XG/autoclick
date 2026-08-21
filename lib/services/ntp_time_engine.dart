import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// NTP 服务器（源池）
class NtpServer {
  final String host;
  final String label;
  const NtpServer(this.host, this.label);
}

/// 源池：stratum-1 为主 + 国内 stratum-2 快源
const List<NtpServer> kNtpServers = [
  NtpServer('time.cloudflare.com', 'Cloudflare (S1)'),
  NtpServer('time.google.com', 'Google (S1)'),
  NtpServer('time.apple.com', 'Apple (S1)'),
  NtpServer('ntp.aliyun.com', '阿里云 (S2)'),
  NtpServer('cn.pool.ntp.org', 'NTP Pool CN'),
  NtpServer('time.windows.com', 'Windows (S2)'),
];

/// 单次 NTP 请求结果（携带 swRecv，修复锚点配对 bug）
class NtpSample {
  final String host;
  final int swSendMicros; // T1：发包瞬间 Stopwatch 读数
  final int swRecvMicros; // T4：收包瞬间 Stopwatch 读数（锚点配对关键）
  final DateTime t2; // 服务器收到时刻
  final DateTime t3; // 服务器发出时刻
  final Duration roundTrip; // T4 - T1
  final Duration netDelay; // roundTrip - (T3 - T2)
  final int stratum;
  final Duration rootDelay;
  final Duration rootDispersion;

  NtpSample({
    required this.host,
    required this.swSendMicros,
    required this.swRecvMicros,
    required this.t2,
    required this.t3,
    required this.roundTrip,
    required this.netDelay,
    required this.stratum,
    required this.rootDelay,
    required this.rootDispersion,
  });

  bool get isValid => stratum >= 1 && stratum <= 15 && !netDelay.isNegative;

  Duration get halfNet => Duration(microseconds: netDelay.inMicroseconds ~/ 2);

  /// 收包瞬间的服务器绝对 UTC 时间 = T3 + halfNet
  DateTime get serverTimeAtRecv => t3.add(halfNet);

  int get serverTimeAtRecvMicros => serverTimeAtRecv.microsecondsSinceEpoch;

  /// offset = 服务器时间 - Stopwatch 读数（微秒）
  int get offsetMicros => serverTimeAtRecvMicros - swRecvMicros;

  /// 不确定区间半宽（微秒）：netDelay/2 + rootDispersion + rootDelay/2
  int get halfWidthMicros {
    final hw = netDelay.inMicroseconds ~/ 2 +
        rootDispersion.inMicroseconds +
        rootDelay.inMicroseconds ~/ 2;
    return hw < 1000 ? 1000 : hw;
  }
}

/// 一次同步的详细结果
class SyncResult {
  final bool success;
  final String? chosenSource;
  final int? chosenStratum;
  final DateTime? anchorTime;
  final Duration? uncertainty; // 半宽
  final Duration? bestNetDelay;
  final int serversTried;
  final int serversOK;
  final Map<String, Duration> perServerBestDelay;
  final double? freqCorrection;
  final String? error;

  SyncResult({
    required this.success,
    this.chosenSource,
    this.chosenStratum,
    this.anchorTime,
    this.uncertainty,
    this.bestNetDelay,
    required this.serversTried,
    required this.serversOK,
    required this.perServerBestDelay,
    this.freqCorrection,
    this.error,
  });
}

/// NTP 时间引擎
///
/// 算法移植自 ntpd/chronyd：
/// - 时钟过滤器：每源多样本取最小 netDelay（Cristian + min-RTT）
/// - Marzullo 交集：多源区间找最大重叠集，剔 falseticker，取最窄区间
/// - PLL/FLL 频率纪律：历史锚点最小二乘拟合 QPC 频率，修正长期漂移
///
/// 绝对时间只来自 NTP 服务器 T2/T3；本地 Stopwatch(QPC) 仅测量经过时长。
/// 程序标准时间 = anchorTime + (Stopwatch.elapsed - anchorSw) * freq
///
/// 同步策略：仅启动时自动同步一次 + 用户点「同步」按钮；无周期后台重同步。
class NtpTimeEngine {
  static const int _ntpPort = 123;
  static const int _queryTimeoutSec = 1;
  static const int _samplesPerServer = 8;
  static const int _serverDeadlineSec = 8;
  static const int _minConsensusServers = 4;
  static const int _maxHistory = 16;
  static const int _jumpThresholdMicros = 200000; // 200ms
  static const Duration _qualityGateRtt = Duration(milliseconds: 80);
  static const int _ntpToUnixSecs = 2208988800; // 1900-01-01 → 1970-01-01

  final Stopwatch _sw = Stopwatch()..start();

  DateTime? _anchorTime;
  int _anchorSwMicros = 0;
  double _freq = 1.0;
  bool _synced = false;
  bool _syncing = false;
  SyncResult? _lastResult;

  final List<({int sw, int serverMicros})> _history = [];

  NtpTimeEngine();

  bool get isSynced => _synced;
  DateTime? get anchorTime => _anchorTime;
  SyncResult? get lastResult => _lastResult;
  double get freq => _freq;

  DateTime now() {
    if (!_synced || _anchorTime == null) {
      throw StateError('NTP 尚未同步');
    }
    final elapsed = (_sw.elapsedMicroseconds - _anchorSwMicros) * _freq;
    return _anchorTime!.add(Duration(microseconds: elapsed.round()));
  }

  int swMicros() => _sw.elapsedMicroseconds;

  int targetToSwMicros(DateTime target) {
    if (!_synced || _anchorTime == null) {
      throw StateError('NTP 尚未同步');
    }
    final deltaUs = target.difference(_anchorTime!).inMicroseconds;
    return _anchorSwMicros + (deltaUs / _freq).round();
  }

  Future<SyncResult> synchronize() async {
    if (_syncing) {
      return _lastResult ??
          SyncResult(
            success: false,
            serversTried: 0,
            serversOK: 0,
            perServerBestDelay: const {},
            error: '同步进行中',
          );
    }
    return _synchronizeInternal();
  }

  Future<SyncResult> _synchronizeInternal() async {
    _syncing = true;
    final perServerBest = <String, Duration>{};
    try {
      final n = kNtpServers.length;
      final results = List<NtpSample?>.filled(n, null);
      final done = Completer<void>();
      var completed = 0;
      var nonNull = 0;
      for (var i = 0; i < n; i++) {
        final idx = i;
        _queryServer(kNtpServers[i].host)
            .timeout(const Duration(seconds: _serverDeadlineSec),
                onTimeout: () => null)
            .then((r) {
          results[idx] = r;
          completed++;
          if (r != null) nonNull++;
          if (!done.isCompleted &&
              (nonNull >= _minConsensusServers || completed == n)) {
            done.complete();
          }
        });
      }
      await done.future;

      final candidates = <NtpSample>[];
      for (var i = 0; i < n; i++) {
        final r = results[i];
        if (r != null) {
          candidates.add(r);
          perServerBest[kNtpServers[i].host] = r.netDelay;
        }
      }

      if (candidates.isEmpty) {
        _lastResult = SyncResult(
          success: false,
          serversTried: kNtpServers.length,
          serversOK: 0,
          perServerBestDelay: perServerBest,
          error: '所有 NTP 源均失败，请检查网络',
        );
        return _lastResult!;
      }

      final (chosen, halfWidth) = candidates.length == 1
          ? (candidates.first, candidates.first.halfWidthMicros)
          : marzullo(candidates);

      if (chosen.netDelay > _qualityGateRtt) {
        _lastResult = SyncResult(
          success: false,
          serversTried: kNtpServers.length,
          serversOK: candidates.length,
          perServerBestDelay: perServerBest,
          chosenSource: chosen.host,
          bestNetDelay: chosen.netDelay,
          error: '网络延迟过高 (${chosen.netDelay.inMilliseconds}ms)，请重试',
        );
        return _lastResult!;
      }

      final applied = _applyResult(chosen, halfWidth);
      if (!applied) {
        _lastResult = SyncResult(
          success: false,
          serversTried: kNtpServers.length,
          serversOK: candidates.length,
          perServerBestDelay: perServerBest,
          chosenSource: chosen.host,
          error: '锚点时间不合理，已拒绝本次同步',
        );
        return _lastResult!;
      }

      _lastResult = SyncResult(
        success: true,
        chosenSource: chosen.host,
        chosenStratum: chosen.stratum,
        anchorTime: chosen.serverTimeAtRecv,
        uncertainty: Duration(microseconds: halfWidth),
        bestNetDelay: chosen.netDelay,
        serversTried: kNtpServers.length,
        serversOK: candidates.length,
        perServerBestDelay: perServerBest,
        freqCorrection: _freq,
      );
      return _lastResult!;
    } finally {
      _syncing = false;
    }
  }

  /// 应用选中样本为锚点；更新频率纪律。返回 false 表示锚点不合理已拒绝。
  bool _applyResult(NtpSample chosen, int halfWidthMicros) {
    final anchorDt = chosen.serverTimeAtRecv;
    if (anchorDt.year < 2000 || anchorDt.year > 2100) {
      return false;
    }

    final serverMicros = chosen.serverTimeAtRecvMicros;
    final sw = chosen.swRecvMicros;

    // 时钟跳变检测：新锚 vs 旧锚外推偏差 > 200ms → 清空历史，重置 freq
    if (_anchorTime != null) {
      final extrapolated = _anchorTime!.microsecondsSinceEpoch +
          ((sw - _anchorSwMicros) * _freq).round();
      final diff = (serverMicros - extrapolated).abs();
      if (diff > _jumpThresholdMicros) {
        _history.clear();
        _freq = 1.0;
      }
    }

    _history.add((sw: sw, serverMicros: serverMicros));
    if (_history.length > _maxHistory) {
      _history.removeRange(0, _history.length - _maxHistory);
    }

    final f = fitFreq(_history);
    if (f != null && f.isFinite && f > 0.5 && f < 2.0) {
      _freq = f;
    }

    _anchorTime = anchorDt;
    _anchorSwMicros = sw;
    _synced = true;
    return true;
  }

  /// 最小二乘拟合频率 b（real-us per stopwatch-us）。数据做中心化避免大数精度损失。
  @visibleForTesting
  static double? fitFreq(List<({int sw, int serverMicros})> h) {
    final n = h.length;
    if (n < 2) return null;
    final baseSw = h.first.sw;
    final baseServer = h.first.serverMicros;
    double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
    for (final p in h) {
      final x = (p.sw - baseSw).toDouble();
      final y = (p.serverMicros - baseServer).toDouble();
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumXX += x * x;
    }
    final denom = n * sumXX - sumX * sumX;
    if (denom == 0) return null;
    return (n * sumXY - sumX * sumY) / denom;
  }

  /// Marzullo 交集算法：找最大重叠区间集，取其中最窄区间的样本。
  @visibleForTesting
  (NtpSample, int) marzullo(List<NtpSample> candidates) {
    final eps = <({int val, int delta, int idx})>[];
    for (var i = 0; i < candidates.length; i++) {
      final o = candidates[i].offsetMicros;
      final h = candidates[i].halfWidthMicros;
      eps.add((val: o - h, delta: 1, idx: i));
      eps.add((val: o + h, delta: -1, idx: i));
    }
    eps.sort((a, b) {
      final c = a.val.compareTo(b.val);
      if (c != 0) return c;
      return b.delta.compareTo(a.delta); // 同值 +1 先于 -1
    });

    int count = 0, bestCount = 0;
    final active = <int>{};
    Set<int> bestActive = const <int>{};
    for (final e in eps) {
      if (e.delta > 0) {
        active.add(e.idx);
      } else {
        active.remove(e.idx);
      }
      count += e.delta;
      if (count > bestCount) {
        bestCount = count;
        bestActive = {...active};
      }
    }

    int chosenIdx = 0;
    int chosenH = 1 << 62;
    for (var i = 0; i < candidates.length; i++) {
      if (bestActive.contains(i) && candidates[i].halfWidthMicros < chosenH) {
        chosenH = candidates[i].halfWidthMicros;
        chosenIdx = i;
      }
    }
    return (candidates[chosenIdx], chosenH);
  }

  /// 单源并发突发采样，取最小 netDelay（时钟过滤器）。
  /// 8 个样本并发发出，整体耗时 ≈ 1 个 RTT（快源）/ 1s 超时（死源），
  /// 不再串行等待，提速同时 min-RTT 滤波仍有效。
  Future<NtpSample?> _queryServer(String host) async {
    final lookup =
        await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
    if (lookup.isEmpty) return null;
    final addr = lookup.first;
    final futures = List<Future<NtpSample?>>.generate(
      _samplesPerServer,
      (_) async {
        try {
          return await queryOnceDirect(addr, hostLabel: host);
        } catch (_) {
          return null;
        }
      },
    );
    final raw = await Future.wait(futures);
    final samples =
        raw.whereType<NtpSample>().where((s) => s.isValid).toList();
    if (samples.length < 3) return null;
    samples.sort((a, b) => a.netDelay.compareTo(b.netDelay));
    return samples.first;
  }

  @visibleForTesting
  Future<NtpSample?> queryOnceDirect(InternetAddress serverAddr,
      {int port = _ntpPort, String hostLabel = 'direct'}) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final sock = socket;

      final req = Uint8List(48);
      req[0] = 0x1B; // LI=0, VN=3, Mode=3(client)

      final completer = Completer<(Datagram, int)>();
      Timer? timer;
      late StreamSubscription sub;
      sub = sock.listen((event) {
        if (event == RawSocketEvent.read) {
          // 先抓 swRecv，再 receive()，省掉系统调用开销
          final swRecv = _sw.elapsedMicroseconds;
          final dg = sock.receive();
          if (dg != null && !completer.isCompleted) {
            timer?.cancel();
            completer.complete((dg, swRecv));
          }
        }
      }, onError: (e) {
        if (!completer.isCompleted) {
          timer?.cancel();
          completer.completeError(e);
        }
      });

      timer = Timer(const Duration(seconds: _queryTimeoutSec), () {
        if (!completer.isCompleted) {
          sub.cancel();
          completer.completeError(TimeoutException('NTP 请求超时'));
        }
      });

      final swSend = _sw.elapsedMicroseconds;
      sock.send(req, serverAddr, port);

      Datagram dg;
      int swRecv;
      try {
        final result = await completer.future;
        dg = result.$1;
        swRecv = result.$2;
      } catch (_) {
        return null;
      } finally {
        sub.cancel();
        timer.cancel();
      }

      return parseResponse(dg.data, swSend, swRecv, hostLabel);
    } finally {
      socket?.close();
    }
  }

  @visibleForTesting
  NtpSample? parseResponse(
      Uint8List data, int swSend, int swRecv, String host) {
    if (data.length < 48) return null;
    final buf = ByteData.sublistView(data);

    final b0 = buf.getUint8(0);
    final mode = b0 & 0x07;
    final leap = (b0 >> 6) & 0x03;
    if (mode != 4) return null; // 非服务器响应
    if (leap == 3) return null; // 告警：时钟未同步

    final stratum = buf.getUint8(1);
    if (stratum < 1 || stratum > 15) return null; // 拒 Kiss-o'-Death(0) & 未同步(16+)

    final rootDelayUs = _readFixedSigned(buf, 4);
    final rootDispUs = _readFixedUnsigned(buf, 8);

    final t2Sec = buf.getUint32(32, Endian.big);
    final t2Frac = buf.getUint32(36, Endian.big);
    final t3Sec = buf.getUint32(40, Endian.big);
    final t3Frac = buf.getUint32(44, Endian.big);
    if (t2Sec == 0 || t3Sec == 0) return null;

    final t2 = ntpToDateTime(t2Sec, t2Frac);
    final t3 = ntpToDateTime(t3Sec, t3Frac);
    final serverProc = t3.difference(t2);
    final roundTrip = Duration(microseconds: swRecv - swSend);
    final netDelay = roundTrip - serverProc;
    if (netDelay.isNegative) return null;

    return NtpSample(
      host: host,
      swSendMicros: swSend,
      swRecvMicros: swRecv,
      t2: t2,
      t3: t3,
      roundTrip: roundTrip,
      netDelay: netDelay,
      stratum: stratum,
      rootDelay: Duration(microseconds: rootDelayUs),
      rootDispersion: Duration(microseconds: rootDispUs),
    );
  }

  /// 16.16 有符号定点秒 → 微秒
  int _readFixedSigned(ByteData buf, int off) {
    final raw = buf.getInt32(off, Endian.big);
    return (raw * 1000000) ~/ 65536;
  }

  /// 16.16 无符号定点秒 → 微秒
  int _readFixedUnsigned(ByteData buf, int off) {
    final raw = buf.getUint32(off, Endian.big);
    return (raw * 1000000) ~/ 65536;
  }

  /// NTP 时间戳（1900 起的秒 + 32 位小数）→ DateTime(UTC)，微秒精度
  @visibleForTesting
  static DateTime ntpToDateTime(int seconds, int fraction) {
    if (seconds < _ntpToUnixSecs) {
      seconds += (1 << 32); // 2036 era 翻转处理
    }
    final unixMicros = (seconds - _ntpToUnixSecs) * 1000000 +
        (fraction * 1000000 ~/ 4294967296);
    return DateTime.fromMicrosecondsSinceEpoch(unixMicros, isUtc: true);
  }
}
