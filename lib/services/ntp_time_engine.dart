import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// NTP 服务器列表（用户在 UI 中选择其一）
class NtpServer {
  final String host;
  final String label;
  const NtpServer(this.host, this.label);
}

const List<NtpServer> kNtpServers = [
  NtpServer('ntp.aliyun.com', 'ntp.aliyun.com (阿里云)'),
  NtpServer('ntp1.aliyun.com', 'ntp1.aliyun.com (阿里云)'),
  NtpServer('cn.ntp.org.cn', 'cn.ntp.org.cn (中国)'),
];

/// 单次 NTP 请求的原始计时结果
class _NtpSample {
  final Duration netRtt; // 纯网络往返（已扣除服务器处理时间）
  final DateTime serverTimeAtRecv; // 收包瞬间的服务器绝对时间 = T3 + halfNet
  final Duration serverProc; // 服务器处理耗时 T3-T2
  _NtpSample(this.netRtt, this.serverTimeAtRecv, this.serverProc);
}

/// 一次同步的详细结果
class SyncResult {
  final String serverHost;
  final bool success;
  final DateTime? anchorTime; // 收包瞬间的服务器绝对时间（锚点）
  final Duration? bestRtt;
  final List<Duration> allNetRtts; // 3 次请求各自的纯网络往返
  final List<Duration> serverProcs; // 3 次各自的服务器处理耗时
  final String? error;
  SyncResult({
    required this.serverHost,
    required this.success,
    this.anchorTime,
    this.bestRtt,
    required this.allNetRtts,
    required this.serverProcs,
    this.error,
  });
}

/// NTP 时间引擎
///
/// 绝对时间只来自 NTP 服务器的 T2/T3 时间戳；
/// 本地 Stopwatch（底层 QueryPerformanceCounter 单调计数器）仅用于测量
/// 经过时长以推进时间，绝不读取本地计算机时钟作为时间源。
///
/// 程序标准时间 = anchorTime + (Stopwatch.elapsed - anchorSw)
class NtpTimeEngine {
  static const int _ntpPort = 123;
  static const int _timeoutSec = 4;

  final Stopwatch _sw = Stopwatch()..start();

  DateTime? _anchorTime; // 收包瞬间的服务器绝对 UTC 时间
  int _anchorSwMicros = 0; // 收包瞬间的 Stopwatch 微秒读数
  bool _synced = false;

  bool get isSynced => _synced;
  DateTime? get anchorTime => _anchorTime;

  /// 当前程序标准时间（绝对时间，源自服务器；用 Stopwatch 时长推进）
  DateTime now() {
    if (!_synced || _anchorTime == null) {
      throw StateError('NTP 尚未同步');
    }
    final elapsed = _sw.elapsedMicroseconds - _anchorSwMicros;
    return _anchorTime!.add(Duration(microseconds: elapsed));
  }

  /// 当前 Stopwatch 微秒读数（供调度器换算目标时刻用）
  int swMicros() => _sw.elapsedMicroseconds;

  /// 将目标服务器绝对时间换算为 Stopwatch 目标读数（微秒）
  int targetToSwMicros(DateTime target) {
    if (!_synced || _anchorTime == null) {
      throw StateError('NTP 尚未同步');
    }
    final delta = target.difference(_anchorTime!);
    return _anchorSwMicros + delta.inMicroseconds;
  }

  /// 请求 5 次，剔除最高 RTT 的离群值，取最优为锚点。
  /// 若最优 RTT > 80ms 则拒绝本次同步。
  Future<SyncResult> synchronize(String host) async {
    final samples = <_NtpSample>[];
    final errors = <String>[];

    for (var i = 0; i < 5; i++) {
      try {
        final s = await _queryOnce(host);
        if (s != null) {
          samples.add(s);
        } else {
          errors.add('第${i + 1}次: 无响应');
        }
      } catch (e) {
        errors.add('第${i + 1}次: $e');
      }
    }

    if (samples.isEmpty) {
      return SyncResult(
        serverHost: host,
        success: false,
        allNetRtts: const [],
        serverProcs: const [],
        error: errors.isEmpty ? '5 次请求均失败' : errors.join(' | '),
      );
    }

    // 按 RTT 排序，剔除最大的（最多去掉 2 个离群值）
    samples.sort((a, b) => a.netRtt.compareTo(b.netRtt));
    while (samples.length > 3) {
      samples.removeLast();
    }
    final best = samples.first;

    // 质量门控：最佳 RTT > 80ms 说明网络状况差，拒绝本次同步
    if (best.netRtt > const Duration(milliseconds: 80)) {
      return SyncResult(
        serverHost: host,
        success: false,
        allNetRtts: samples.map((s) => s.netRtt).toList(),
        serverProcs: samples.map((s) => s.serverProc).toList(),
        error: '网络延迟过高 (最佳 ${best.netRtt.inMilliseconds}ms)，请重试或切换服务器',
      );
    }

    _anchorTime = best.serverTimeAtRecv;
    _anchorSwMicros = _sw.elapsedMicroseconds;
    _synced = true;

    return SyncResult(
      serverHost: host,
      success: true,
      anchorTime: best.serverTimeAtRecv,
      bestRtt: best.netRtt,
      allNetRtts: samples.map((s) => s.netRtt).toList(),
      serverProcs: samples.map((s) => s.serverProc).toList(),
    );
  }

  /// 单次 NTP 查询。返回 [_NtpSample]，失败返回 null。
  Future<_NtpSample?> _queryOnce(String host) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final sock = socket;

      // 解析域名为 IP（Windows 上 InternetAddress(host) 对域名解析不可靠）
      final lookup = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
      if (lookup.isEmpty) {
        throw SocketException('无法解析主机名: $host');
      }
      final serverAddr = lookup.first;

      // 构造 48 字节 NTPv3 请求包：byte[0]=0x1B (LI=0, VN=3, Mode=3)
      final req = Uint8List(48);
      req[0] = 0x1B;

      // tSend：发包瞬间的 Stopwatch 读数
      final sw = _sw.elapsedMicroseconds;
      sock.send(req, serverAddr, _ntpPort);

      // 收包结果：(数据报, 收包瞬间Stopwatch读数)
      final completer = Completer<(Datagram, int)>();
      Timer? timer;
      late StreamSubscription sub;
      sub = sock.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null && !completer.isCompleted) {
            // 收包瞬间立即记录 Stopwatch 读数，消除事件循环调度延迟
            final swRecv = _sw.elapsedMicroseconds;
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

      timer = Timer(const Duration(seconds: _timeoutSec), () {
        if (!completer.isCompleted) {
          sub.cancel();
          completer.completeError(TimeoutException('NTP 请求超时'));
        }
      });

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

      if (dg.data.length < 48) return null;

      final buf = ByteData.sublistView(dg.data);
      // T2（服务器收到时刻）= bytes[32..39]
      final t2Sec = buf.getUint32(32, Endian.big);
      final t2Frac = buf.getUint32(36, Endian.big);
      // T3（服务器发出时刻）= bytes[40..47]
      final t3Sec = buf.getUint32(40, Endian.big);
      final t3Frac = buf.getUint32(44, Endian.big);

      if (t2Sec == 0 && t3Sec == 0) return null;

      final t2 = _ntpToDateTime(t2Sec, t2Frac);
      final t3 = _ntpToDateTime(t3Sec, t3Frac);
      final serverProc = t3.difference(t2);

      // 纯网络往返 = 收发 Stopwatch 时长 - 服务器处理耗时
      final totalRtt = Duration(microseconds: swRecv - sw);
      final netRtt = totalRtt - serverProc;
      final halfNet = Duration(microseconds: netRtt.inMicroseconds ~/ 2);

      // 收包瞬间的服务器绝对时间 = T3 + halfNet
      final serverTimeAtRecv = t3.add(halfNet);

      return _NtpSample(
        netRtt.isNegative ? Duration.zero : netRtt,
        serverTimeAtRecv,
        serverProc,
      );
    } finally {
      socket?.close();
    }
  }

  /// NTP 时间戳（1900 起的秒 + 32 位小数）→ DateTime(UTC)，微秒精度
  DateTime _ntpToDateTime(int seconds, int fraction) {
    const ntpToUnixSecs = 2208988800; // 1900-01-01 → 1970-01-01 的秒数
    final unixMicros = (seconds - ntpToUnixSecs) * 1000000 + (fraction * 1000000 ~/ 4294967296);
    return DateTime.fromMicrosecondsSinceEpoch(unixMicros, isUtc: true);
  }
}
