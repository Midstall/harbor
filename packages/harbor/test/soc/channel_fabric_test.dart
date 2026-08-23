// HarborSoC.buildFabric N-channel support: each named channel gets its own
// arbiter plus decoder over its own slave subset. A slave that more than one
// channel reaches is shared through a convergence WishboneArbiter. The
// single-channel default stays byte identical to the historic one-fabric SoC.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Wishbone master that, on `start`, writes `value` to `addr` then reads it
/// back, latching the result on `rdata` and asserting `done`. Same shape as the
/// multi_master_test helper, reused here to drive per-channel transactions.
class _RwMaster extends BridgeModule {
  _RwMaster(WishboneConfig cfg, int addr, int value, {String? name})
    : super('RwMaster', name: name ?? 'rw_master') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    final done = addOutput('done');
    final rdata = addOutput('rdata', width: cfg.dataWidth);

    final bus =
        addInterface(
              WishboneInterface(cfg),
              name: 'bus',
              role: PairRole.provider,
            ).internalInterface
            as WishboneInterface;

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');

    final st = Logic(name: 'st', width: 3);
    final cyc = Logic(name: 'cyc');
    final stb = Logic(name: 'stb');
    final we = Logic(name: 'we');
    final rdReg = Logic(name: 'rd_reg', width: cfg.dataWidth);
    final doneReg = Logic(name: 'done_reg');
    final ackNow = cyc & stb & bus.ack;

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(0, width: 3),
          cyc < Const(0),
          stb < Const(0),
          we < Const(0),
          rdReg < Const(0, width: cfg.dataWidth),
          doneReg < Const(0),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(0, width: 3), [
              If(
                start,
                then: [
                  cyc < Const(1),
                  stb < Const(1),
                  we < Const(1),
                  st < Const(1, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(1, width: 3), [
              If(
                ackNow,
                then: [
                  cyc < Const(0),
                  stb < Const(0),
                  we < Const(0),
                  st < Const(2, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 3), [
              cyc < Const(1),
              stb < Const(1),
              we < Const(0),
              st < Const(3, width: 3),
            ]),
            CaseItem(Const(3, width: 3), [
              If(
                ackNow,
                then: [
                  rdReg < bus.datMiso,
                  cyc < Const(0),
                  stb < Const(0),
                  doneReg < Const(1),
                  st < Const(4, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(4, width: 3), []),
          ]),
        ],
      ),
    ]);

    bus.cyc <= cyc;
    bus.stb <= stb;
    bus.we <= we;
    bus.adr <= Const(addr, width: cfg.addressWidth);
    bus.datMosi <= Const(value, width: cfg.dataWidth);
    bus.sel <=
        Const((1 << cfg.effectiveSelWidth) - 1, width: cfg.effectiveSelWidth);
    done <= doneReg;
    rdata <= rdReg;
  }
}

/// Walks the whole module tree under [root], root included.
Iterable<Module> _allModules(Module root) sync* {
  yield root;
  for (final sub in root.subModules) {
    yield* _allModules(sub);
  }
}

List<WishboneDecoder> _decoders(Module root) =>
    _allModules(root).whereType<WishboneDecoder>().toList();

List<WishboneArbiter> _arbiters(Module root) =>
    _allModules(root).whereType<WishboneArbiter>().toList();

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('single-channel byte-identical guard', () {
    test(
      'default fabric: exactly one decoder, no arbiter (one master)',
      () async {
        const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
        final soc = HarborSoC(
          name: 'GoldenSoC',
          compatible: 'test,golden',
          busConfig: cfg,
        );
        soc.addMaster(
          _RwMaster(cfg, 0x20, 0, name: 'cpu'),
          busInterfaceName: 'bus',
        );
        soc.addPeripheral(
          HarborSram(
            baseAddress: 0,
            size: 4096,
            busAddressWidth: 32,
            name: 'sramA',
          ),
        );
        soc.addPeripheral(
          HarborSram(
            baseAddress: 0x1000,
            size: 4096,
            busAddressWidth: 32,
            name: 'sramB',
          ),
        );
        soc.buildFabric();
        await soc.build();

        final decoders = _decoders(soc);
        final arbiters = _arbiters(soc);
        // GOLDEN: one decoder over both slaves, no arbiter at all.
        expect(decoders, hasLength(1));
        expect(decoders.single.definitionName, equals('WishboneDecoder_S2'));
        expect(arbiters, isEmpty);
        expect(soc.fabricArbiter, isNull);
      },
    );

    test(
      'explicit single primary reaching all is identical to the default',
      () async {
        const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);

        List<String> fabricSubs(Map<String, Set<String>>? cs) {
          final soc = HarborSoC(
            name: 'IdSoC',
            compatible: 'test,id',
            busConfig: cfg,
          );
          soc.addMaster(
            _RwMaster(cfg, 0x20, 0, name: 'cpu'),
            busInterfaceName: 'bus',
          );
          soc.addPeripheral(
            HarborSram(
              baseAddress: 0,
              size: 4096,
              busAddressWidth: 32,
              name: 'sramA',
            ),
          );
          soc.addPeripheral(
            HarborSram(
              baseAddress: 0x1000,
              size: 4096,
              busAddressWidth: 32,
              name: 'sramB',
            ),
          );
          soc.buildFabric(channelSlaves: cs);
          return [
            ..._decoders(soc).map((d) => d.definitionName),
            ..._arbiters(soc).map((a) => a.definitionName),
          ]..sort();
        }

        final byDefault = fabricSubs(null);
        final byExplicit = fabricSubs({
          'primary': {'sramA', 'sramB'},
        });
        // Naming the one primary channel over every slave takes the byte-identical
        // path, so the fabric submodule set matches the default exactly.
        expect(byExplicit, equals(byDefault));
      },
    );
  });

  test('two channels, disjoint slaves: two decoders, no convergence', () async {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'DisjointSoC',
      compatible: 'test,disjoint',
      busConfig: cfg,
    );
    // perA at 0x0.., perB at 0x1000..
    final mCpu = _RwMaster(cfg, 0x20, 0xAAAA1111, name: 'cpu');
    final mDma = _RwMaster(cfg, 0x1020, 0xBBBB2222, name: 'dma');
    soc.addMaster(mCpu, busInterfaceName: 'bus', channel: 'primary');
    soc.addMaster(mDma, busInterfaceName: 'bus', channel: 'dma');
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'perB',
      ),
    );
    soc.buildFabric(
      channelSlaves: {
        'primary': {'perA'},
        'dma': {'perB'},
      },
    );

    // Two decoders, each over ONE slave. No convergence arbiter (disjoint).
    expect(_decoders(soc), hasLength(2));
    expect(
      _decoders(soc).map((d) => d.definitionName).toSet(),
      equals({'WishboneDecoder_S1'}),
    );
    expect(_arbiters(soc), isEmpty);

    final clk = SimpleClockGenerator(10).clk;
    final resetL = Logic(name: 'reset')..inject(1);
    final startA = Logic(name: 'startA')..inject(0);
    final startB = Logic(name: 'startB')..inject(0);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= resetL;
    mCpu.input('start').srcConnection! <= startA;
    mDma.input('start').srcConnection! <= startB;

    await soc.build();
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetL.inject(0);
    await clk.nextPosedge;
    startA.inject(1);
    startB.inject(1);
    await clk.nextPosedge;
    startA.inject(0);
    startB.inject(0);

    var guard = 0;
    while (guard++ < 500) {
      await clk.nextPosedge;
      if (mCpu.output('done').value.toBool() &&
          mDma.output('done').value.toBool()) {
        break;
      }
    }
    expect(mCpu.output('done').value.toBool(), isTrue, reason: 'cpu done');
    expect(mDma.output('done').value.toBool(), isTrue, reason: 'dma done');
    expect(mCpu.output('rdata').value.toInt(), equals(0xAAAA1111));
    expect(mDma.output('rdata').value.toInt(), equals(0xBBBB2222));
    await Simulator.endSimulation();
  });

  test(
    'two channels sharing memory: convergence arbiter, both reach mem',
    () async {
      const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
      final soc = HarborSoC(
        name: 'SharedMemSoC',
        compatible: 'test,sharedmem',
        busConfig: cfg,
      );
      // perA at 0x0.. (primary only), mem at 0x1000.. (both channels).
      // primary writes/reads a mem word, dma writes/reads a different mem word.
      final mCpu = _RwMaster(cfg, 0x1020, 0xAAAA1111, name: 'cpu');
      final mDma = _RwMaster(cfg, 0x1040, 0xBBBB2222, name: 'dma');
      soc.addMaster(mCpu, busInterfaceName: 'bus', channel: 'primary');
      soc.addMaster(mDma, busInterfaceName: 'bus', channel: 'dma');
      soc.addPeripheral(
        HarborSram(
          baseAddress: 0,
          size: 4096,
          busAddressWidth: 32,
          name: 'perA',
        ),
      );
      soc.addPeripheral(
        HarborSram(
          baseAddress: 0x1000,
          size: 4096,
          busAddressWidth: 32,
          name: 'mem',
        ),
      );
      soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'mem'},
          'dma': {'mem'},
        },
      );

      // primary decoder reaches perA + mem (S2), dma decoder reaches mem only
      // (S1). So dma physically cannot route to perA.
      final decDefs = _decoders(soc).map((d) => d.definitionName).toList()
        ..sort();
      expect(decDefs, equals(['WishboneDecoder_S1', 'WishboneDecoder_S2']));

      // A single convergence arbiter (2 channels reach mem) and no channel
      // arbiter (each channel has one master).
      final arbs = _arbiters(soc);
      expect(arbs, hasLength(1));
      expect(arbs.single.numMasters, equals(2));
      expect(arbs.single.name, contains('converge'));

      final clk = SimpleClockGenerator(10).clk;
      final resetL = Logic(name: 'reset')..inject(1);
      final startA = Logic(name: 'startA')..inject(0);
      final startB = Logic(name: 'startB')..inject(0);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= resetL;
      mCpu.input('start').srcConnection! <= startA;
      mDma.input('start').srcConnection! <= startB;

      await soc.build();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      resetL.inject(0);
      await clk.nextPosedge;
      startA.inject(1);
      startB.inject(1);
      await clk.nextPosedge;
      startA.inject(0);
      startB.inject(0);

      var guard = 0;
      while (guard++ < 500) {
        await clk.nextPosedge;
        if (mCpu.output('done').value.toBool() &&
            mDma.output('done').value.toBool()) {
          break;
        }
      }
      // Both channels reached mem through the convergence arbiter.
      expect(
        mCpu.output('done').value.toBool(),
        isTrue,
        reason: 'primary reached mem',
      );
      expect(
        mDma.output('done').value.toBool(),
        isTrue,
        reason: 'dma reached mem',
      );
      expect(mCpu.output('rdata').value.toInt(), equals(0xAAAA1111));
      expect(mDma.output('rdata').value.toInt(), equals(0xBBBB2222));
      await Simulator.endSimulation();
    },
  );

  test('converge: dualport throws UnimplementedError', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'DualportSoC',
      compatible: 'test,dualport',
      busConfig: cfg,
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1020, 0, name: 'cpu'),
      busInterfaceName: 'bus',
      channel: 'primary',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1040, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'mem',
      ),
    );
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'mem'},
          'dma': {'mem'},
        },
        converge: HarborMemConverge.dualport,
      ),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('converge: sharedDecode throws UnimplementedError', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'SharedDecodeSoC',
      compatible: 'test,shareddecode',
      busConfig: cfg,
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1020, 0, name: 'cpu'),
      busInterfaceName: 'bus',
      channel: 'primary',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1040, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'mem',
      ),
    );
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'mem'},
          'dma': {'mem'},
        },
        converge: HarborMemConverge.sharedDecode,
      ),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('a channel with masters absent from channelSlaves is an error', () {
    const cfg = WishboneConfig(addressWidth: 32, dataWidth: 32);
    final soc = HarborSoC(
      name: 'MissingChannelSoC',
      compatible: 'test,missing',
      busConfig: cfg,
    );
    soc.addMaster(
      _RwMaster(cfg, 0x20, 0, name: 'cpu'),
      busInterfaceName: 'bus',
      channel: 'primary',
    );
    soc.addMaster(
      _RwMaster(cfg, 0x1020, 0, name: 'dma'),
      busInterfaceName: 'bus',
      channel: 'dma',
    );
    soc.addPeripheral(
      HarborSram(baseAddress: 0, size: 4096, busAddressWidth: 32, name: 'perA'),
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x1000,
        size: 4096,
        busAddressWidth: 32,
        name: 'perB',
      ),
    );
    // 'dma' has a master but is not in the map.
    expect(
      () => soc.buildFabric(
        channelSlaves: {
          'primary': {'perA', 'perB'},
        },
      ),
      throwsStateError,
    );
  });
}
