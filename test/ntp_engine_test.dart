import 'dart:io';
import 'dart:typed_data';

import 'package:autoclick/services/ntp_time_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ntpToDateTime', () {
    test('当前 era（2026）', () {
      // 2026-01-01 00:00:00 UTC 的 NTP 秒
      const secs = 3976214400;
      final dt = NtpTimeEngine.ntpToDateTime(secs, 0);
      expect(dt.year, 2026);
      expect(dt.month, 1);
      expect(dt.day, 1);
    });

    test('2036 era 翻转处理', () {
      // 小于 ntpToUnixSecs 的秒数 → 触发 +2^32 → 落在 2036 年之后
      const secs = 100;
      final dt = NtpTimeEngine.ntpToDateTime(secs, 0);
      expect(dt.year, greaterThanOrEqualTo(2036));
    });

    test('小数部分（fraction）携带亚秒信息', () {
      const secs = 3976214400;
      const frac = 1 << 31; // 0.5 秒
      final dt = NtpTimeEngine.ntpToDateTime(secs, frac);
      expect(dt.year, 2026);
      expect(dt.millisecond, 500);
    });
  });

  group('fitFreq（频率纪律）', () {
    test('斜率 1.0', () {
      final List<({int sw, int serverMicros})> h = [
        (sw: 0, serverMicros: 0),
        (sw: 1000000, serverMicros: 1000000),
      ];
      expect(NtpTimeEngine.fitFreq(h), closeTo(1.0, 1e-9));
    });

    test('斜率 1.5（Stopwatch 偏慢）', () {
      final List<({int sw, int serverMicros})> h = [
        (sw: 0, serverMicros: 0),
        (sw: 1000, serverMicros: 1500),
      ];
      expect(NtpTimeEngine.fitFreq(h), closeTo(1.5, 1e-9));
    });

    test('单点返回 null', () {
      expect(NtpTimeEngine.fitFreq([(sw: 0, serverMicros: 0)]), isNull);
    });

    test('sw 全相同返回 null（除零保护）', () {
      final List<({int sw, int serverMicros})> h = [
        (sw: 5, serverMicros: 0),
        (sw: 5, serverMicros: 100),
      ];
      expect(NtpTimeEngine.fitFreq(h), isNull);
    });
  });

  group('marzullo（多源选择）', () {
    test('取最大重叠集，剔除 falseticker', () {
      final engine = NtpTimeEngine();
      final a = _sample(offset: 0, halfWidth: 5000, host: 'A');
      final b = _sample(offset: 1000, halfWidth: 5000, host: 'B');
      final c = _sample(offset: 100000, halfWidth: 5000, host: 'C'); // falseticker
      final (chosen, hw) = engine.marzullo([a, b, c]);
      expect(chosen.host, 'A'); // A、B 重叠且并列最窄，取下标最小
      expect(hw, lessThanOrEqualTo(5000));
      expect(chosen.host, isNot('C'));
    });

    test('全部一致时取最窄区间', () {
      final engine = NtpTimeEngine();
      final a = _sample(offset: 0, halfWidth: 10000, host: 'A');
      final b = _sample(offset: 0, halfWidth: 3000, host: 'B');
      final c = _sample(offset: 0, halfWidth: 5000, host: 'C');
      final (chosen, _) = engine.marzullo([a, b, c]);
      expect(chosen.host, 'B'); // h 最小
    });

    test('单源直接采用', () {
      final engine = NtpTimeEngine();
      final a = _sample(offset: 0, halfWidth: 5000, host: 'A');
      final (chosen, hw) = engine.marzullo([a]);
      expect(chosen.host, 'A');
      expect(hw, 5000);
    });
  });

  group('parseResponse（响应校验）', () {
    final now = DateTime.now().toUtc();

    test('合法服务器响应', () {
      final data = _craftResponse(t2: now, t3: now, stratum: 1);
      final engine = NtpTimeEngine();
      final s = engine.parseResponse(data, 1000, 2000, 'mock');
      expect(s, isNotNull);
      expect(s!.host, 'mock');
      expect(s.stratum, 1);
      expect(s.swSendMicros, 1000);
      expect(s.swRecvMicros, 2000);
      expect(s.isValid, isTrue);
      expect(s.netDelay.inMicroseconds, 1000); // roundTrip=1000, serverProc=0
    });

    test('拒绝 Kiss-o-Death（stratum=0）', () {
      final data = _craftResponse(t2: now, t3: now, stratum: 0);
      expect(NtpTimeEngine().parseResponse(data, 0, 100, 'm'), isNull);
    });

    test('拒绝未同步（stratum=16）', () {
      final data = _craftResponse(t2: now, t3: now, stratum: 16);
      expect(NtpTimeEngine().parseResponse(data, 0, 100, 'm'), isNull);
    });

    test('拒绝非服务器 mode', () {
      final data = _craftResponse(t2: now, t3: now, stratum: 1, mode: 3);
      expect(NtpTimeEngine().parseResponse(data, 0, 100, 'm'), isNull);
    });

    test('拒绝 leap 告警（LI=3）', () {
      final data = _craftResponse(t2: now, t3: now, stratum: 1, leap: 3);
      expect(NtpTimeEngine().parseResponse(data, 0, 100, 'm'), isNull);
    });

    test('拒绝 T2/T3 全零', () {
      final data = _rawResponse(stratum: 1); // t2sec=t3sec=0
      expect(NtpTimeEngine().parseResponse(data, 0, 100, 'm'), isNull);
    });

    test('拒绝负 netDelay（serverProc > roundTrip）', () {
      final t3 = now.add(const Duration(milliseconds: 50)); // serverProc=50ms
      final data = _craftResponse(t2: now, t3: t3, stratum: 1);
      // roundTrip = 100us < serverProc 50ms → netDelay 负 → null
      expect(NtpTimeEngine().parseResponse(data, 0, 100, 'm'), isNull);
    });

    test('小于 48 字节拒绝', () {
      expect(NtpTimeEngine().parseResponse(Uint8List(40), 0, 100, 'm'), isNull);
    });
  });

  group('queryOnceDirect（端到端锚点配对）', () {
    // 该测试直接验证 Bug#1 修复：样本必须携带 swRecvMicros，
    // 且 serverTimeAtRecv 与 swRecvMicros 时刻一致。
    test('mock NTP 服务器返回配对样本', () async {
      final server = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final sub = server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = server.receive();
        if (dg == null) return;
        final t = DateTime.now().toUtc();
        final resp = _craftResponse(t2: t, t3: t, stratum: 1);
        server.send(resp, dg.address, dg.port);
      });

      final engine = NtpTimeEngine();
      try {
        final sample = await engine.queryOnceDirect(
          InternetAddress.loopbackIPv4,
          port: port,
          hostLabel: 'mock',
        );
        expect(sample, isNotNull);
        expect(sample!.isValid, isTrue);
        expect(sample.host, 'mock');
        expect(sample.stratum, 1);
        // 锚点配对关键：swRecv > swSend，且 serverTimeAtRecv ≈ 收包真实时刻
        expect(sample.swRecvMicros, greaterThan(sample.swSendMicros));
        final diff = sample.serverTimeAtRecv
            .difference(DateTime.now().toUtc())
            .inMilliseconds
            .abs();
        expect(diff, lessThan(1000));
      } finally {
        await sub.cancel();
        server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

/// 构造指定 offset（微秒，相对 Stopwatch）与 halfWidth（微秒）的样本。
/// offsetMicros getter = serverTimeAtRecvMicros - swRecvMicros
/// halfWidthMicros getter = netDelay/2（rootDisp=rootDelay=0）
NtpSample _sample({
  required int offset,
  required int halfWidth,
  String host = 'h',
  int stratum = 1,
}) {
  final H = halfWidth;
  final netDelayUs = 2 * H;
  // swRecv = 2H, swSend = 0 → roundTrip = 2H = netDelay（serverProc=0）
  // t3.micros = offset + H → serverTimeAtRecvMicros = offset + 2H → offsetMicros = offset
  final t3 = DateTime.fromMicrosecondsSinceEpoch(offset + H, isUtc: true);
  return NtpSample(
    host: host,
    swSendMicros: 0,
    swRecvMicros: netDelayUs,
    t2: t3,
    t3: t3,
    roundTrip: Duration(microseconds: netDelayUs),
    netDelay: Duration(microseconds: netDelayUs),
    stratum: stratum,
    rootDelay: Duration.zero,
    rootDispersion: Duration.zero,
  );
}

/// 用真实 DateTime 构造 NTP 响应包（当前 era）。
Uint8List _craftResponse({
  required DateTime t2,
  required DateTime t3,
  int stratum = 1,
  int mode = 4,
  int leap = 0,
  int version = 3,
}) {
  final data = Uint8List(48);
  data[0] = (leap << 6) | (version << 3) | mode;
  data[1] = stratum;
  final buf = ByteData.sublistView(data);
  _writeNtpTs(buf, 32, t2);
  _writeNtpTs(buf, 40, t3);
  return data;
}

/// 用原始整数字段构造 NTP 响应包（用于边界用例）。
Uint8List _rawResponse({
  int b0 = 0x1C, // LI=0, VN=3, Mode=4
  int stratum = 1,
  int t2sec = 0,
  int t2frac = 0,
  int t3sec = 0,
  int t3frac = 0,
}) {
  final data = Uint8List(48);
  data[0] = b0;
  data[1] = stratum;
  final buf = ByteData.sublistView(data);
  buf.setUint32(32, t2sec, Endian.big);
  buf.setUint32(36, t2frac, Endian.big);
  buf.setUint32(40, t3sec, Endian.big);
  buf.setUint32(44, t3frac, Endian.big);
  return data;
}

void _writeNtpTs(ByteData buf, int off, DateTime dt) {
  const ntpToUnixSecs = 2208988800;
  final unixMicros = dt.toUtc().microsecondsSinceEpoch;
  final totalSec = (unixMicros / 1000000.0) + ntpToUnixSecs;
  final sec = totalSec.floor();
  final frac = ((totalSec - sec) * 4294967296.0).round();
  buf.setUint32(off, sec, Endian.big);
  buf.setUint32(off + 4, frac, Endian.big);
}
