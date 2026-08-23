import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// EP0 register BYTE offsets. The EP0 block is the second 512-byte page
// (address bit 9 set), and each register is its own 8-byte slot.
const _ep0Ctrl = 0x200;
const _ep0TxData = 0x218;
const _ep0TxLen = 0x228;
const _ep0RxLen = 0x280;
const _ep0RxData = 0x288;
const _hostToken = 0x300;
const _hostStatus = 0x308;

// Global register BYTE offsets.
const _ctrl = 0x00;
const _status = 0x08;
const _intStatus = 0x18;

// USB CRC16: reflected poly 0xA001, init 0xFFFF, processed LSB first per byte.
int _crc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    for (var i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final xorIn = (crc & 1) ^ bit;
      crc >>= 1;
      if (xorIn != 0) crc ^= 0xA001;
    }
  }
  return (~crc) & 0xFFFF;
}

// USB CRC5: reflected poly 0x14, init 0x1F, over `nbits` bits LSB first.
int _crc5(int data, int nbits) {
  var crc = 0x1F;
  for (var i = 0; i < nbits; i++) {
    final bit = (data >> i) & 1;
    final xorIn = (crc & 1) ^ bit;
    crc >>= 1;
    if (xorIn != 0) crc ^= 0x14;
  }
  return (~crc) & 0x1F;
}

// Builds the two token bytes for addr/endp (11 data bits + CRC5).
List<int> _token(int addr, int endp) {
  final field = (addr & 0x7F) | ((endp & 0xF) << 7);
  final v = field | (_crc5(field, 11) << 11);
  return [v & 0xFF, (v >> 8) & 0xFF];
}

// Encodes a packet (PID byte + body, SYNC prepended here) into line symbols
// with bit stuffing, NRZI and an EOP. Each entry is [dp, dm].
List<List<int>> _encode(List<int> bytes) {
  final raw = <int>[];
  for (final b in [0x80, ...bytes]) {
    for (var i = 0; i < 8; i++) {
      raw.add((b >> i) & 1);
    }
  }
  final stuffed = <int>[];
  var ones = 0;
  for (final bit in raw) {
    stuffed.add(bit);
    if (bit == 1) {
      ones++;
      if (ones == 6) {
        stuffed.add(0);
        ones = 0;
      }
    } else {
      ones = 0;
    }
  }
  final out = <List<int>>[];
  var line = 1; // idle J
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line;
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  out.add([0, 0]); // EOP SE0
  out.add([0, 0]); // EOP SE0
  out.add([1, 0]); // J
  return out;
}

// PID byte from a 4-bit PID nibble.
int _pid(int nibble) => (nibble & 0xF) | ((~nibble & 0xF) << 4);

// Decodes captured J/K symbols (0=K, 1=J) into bytes including the SYNC byte.
List<int> _decode(List<int> symbols) {
  final raw = <int>[];
  var prev = 1; // idle J
  for (final s in symbols) {
    raw.add(s == prev ? 1 : 0);
    prev = s;
  }
  final bits = <int>[];
  var ones = 0;
  for (final b in raw) {
    if (ones == 6) {
      ones = 0;
      continue;
    }
    bits.add(b);
    ones = (b == 1) ? ones + 1 : 0;
  }
  final bytes = <int>[];
  for (var i = 0; i + 8 <= bits.length; i += 8) {
    var v = 0;
    for (var j = 0; j < 8; j++) {
      v |= bits[i + j] << j;
    }
    bytes.add(v);
  }
  return bytes;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbConfig', () {
    test('isSuperSpeed', () {
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.full).isSuperSpeed,
        isFalse,
      );
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.high).isSuperSpeed,
        isFalse,
      );
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.super_).isSuperSpeed,
        isTrue,
      );
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.superPlus).isSuperSpeed,
        isTrue,
      );
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.superPlus2x2).isSuperSpeed,
        isTrue,
      );
    });

    test('isHighSpeed', () {
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.full).isHighSpeed,
        isFalse,
      );
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.high).isHighSpeed,
        isTrue,
      );
      expect(
        HarborUsbConfig(maxSpeed: HarborUsbSpeed.super_).isHighSpeed,
        isTrue,
      );
    });

    test('toPrettyString', () {
      const config = HarborUsbConfig(
        maxSpeed: HarborUsbSpeed.high,
        role: HarborUsbRole.otg,
      );
      expect(config.toPrettyString(), contains('high'));
      expect(config.toPrettyString(), contains('otg'));
    });
  });

  group('HarborUsbController', () {
    test('creates USB 2.0 device', () {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(
          maxSpeed: HarborUsbSpeed.full,
          role: HarborUsbRole.device,
        ),
        baseAddress: 0x50000000,
      );
      expect(usb.bus, isNotNull);
      expect(usb.interrupt.width, equals(1));
    });

    test('USB 3.0 has SuperSpeed pins', () {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(
          maxSpeed: HarborUsbSpeed.super_,
          role: HarborUsbRole.host,
        ),
        baseAddress: 0x50000000,
      );
      // Should have SS TX/RX pins
      expect(usb.tryOutput('ss_tx_p'), isNotNull);
      expect(usb.tryOutput('ss_tx_n'), isNotNull);
    });

    test('USB 2.0 has no SuperSpeed pins', () {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(maxSpeed: HarborUsbSpeed.high),
        baseAddress: 0x50000000,
      );
      expect(usb.tryOutput('ss_tx_p'), isNull);
    });

    test('DT node uses standard speed strings', () {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(
          maxSpeed: HarborUsbSpeed.super_,
          role: HarborUsbRole.otg,
        ),
        baseAddress: 0x50000000,
      );
      final dt = usb.dtNode;
      expect(dt.properties['maximum-speed'], equals('super-speed'));
      expect(dt.properties['dr_mode'], equals('otg'));
    });
  });

  group('HarborUsbController FS transmitter', () {
    test('serializes a DATA0 packet on usb_dp/usb_dm', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0x60000000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      usb.input('clk').srcConnection! <= clk;
      usb.input('reset').srcConnection! <= reset;
      usb.input('usb_dp_in').srcConnection! <= Const(0);
      usb.input('usb_dm_in').srcConnection! <= Const(0);
      usb.input('bus_CYC').srcConnection! <= stb;
      usb.input('bus_STB').srcConnection! <= stb;
      usb.input('bus_WE').srcConnection! <= we;
      usb.input('bus_ADR').srcConnection! <= adr;
      usb.input('bus_DAT_MOSI').srcConnection! <= mosi;
      usb.input('bus_SEL').srcConnection! <=
          Const(0xF, width: usb.input('bus_SEL').width);

      await usb.build();
      final dp = usb.output('usb_dp_out');
      final dm = usb.output('usb_dm_out');
      final oe = usb.output('usb_oe');

      Future<void> bw(int addr, int data) async {
        adr.inject(addr);
        mosi.inject(data);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Load a DATA0 payload then start the packet.
      const payload = [0xC3, 0x3C, 0xA5, 0x5A];
      await bw(_ep0TxLen, payload.length);
      for (final b in payload) {
        await bw(_ep0TxData, b);
      }
      // PID DATA0 = 0x3, has-data = bit1, start = bit0.
      await bw(_ep0Ctrl, (0x3 << 4) | 0x2 | 0x1);

      // Wait for the driver to enable, then capture line symbols. Sample
      // before advancing the clock so the very first symbol is not skipped.
      final symbols = <int>[]; // 0 = K, 1 = J, 2 = SE0
      var started = false;
      for (var i = 0; i < 4000; i++) {
        final o = oe.value.toInt();
        if (o == 1) {
          started = true;
          final d = dp.value.toInt();
          final m = dm.value.toInt();
          if (d == 1 && m == 0) {
            symbols.add(1); // J
          } else if (d == 0 && m == 1) {
            symbols.add(0); // K
          } else {
            symbols.add(2); // SE0
          }
        } else if (started) {
          break;
        }
        await clk.nextPosedge;
      }

      // Strip the EOP (first SE0 onward).
      final eop = symbols.indexOf(2);
      expect(eop, greaterThan(0), reason: 'expected an EOP');
      final line = symbols.sublist(0, eop);

      // NRZI decode: idle line is J. A hold (same symbol) is a 1, a toggle a 0.
      final rawBits = <int>[];
      var prev = 1; // idle J
      for (final s in line) {
        rawBits.add(s == prev ? 1 : 0);
        prev = s;
      }

      // De-stuff: drop the 0 inserted after six consecutive 1s.
      final bits = <int>[];
      var ones = 0;
      for (final b in rawBits) {
        if (ones == 6) {
          ones = 0; // this bit is the stuffed 0, discard it
          continue;
        }
        bits.add(b);
        ones = (b == 1) ? ones + 1 : 0;
      }

      // Reassemble bytes LSB first.
      final bytes = <int>[];
      for (var i = 0; i + 8 <= bits.length; i += 8) {
        var v = 0;
        for (var j = 0; j < 8; j++) {
          v |= bits[i + j] << j;
        }
        bytes.add(v);
      }

      final crc = _crc16(payload);
      expect(bytes[0], equals(0x80), reason: 'SYNC');
      expect(bytes[1], equals(0xC3), reason: 'PID DATA0 (0x3 + ~0x3)');
      expect(
        bytes.sublist(2, 2 + payload.length),
        equals(payload),
        reason: 'payload',
      );
      expect(bytes[2 + payload.length], equals(crc & 0xFF), reason: 'CRC low');
      expect(
        bytes[3 + payload.length],
        equals((crc >> 8) & 0xFF),
        reason: 'CRC high',
      );
      await Simulator.endSimulation();
    });
  });

  group('HarborUsbController device transactions', () {
    test('answers SETUP, IN and OUT transactions', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0x60000000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);
      final dpin = Logic(name: 'dpin');
      final dmin = Logic(name: 'dmin');

      usb.input('clk').srcConnection! <= clk;
      usb.input('reset').srcConnection! <= reset;
      usb.input('usb_dp_in').srcConnection! <= dpin;
      usb.input('usb_dm_in').srcConnection! <= dmin;
      usb.input('bus_CYC').srcConnection! <= stb;
      usb.input('bus_STB').srcConnection! <= stb;
      usb.input('bus_WE').srcConnection! <= we;
      usb.input('bus_ADR').srcConnection! <= adr;
      usb.input('bus_DAT_MOSI').srcConnection! <= mosi;
      usb.input('bus_SEL').srcConnection! <=
          Const(0xF, width: usb.input('bus_SEL').width);

      await usb.build();
      final dp = usb.output('usb_dp_out');
      final dm = usb.output('usb_dm_out');
      final oe = usb.output('usb_oe');
      final miso = usb.output('bus_DAT_MISO');

      Future<void> bw(int addr, int data) async {
        adr.inject(addr);
        mosi.inject(data);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int addr) async {
        adr.inject(addr);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = miso.value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      // Drives one line symbol ([dp, dm]) for one bit time.
      Future<void> driveSym(List<int> s) async {
        dpin.inject(s[0]);
        dmin.inject(s[1]);
        await clk.nextPosedge;
      }

      Future<void> sendHost(List<int> bytes) async {
        for (final s in _encode(bytes)) {
          await driveSym(s);
        }
      }

      Future<void> idle(int n) async {
        for (var i = 0; i < n; i++) {
          await driveSym([1, 0]); // idle J
        }
      }

      // Sends a host packet and captures the device's reply in the same loop.
      // The device starts replying during the host EOP, so capture must run
      // concurrently with driving. Returns the decoded reply bytes (byte 0 is
      // SYNC, byte 1 the PID).
      Future<List<int>> sendAndCapture(List<int> bytes) async {
        final syms = _encode(bytes);
        final cap = <int>[];
        var started = false;
        var idx = 0;
        for (var i = 0; i < 6000; i++) {
          final o = oe.value.toInt();
          if (o == 1) {
            started = true;
            final d = dp.value.toInt();
            final m = dm.value.toInt();
            cap.add(d == 1 && m == 0 ? 1 : (d == 0 && m == 1 ? 0 : 2));
          } else if (started) {
            break;
          }
          if (idx < syms.length) {
            dpin.inject(syms[idx][0]);
            dmin.inject(syms[idx][1]);
            idx++;
          } else {
            dpin.inject(1);
            dmin.inject(0);
          }
          await clk.nextPosedge;
        }
        final eop = cap.indexOf(2);
        return _decode(eop > 0 ? cap.sublist(0, eop) : cap);
      }

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      dpin.inject(1); // idle J
      dmin.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      await bw(_ctrl, 0x1); // enable
      await idle(4);

      await sendHost([_pid(0xD), ..._token(0, 0)]); // SETUP token
      await idle(3);
      const setupData = [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      final sc = _crc16(setupData);
      final setupAck = await sendAndCapture([
        _pid(0x3),
        ...setupData,
        sc & 0xFF,
        (sc >> 8) & 0xFF,
      ]);
      expect(setupAck[1], equals(_pid(0x2)), reason: 'device ACKs the SETUP');
      expect((await br(_intStatus)) & 0x1, equals(0x1), reason: 'SETUP int');
      expect(await br(_ep0RxLen), equals(8), reason: 'setup length');
      for (final b in setupData) {
        expect(await br(_ep0RxData), equals(b), reason: 'setup byte');
      }
      await idle(4);

      const desc = [0x12, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x40];
      await bw(_ep0TxLen, desc.length);
      for (final b in desc) {
        await bw(_ep0TxData, b);
      }
      // PID DATA1 = 0xB, arm = bit2, has-data = bit1.
      await bw(_ep0Ctrl, (0xB << 4) | (1 << 2) | (1 << 1));
      await idle(2);
      final inResp = await sendAndCapture([_pid(0x9), ..._token(0, 0)]); // IN
      expect(inResp[1], equals(_pid(0xB)), reason: 'device returns DATA1');
      expect(
        inResp.sublist(2, 2 + desc.length),
        equals(desc),
        reason: 'descriptor payload',
      );
      final dc = _crc16(desc);
      expect(inResp[2 + desc.length], equals(dc & 0xFF), reason: 'IN CRC low');
      expect(
        inResp[3 + desc.length],
        equals((dc >> 8) & 0xFF),
        reason: 'IN CRC high',
      );
      await idle(3);
      await sendHost([_pid(0x2)]); // host ACK
      await idle(3);
      expect((await br(_intStatus)) & 0x4, equals(0x4), reason: 'IN done int');
      await idle(3);

      await sendHost([_pid(0x1), ..._token(0, 0)]); // OUT token
      await idle(3);
      const outData = [0xDE, 0xAD, 0xBE, 0xEF];
      final oc = _crc16(outData);
      final outAck = await sendAndCapture([
        _pid(0x3),
        ...outData,
        oc & 0xFF,
        (oc >> 8) & 0xFF,
      ]);
      expect(outAck[1], equals(_pid(0x2)), reason: 'device ACKs the OUT');
      expect((await br(_intStatus)) & 0x2, equals(0x2), reason: 'OUT int');
      expect(await br(_ep0RxLen), equals(4), reason: 'out length');
      for (final b in outData) {
        expect(await br(_ep0RxData), equals(b), reason: 'out byte');
      }

      await Simulator.endSimulation();
    });
  });

  group('HarborUsbController high speed', () {
    test('negotiates high speed via the reset chirp handshake', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(maxSpeed: HarborUsbSpeed.high),
        baseAddress: 0x60000000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);
      final dpin = Logic(name: 'dpin');
      final dmin = Logic(name: 'dmin');

      usb.input('clk').srcConnection! <= clk;
      usb.input('reset').srcConnection! <= reset;
      usb.input('usb_dp_in').srcConnection! <= dpin;
      usb.input('usb_dm_in').srcConnection! <= dmin;
      usb.input('bus_CYC').srcConnection! <= stb;
      usb.input('bus_STB').srcConnection! <= stb;
      usb.input('bus_WE').srcConnection! <= we;
      usb.input('bus_ADR').srcConnection! <= adr;
      usb.input('bus_DAT_MOSI').srcConnection! <= mosi;
      usb.input('bus_SEL').srcConnection! <=
          Const(0xF, width: usb.input('bus_SEL').width);

      await usb.build();
      final oe = usb.output('usb_oe');
      final dp = usb.output('usb_dp_out');
      final dm = usb.output('usb_dm_out');
      final pullup = usb.output('usb_pullup');

      Future<void> bw(int addr, int data) async {
        adr.inject(addr);
        mosi.inject(data);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int addr) async {
        adr.inject(addr);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = usb.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      dpin.inject(1); // idle J
      dmin.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      await bw(_ctrl, 0x1); // enable

      // Drive a bus reset (sustained SE0) until the device chirps.
      dpin.inject(0);
      dmin.inject(0);
      var sawDevChirp = false;
      for (var i = 0; i < 40; i++) {
        await clk.nextPosedge;
        if (oe.value.toInt() == 1 &&
            dp.value.toInt() == 0 &&
            dm.value.toInt() == 1) {
          sawDevChirp = true;
          break;
        }
      }
      expect(sawDevChirp, isTrue, reason: 'device drove a chirp K');

      // Let the device finish its chirp, then drive the host chirp (K-J pairs).
      for (var i = 0; i < 12; i++) {
        await clk.nextPosedge;
      }
      for (var i = 0; i < 20; i++) {
        final k = i.isEven;
        dpin.inject(k ? 0 : 1);
        dmin.inject(k ? 1 : 0);
        await clk.nextPosedge;
      }
      dpin.inject(1); // back to idle J
      dmin.inject(0);
      await clk.nextPosedge;

      final status = await br(_status);
      expect((status >> 8) & 0x1, equals(0x1), reason: 'high-speed bit');
      expect(
        (status >> 4) & 0xF,
        equals(HarborUsbSpeed.high.index),
        reason: 'reports high speed',
      );
      expect(
        pullup.value.toInt(),
        equals(0),
        reason: 'pullup removed in high speed',
      );
      await Simulator.endSimulation();
    });

    test('full-speed-only config never reports high speed', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0x60000000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      usb.input('clk').srcConnection! <= clk;
      usb.input('reset').srcConnection! <= reset;
      usb.input('usb_dp_in').srcConnection! <= Const(0);
      usb.input('usb_dm_in').srcConnection! <= Const(0);
      usb.input('bus_CYC').srcConnection! <= stb;
      usb.input('bus_STB').srcConnection! <= stb;
      usb.input('bus_WE').srcConnection! <= we;
      usb.input('bus_ADR').srcConnection! <= adr;
      usb.input('bus_DAT_MOSI').srcConnection! <= mosi;
      usb.input('bus_SEL').srcConnection! <=
          Const(0xF, width: usb.input('bus_SEL').width);

      await usb.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      adr.inject(_status);
      stb.inject(1);
      await clk.nextPosedge;
      while (usb.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final status = usb.output('bus_DAT_MISO').value.toInt();
      expect((status >> 8) & 0x1, equals(0), reason: 'no high-speed bit');
      await Simulator.endSimulation();
    });
  });

  group('HarborUsbController SuperSpeed', () {
    test('trains the SuperSpeed link to U0 and reports super speed', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(maxSpeed: HarborUsbSpeed.super_),
        baseAddress: 0x60000000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);
      final ssRx = Logic(name: 'ss_rx');

      usb.input('clk').srcConnection! <= clk;
      usb.input('reset').srcConnection! <= reset;
      usb.input('usb_dp_in').srcConnection! <= Const(1);
      usb.input('usb_dm_in').srcConnection! <= Const(0);
      usb.input('ss_rx_p').srcConnection! <= ssRx;
      usb.input('ss_rx_n').srcConnection! <= ~ssRx;
      usb.input('bus_CYC').srcConnection! <= stb;
      usb.input('bus_STB').srcConnection! <= stb;
      usb.input('bus_WE').srcConnection! <= we;
      usb.input('bus_ADR').srcConnection! <= adr;
      usb.input('bus_DAT_MOSI').srcConnection! <= mosi;
      usb.input('bus_SEL').srcConnection! <=
          Const(0xF, width: usb.input('bus_SEL').width);

      await usb.build();
      final ssTxOe = usb.output('ss_tx_oe');

      Future<void> bw(int addr, int data) async {
        adr.inject(addr);
        mosi.inject(data);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int addr) async {
        adr.inject(addr);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = usb.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      ssRx.inject(1); // partner present
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      await bw(_ctrl, 0x1); // enable
      var status = 0;
      for (var i = 0; i < 40; i++) {
        status = await br(_status);
        if ((status >> 9) & 0x1 == 0x1) break;
      }
      expect((status >> 9) & 0x1, equals(0x1), reason: 'SuperSpeed link up');
      expect(
        (status >> 4) & 0xF,
        equals(HarborUsbSpeed.super_.index),
        reason: 'reports super speed',
      );
      expect(ssTxOe.value.toInt(), equals(1), reason: 'SSTX driving in U0');
      await Simulator.endSimulation();
    });
  });

  group('HarborUsbController host mode', () {
    // Builds a host/OTG controller wired so the testbench plays the device:
    // it captures the host's line output and injects device responses.
    Future<Map<String, dynamic>> buildHost(HarborUsbRole role) async {
      final usb = HarborUsbController(
        config: HarborUsbConfig(role: role),
        baseAddress: 0x60000000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);
      final dpin = Logic(name: 'dpin');
      final dmin = Logic(name: 'dmin');

      usb.input('clk').srcConnection! <= clk;
      usb.input('reset').srcConnection! <= reset;
      usb.input('usb_dp_in').srcConnection! <= dpin;
      usb.input('usb_dm_in').srcConnection! <= dmin;
      usb.input('bus_CYC').srcConnection! <= stb;
      usb.input('bus_STB').srcConnection! <= stb;
      usb.input('bus_WE').srcConnection! <= we;
      usb.input('bus_ADR').srcConnection! <= adr;
      usb.input('bus_DAT_MOSI').srcConnection! <= mosi;
      usb.input('bus_SEL').srcConnection! <=
          Const(0xF, width: usb.input('bus_SEL').width);

      await usb.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      dpin.inject(1);
      dmin.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      return {
        'usb': usb,
        'clk': clk,
        'stb': stb,
        'we': we,
        'adr': adr,
        'mosi': mosi,
        'dpin': dpin,
        'dmin': dmin,
      };
    }

    test('host-only build runs OUT and IN transactions', () async {
      final h = await buildHost(HarborUsbRole.host);
      final usb = h['usb'] as HarborUsbController;
      final clk = h['clk'] as Logic;
      final stb = h['stb'] as Logic;
      final we = h['we'] as Logic;
      final adr = h['adr'] as Logic;
      final mosi = h['mosi'] as Logic;
      final dpin = h['dpin'] as Logic;
      final dmin = h['dmin'] as Logic;
      final oe = usb.output('usb_oe');
      final dp = usb.output('usb_dp_out');
      final dm = usb.output('usb_dm_out');

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = usb.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      // Capture one packet the host drives onto the line.
      Future<List<int>> capture() async {
        final syms = <int>[];
        var started = false;
        for (var i = 0; i < 3000; i++) {
          final o = oe.value.toInt();
          if (o == 1) {
            started = true;
            final d = dp.value.toInt();
            final m = dm.value.toInt();
            syms.add(d == 1 && m == 0 ? 1 : (d == 0 && m == 1 ? 0 : 2));
          } else if (started) {
            break;
          }
          dpin.inject(1);
          dmin.inject(0);
          await clk.nextPosedge;
        }
        final eop = syms.indexOf(2);
        return _decode(eop > 0 ? syms.sublist(0, eop) : syms);
      }

      Future<void> sendDevice(List<int> bytes) async {
        for (final s in _encode(bytes)) {
          dpin.inject(s[0]);
          dmin.inject(s[1]);
          await clk.nextPosedge;
        }
        dpin.inject(1);
        dmin.inject(0);
      }

      // Drives a device packet and captures the host's reply (the host begins
      // its ACK during our EOP, so the two must overlap).
      Future<List<int>> sendDeviceAndCapture(List<int> bytes) async {
        final syms = _encode(bytes);
        final cap = <int>[];
        var started = false;
        var idx = 0;
        for (var i = 0; i < 3000; i++) {
          final o = oe.value.toInt();
          if (o == 1) {
            started = true;
            final d = dp.value.toInt();
            final m = dm.value.toInt();
            cap.add(d == 1 && m == 0 ? 1 : (d == 0 && m == 1 ? 0 : 2));
          } else if (started) {
            break;
          }
          if (idx < syms.length) {
            dpin.inject(syms[idx][0]);
            dmin.inject(syms[idx][1]);
            idx++;
          } else {
            dpin.inject(1);
            dmin.inject(0);
          }
          await clk.nextPosedge;
        }
        final eop = cap.indexOf(2);
        return _decode(eop > 0 ? cap.sublist(0, eop) : cap);
      }

      Future<int> waitHostDone() async {
        var st = 0;
        for (var i = 0; i < 200; i++) {
          st = await br(_hostStatus);
          if (st & 0x2 == 0x2) return st;
        }
        return st;
      }

      await bw(_ctrl, 0x1); // enable (host mode is fixed on)

      const outData = [0xDE, 0xAD, 0xBE, 0xEF];
      await bw(_ep0TxLen, outData.length);
      for (final b in outData) {
        await bw(_ep0TxData, b);
      }
      // OUT pid 0x1, addr 5, endp 2, toggle 0 (DATA0)
      await bw(_hostToken, 0x1 | (5 << 4) | (2 << 11));
      final outTok = await capture();
      expect(outTok[1], equals(_pid(0x1)), reason: 'OUT token PID');
      expect(
        outTok.sublist(2, 4),
        equals(_token(5, 2)),
        reason: 'token addr/endp/CRC5',
      );
      final outDat = await capture();
      expect(outDat[1], equals(_pid(0x3)), reason: 'DATA0 PID');
      expect(
        outDat.sublist(2, 2 + outData.length),
        equals(outData),
        reason: 'OUT payload',
      );
      // Device ACKs.
      await sendDevice([_pid(0x2)]);
      final outStatus = await waitHostDone();
      expect((outStatus >> 2) & 0x3, equals(0), reason: 'OUT result ACK');

      await bw(_hostToken, 0x9 | (5 << 4) | (2 << 11)); // IN pid 0x9
      final inTok = await capture();
      expect(inTok[1], equals(_pid(0x9)), reason: 'IN token PID');
      expect(inTok.sublist(2, 4), equals(_token(5, 2)));
      // Device returns DATA1. The host ACKs it (captured concurrently).
      const inData = [0x11, 0x22, 0x33];
      final ic = _crc16(inData);
      final hostAck = await sendDeviceAndCapture([
        _pid(0xB),
        ...inData,
        ic & 0xFF,
        (ic >> 8) & 0xFF,
      ]);
      expect(hostAck[1], equals(_pid(0x2)), reason: 'host ACKs IN data');
      final inStatus = await waitHostDone();
      expect((inStatus >> 2) & 0x3, equals(0), reason: 'IN result OK');
      expect(await br(_ep0RxLen), equals(inData.length));
      for (final b in inData) {
        expect(await br(_ep0RxData), equals(b), reason: 'received IN byte');
      }

      await Simulator.endSimulation();
    });

    test('OTG build defaults to device and switches to host', () async {
      final h = await buildHost(HarborUsbRole.otg);
      final usb = h['usb'] as HarborUsbController;
      final clk = h['clk'] as Logic;
      final stb = h['stb'] as Logic;
      final we = h['we'] as Logic;
      final adr = h['adr'] as Logic;
      final mosi = h['mosi'] as Logic;
      final dpin = h['dpin'] as Logic;
      final dmin = h['dmin'] as Logic;
      final oe = usb.output('usb_oe');
      final dp = usb.output('usb_dp_out');
      final dm = usb.output('usb_dm_out');

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (usb.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = usb.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      // Default after reset: device mode (CTRL host bit clear).
      expect(
        (await br(_ctrl) >> 1) & 0x1,
        equals(0),
        reason: 'defaults device',
      );

      // Switch to host mode and run an OUT token.
      await bw(_ctrl, 0x1 | (1 << 1)); // enable + host
      expect((await br(_ctrl) >> 1) & 0x1, equals(1), reason: 'now host');

      await bw(_hostToken, 0x1 | (3 << 4) | (1 << 11)); // OUT addr 3 endp 1
      final syms = <int>[];
      var started = false;
      for (var i = 0; i < 2000; i++) {
        final o = oe.value.toInt();
        if (o == 1) {
          started = true;
          final d = dp.value.toInt();
          final m = dm.value.toInt();
          syms.add(d == 1 && m == 0 ? 1 : (d == 0 && m == 1 ? 0 : 2));
        } else if (started) {
          break;
        }
        dpin.inject(1);
        dmin.inject(0);
        await clk.nextPosedge;
      }
      final eop = syms.indexOf(2);
      final tok = _decode(eop > 0 ? syms.sublist(0, eop) : syms);
      expect(tok[1], equals(_pid(0x1)), reason: 'OTG host drove an OUT token');
      expect(tok.sublist(2, 4), equals(_token(3, 1)));
      await Simulator.endSimulation();
    });
  });
}
