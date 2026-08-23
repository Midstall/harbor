import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('eFuse sim', () {
    test('write ADDR register and read back', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0xA000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));

      final tb = PeripheralTestBench(efuse);
      await tb.init();

      // ADDR word addr 2 (0x08 >> 2)
      await tb.write(0x10, 5);
      final val = await tb.read(0x10);
      expect(val, equals(5));

      await Simulator.endSimulation();
    });

    test('write WDATA and read back', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0xA000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));

      final tb = PeripheralTestBench(efuse);
      await tb.init();

      // WDATA word addr 4 (0x10 >> 2)
      await tb.write(0x20, 0xCAFEBABE);
      final val = await tb.read(0x20);
      expect(val, equals(0xCAFEBABE));

      await Simulator.endSimulation();
    });

    test('lock bits are write-once', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0xA000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));

      final tb = PeripheralTestBench(efuse);
      await tb.init();

      // LOCK word addr 5 (0x14 >> 2)
      // Write 0x01 to lock region 0
      await tb.write(0x28, 0x01);
      var val = await tb.read(0x28);
      expect(val & 0x01, equals(0x01));

      // Try to clear with 0x00 - should still be 0x01 (write-1-to-lock)
      await tb.write(0x28, 0x00);
      val = await tb.read(0x28);
      expect(val & 0x01, equals(0x01));

      // Write 0x04 to also lock region 2 - should be 0x05
      await tb.write(0x28, 0x04);
      val = await tb.read(0x28);
      expect(val & 0x05, equals(0x05));

      await Simulator.endSimulation();
    });

    test('unlock key: wrong key does not unlock', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0xA000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));

      final tb = PeripheralTestBench(efuse);
      await tb.init();

      // Write wrong key to KEY register (word addr 7, 0x1C >> 2)
      await tb.write(0x38, 0xDEADBEEF);

      // Read STATUS (word addr 1, 0x04 >> 2), bit 3 = unlocked
      final status = await tb.read(0x08);
      expect(
        status & 0x08,
        equals(0x00),
        reason: 'Wrong key should not unlock',
      );

      await Simulator.endSimulation();
    });

    test('unlock key: correct key unlocks', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0xA000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));

      final tb = PeripheralTestBench(efuse);
      await tb.init();

      // Write correct key 0x4F545021
      await tb.write(0x38, 0x4F545021);

      // Read STATUS, bit 3 = unlocked
      final status = await tb.read(0x08);
      expect(status & 0x08, equals(0x08), reason: 'Correct key should unlock');

      await Simulator.endSimulation();
    });

    test('unlock key: wrong key re-locks', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0xA000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));

      final tb = PeripheralTestBench(efuse);
      await tb.init();

      // Unlock
      await tb.write(0x38, 0x4F545021);
      var status = await tb.read(0x08);
      expect(status & 0x08, equals(0x08));

      // Note: reading STATUS clears done/error, re-read for current state
      // Lock again with wrong key
      await tb.write(0x38, 0x00000000);
      status = await tb.read(0x08);
      expect(status & 0x08, equals(0x00), reason: 'Wrong key should re-lock');

      await Simulator.endSimulation();
    });
  });
}
