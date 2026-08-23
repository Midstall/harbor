import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// The Verilator harness dispatches host-side models. Two properties matter
/// and neither is visible from the generated program's output: a model must
/// tick only when its OWN clock moved, and a DDR model must see both edges.
void main() {
  HarborSimModel model(
    String name,
    String clockPort, {
    HarborSimClockEdge edge = HarborSimClockEdge.rising,
    List<String> cflags = const [],
    List<String> ldflags = const [],
    List<String> pkgConfig = const [],
  }) => HarborSimModel(
    className: name,
    header: '#pragma once\n',
    declaration: 'static $name ${name}_inst;',
    tick: '${name}_inst.tick(top->pin);',
    clockPort: clockPort,
    edge: edge,
    cflags: cflags,
    ldflags: ldflags,
    pkgConfig: pkgConfig,
  );

  const target = HarborSimTarget(topCell: 'soc', frequency: 25000000);

  test('a model ticks only on the edges of its own clock', () {
    final main = target.generateMain(
      topCell: 'soc',
      clockPorts: {'pixel_clk': 50000000},
      models: [
        model('Slow', 'clk'),
        model('Fast', 'pixel_clk', edge: HarborSimClockEdge.both),
      ],
    );

    // Every clock records whether this iteration actually moved it. Without
    // that, an edge on one domain ticks a model whose clock merely happens to
    // be high, so it samples the same bit many times.
    expect(main, contains('bool toggled[kNumClocks] = {false};'));
    expect(main, contains('toggled[c] = true;'));
    expect(main, contains('if (toggled[0]) {'));
    expect(main, contains('if (toggled[1]) {'));

    // The rising-edge model is still level-gated inside its clock's block.
    expect(main, contains('if (top->clk) {'));
    // The both-edges model is not: it runs on every edge of its clock.
    final fastTick = main.indexOf('Fast_inst.tick');
    final levelGate = main.indexOf('if (top->pixel_clk)');
    expect(
      levelGate == -1 || levelGate > fastTick,
      isTrue,
      reason: 'a both-edges model must not sit behind a level check',
    );
  });

  test('a falling-edge model is gated on the clock being low', () {
    final main = target.generateMain(
      topCell: 'soc',
      clockPorts: const {},
      models: [model('Late', 'clk', edge: HarborSimClockEdge.falling)],
    );
    expect(main, contains('if (!top->clk) {'));
  });

  test('a model on a port that is not a clock domain is refused', () {
    // Silently dropping it would leave the pins unwatched with no clue why.
    expect(
      () => target.generateMain(
        topCell: 'soc',
        clockPorts: const {},
        models: [model('Orphan', 'nonexistent_clk')],
      ),
      throwsStateError,
    );
  });

  test('the Makefile carries the build flags a model asked for', () {
    final makefile = target.generateMakefile(
      'soc',
      models: [
        model('A', 'clk', cflags: ['-DWITH_A']),
        model('B', 'clk', ldflags: ['-lm']),
      ],
    );
    expect(makefile, contains('-CFLAGS "-DWITH_A"'));
    expect(makefile, contains('-LDFLAGS "-lm"'));
    // A build with no model flags keeps its previous command line.
    expect(target.generateMakefile('soc'), isNot(contains('-LDFLAGS')));
  });

  test('a pkg-config library resolves at build time, and must be found', () {
    final makefile = target.generateMakefile(
      'soc',
      models: [
        model('A', 'clk', pkgConfig: ['cairo']),
        // The same library from two models must be resolved once.
        model('B', 'clk', pkgConfig: ['cairo']),
      ],
    );
    // Resolved by the machine doing the build, so the package carries no host
    // paths.
    expect(
      RegExp(r'pkg-config --cflags cairo').allMatches(makefile).length,
      equals(1),
    );
    expect(
      makefile,
      contains(r'CAIRO_LIBS := $(shell pkg-config --libs cairo'),
    );
    expect(makefile, contains(r'VFLAGS += -CFLAGS "$(CAIRO_CFLAGS)"'));
    // A missing library must stop the build by name. Without this it expands
    // to empty flags and fails later with an unrelated message.
    expect(makefile, contains(r'ifeq ($(strip $(CAIRO_LIBS)),)'));
    expect(makefile, contains('cannot find "cairo"'));
  });

  test('a package name becomes a legal make variable', () {
    final makefile = target.generateMakefile(
      'soc',
      models: [
        model('A', 'clk', pkgConfig: ['gtk+-3.0']),
      ],
    );
    expect(makefile, contains('GTK__3_0_CFLAGS :='));
    expect(makefile, contains('pkg-config --cflags gtk+-3.0'));
  });
}
