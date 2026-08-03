/// JEDEC DDR3 AC-timing computation, a faithful port of the timing functions and
/// derived localparams in UberDDR3's `ddr3_controller.v` (the `ns_to_cycles`,
/// `nCK_to_cycles`, `ns_to_nCK`, `nCK_to_ns`, `get_slot`, `find_delay`,
/// `WRA_mode_register_value` helpers and everything computed from them).
///
/// The controller schedules DRAM commands on one of four CK "slots" per
/// controller cycle (the 4:1 SERDES ratio). Each command-to-command spacing
/// (precharge-to-activate, activate-to-write, ...) is a number of controller
/// cycles derived from the JEDEC time (ns), the slot each command lands on, and
/// the CK/controller periods. Getting this math bit-exact to the Verilog matters:
/// the FSM's delay counters are sized and compared against these constants.
library;

/// DDR3 device density, selecting tRFC (refresh-to-activate). MT41K128M16 = 2 Gb.
enum DdrDensity {
  gb1(110.0),
  gb2(160.0),
  gb4(300.0),
  gb8(350.0);

  const DdrDensity(this.tRfcNs);

  /// tRFC in ns.
  final double tRfcNs;
}

class DdrTiming {
  /// DDR3 CK period in ns (e.g. 3.0 = 333 MHz, 3.333 = 300 MHz).
  final double ddr3ClkPeriodNs;

  /// Controller-interface clock period in ns (= [serdesRatio] * CK period).
  final double controllerClkPeriodNs;

  /// SERDES ratio (4 for a 4:1 real-speed PHY).
  final int serdesRatio;

  /// Device density (selects tRFC).
  final DdrDensity density;

  DdrTiming({
    required this.ddr3ClkPeriodNs,
    required this.serdesRatio,
    this.density = DdrDensity.gb2,
  }) : controllerClkPeriodNs = ddr3ClkPeriodNs * serdesRatio;

  DdrTiming.fromPs({
    required int ddr3ClkPeriodPs,
    required int serdesRatio,
    DdrDensity density = DdrDensity.gb2,
  }) : this(
         ddr3ClkPeriodNs: ddr3ClkPeriodPs / 1000.0,
         serdesRatio: serdesRatio,
         density: density,
       );

  // --- timing-conversion functions (ddr3_controller.v:2124-2178) ---

  /// ns -> controller cycles, rounded up.
  int nsToCycles(double ns) => (ns / controllerClkPeriodNs).ceil();

  /// DDR cycles (nCK) -> controller cycles, rounded up.
  int nckToCycles(int nck) => (nck / serdesRatio).ceil();

  /// ns -> DDR cycles (nCK), rounded up.
  int nsToNck(double ns) => (ns / ddr3ClkPeriodNs).ceil();

  /// DDR cycles (nCK) -> ns, rounded up to an integer (the YOSYS `$rtoi($ceil)`).
  int nckToNs(int nck) => (nck * ddr3ClkPeriodNs).ceil();

  static double _maxD(double a, double b) => a >= b ? a : b;
  static int _maxI(int a, int b) => a >= b ? a : b;

  // --- JEDEC AC timings (ddr3_controller.v:176-210, DDR3-1600 11-11-11 bin) ---

  static const double tRcd = 13.750; // Active to Read/Write
  static const double tRp = 13.750; // Precharge period
  static const double tRas = 35.0; // ACT to PRE
  double get tRfc => density.tRfcNs; // Refresh to ACT/REF
  static const int tRefiNs = 7800; // avg refresh interval
  double get tXpr => _maxD(5 * ddr3ClkPeriodNs, tRfc + 10);
  static const double tWr = 15.0; // Write recovery
  double get tWtr => _maxD(nckToNs(4).toDouble(), 7.5);
  int get tWlmrd => nckToCycles(40); // controller cycles
  static const double tWlo = 7.5;
  static const int tWloe = 2;
  double get tRtp => _maxD(nckToNs(4).toDouble(), 7.5);
  static const int tCcd = 4; // nCK
  int get tMod => _maxI(nckToCycles(12), nsToCycles(15));
  int get tZqInit => _maxI(nckToCycles(512), nsToCycles(640.0));

  static const int clNck = 6; // CAS latency (nCK)
  static const int cwlNck = 5; // CAS write latency (nCK)

  static const int powerOnResetHigh = 200000; // ns
  static const int initialCkeLow = 500000; // ns
  int get delayMaxValue => nsToCycles(initialCkeLow.toDouble());
  int get delayCounterWidth => _clog2(delayMaxValue);
  static const int calibrationDelay = 2;

  static const int delaySlotWidth = 19;

  // --- initial delay taps (ddr3_controller.v:158-170) ---
  static const int dataInitialOdelayTap = 0;
  static const int dataInitialIdelayTap = 0;

  /// DQS ODELAY tap = a quarter CK (in ps) / 78.125 ps per tap, floored.
  int get dqsInitialOdelayTap =>
      ((ddr3ClkPeriodNs * 1000 / 4) / 78.125 + dataInitialOdelayTap).toInt();
  int get dqsInitialIdelayTap =>
      ((ddr3ClkPeriodNs * 1000 / 4) / 78.125 + dataInitialIdelayTap).toInt();

  // --- command-slot assignment (ddr3_controller.v:2199-2251 get_slot) ---
  // Slots wrap mod 4 (reg[1:0]). read/write slot = -(latency) mod 4; the
  // activate/precharge "anticipate" slots take the two remaining slots.

  static int _mod4(int x) => ((x % 4) + 4) % 4;

  int get readSlot => _mod4(-clNck);
  int get writeSlot => _mod4(-cwlNck);

  int get activateSlot {
    var slot = clNck > cwlNck ? readSlot : writeSlot;
    var delay = nsToNck(tRcd);
    for (; delay != 0; delay--) {
      slot = _mod4(slot - 1);
    }
    while (slot == writeSlot || slot == readSlot) {
      slot = _mod4(slot - 1);
    }
    return slot;
  }

  int get prechargeSlot {
    var slot = 0;
    while (slot == writeSlot || slot == readSlot || slot == activateSlot) {
      slot = _mod4(slot - 1);
    }
    return slot;
  }

  /// find_delay: controller cycles k so `(4 - start) + end + 4k >= delayNck`.
  int findDelay(int delayNck, int startSlot, int endSlot) {
    var k = 0;
    while (((4 - startSlot) + endSlot + 4 * k) < delayNck) {
      k++;
    }
    return k;
  }

  // --- derived command-to-command delays (ddr3_controller.v:216-226) ---

  int get prechargeToActivateDelay =>
      findDelay(nsToNck(tRp), prechargeSlot, activateSlot);
  int get activateToPrechargeDelay =>
      findDelay(nsToNck(tRas), activateSlot, prechargeSlot);
  int get activateToWriteDelay =>
      findDelay(nsToNck(tRcd), activateSlot, writeSlot);
  int get activateToReadDelay =>
      findDelay(nsToNck(tRcd), activateSlot, readSlot);
  int get readToWriteDelay =>
      findDelay(clNck + tCcd + 2 - cwlNck, readSlot, writeSlot);
  int get readToReadDelay => 0;
  int get readToPrechargeDelay =>
      findDelay(nsToNck(tRtp), readSlot, prechargeSlot);
  int get writeToWriteDelay => 0;
  int get writeToReadDelay =>
      findDelay(cwlNck + 4 + nsToNck(tWtr), writeSlot, readSlot);
  int get writeToPrechargeDelay =>
      findDelay(cwlNck + 4 + nsToNck(tWr), writeSlot, prechargeSlot);
  int get preRefreshDelay => writeToPrechargeDelay + 1;

  int get marginBeforeAnticipate =>
      prechargeToActivateDelay + activateToWriteDelay + writeToPrechargeDelay;

  // --- Mode Register 0 write-recovery field (ddr3_controller.v:2181-2197) ---

  /// WR (write recovery for auto-precharge) 3-bit MR0 field for a given cycle
  /// count. The caller passes `ceil(tWR / CK) - 1`, matching the Verilog which
  /// switches on `WRA + 1`.
  static int wraModeRegisterValue(int wra) {
    switch (wra + 1) {
      case 1:
      case 2:
      case 3:
      case 4:
      case 5:
        return 1; // 3'b001
      case 6:
        return 2; // 3'b010
      case 7:
        return 3; // 3'b011
      case 8:
        return 4; // 3'b100
      case 9:
      case 10:
        return 5; // 3'b101
      case 11:
      case 12:
        return 6; // 3'b110
      case 13:
      case 14:
        return 7; // 3'b111
      default: // 15,16 and out-of-range -> largest (16 cycles)
        return 0; // 3'b000
    }
  }

  /// The MR0 WR field for this timing (tWR / CK, rounded up).
  int get wr => wraModeRegisterValue((tWr / ddr3ClkPeriodNs).ceil());

  static int _clog2(int x) {
    var n = 0;
    var v = x - 1;
    while (v > 0) {
      v >>= 1;
      n++;
    }
    return n;
  }
}
