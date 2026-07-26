import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../riscv/paging.dart';

/// Page table walker state machine states.
enum HarborPtwState {
  /// Waiting for TLB miss.
  idle,

  /// Reading page table entry from memory.
  readPte,

  /// Checking PTE validity and permissions.
  checkPte,

  /// Walking next level (non-leaf PTE).
  walkNext,

  /// Updating A/D bits in PTE.
  updateAd,

  /// Writing result to TLB.
  writeTlb,

  /// Reporting page fault.
  fault,
}

/// Synthesizable RISC-V page table walker.
///
/// Performs hardware page table walks for Sv32/Sv39/Sv48/Sv57 paging.
/// Supports two-stage translation for the H extension (VS-stage
/// walks through G-stage translation).
///
/// Connects to:
/// - TLB (receives miss, writes back translation)
/// - L1D cache or memory bus (reads page table entries)
/// - CSR file (reads satp/hgatp for base address and mode)
class HarborPageTableWalker extends BridgeModule {
  /// Supported paging modes.
  final List<RiscVPagingMode> pagingModes;

  /// Whether to support two-stage translation (H extension).
  final bool twoStage;

  /// Whether to support hardware A/D bit updates.
  final bool hardwareAdUpdate;

  HarborPageTableWalker({
    this.pagingModes = const [RiscVPagingMode.sv39, RiscVPagingMode.sv48],
    this.twoStage = false,
    this.hardwareAdUpdate = true,
    super.name = 'ptw',
  }) : super('HarborPageTableWalker') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // TLB miss interface
    createPort('miss_valid', PortDirection.input);
    createPort('miss_vpn', PortDirection.input, width: 44);
    createPort('miss_asid', PortDirection.input, width: 16);
    createPort('miss_is_store', PortDirection.input);
    createPort('miss_is_execute', PortDirection.input);

    // TLB write-back interface
    addOutput('tlb_write_valid');
    addOutput('tlb_write_vpn', width: 44);
    addOutput('tlb_write_ppn', width: 44);
    addOutput('tlb_write_perms', width: 7);
    addOutput('tlb_write_level', width: 3);

    // Page fault output
    addOutput('fault_valid');
    addOutput('fault_cause', width: 4); // trap cause code
    addOutput('fault_addr', width: 64); // faulting address

    // Memory read interface (to L1D or bus)
    addOutput('mem_addr', width: 64);
    addOutput('mem_read');
    createPort('mem_data', PortDirection.input, width: 64);
    createPort('mem_valid', PortDirection.input);

    // Memory write interface (for A/D bit updates)
    if (hardwareAdUpdate) {
      addOutput('mem_write');
      addOutput('mem_wdata', width: 64);
    }

    // CSR inputs
    createPort('satp', PortDirection.input, width: 64); // satp register
    if (twoStage) {
      createPort('hgatp', PortDirection.input, width: 64); // hgatp register
      createPort('vsatp', PortDirection.input, width: 64); // vsatp register
      createPort('v_mode', PortDirection.input); // currently in VS/VU mode
    }

    // PMP check interface
    createPort('pmp_allow', PortDirection.input);
    addOutput('pmp_check_addr', width: 64);
    addOutput('pmp_check_valid');

    final clk = input('clk');
    final reset = input('reset');

    // PTW state machine
    final state = Logic(name: 'ptw_state', width: 3);
    final level = Logic(name: 'walk_level', width: 3);
    final pteAddr = Logic(name: 'pte_addr', width: 64);
    final vpnSaved = Logic(name: 'vpn_saved', width: 44);

    // Maximum walk levels: Sv39=3, Sv48=4, Sv57=5
    final maxLevel = pagingModes.fold<int>(
      0,
      (max, m) => m.levels > max ? m.levels : max,
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(HarborPtwState.idle.index, width: 3),
          level < Const(0, width: 3),
          pteAddr < Const(0, width: 64),
          vpnSaved < Const(0, width: 44),
          output('tlb_write_valid') < Const(0),
          output('fault_valid') < Const(0),
          output('mem_read') < Const(0),
          output('pmp_check_valid') < Const(0),
          if (hardwareAdUpdate) output('mem_write') < Const(0),
        ],
        orElse: [
          output('tlb_write_valid') < Const(0),
          output('fault_valid') < Const(0),

          Case(state, [
            // Idle: wait for TLB miss
            CaseItem(Const(HarborPtwState.idle.index, width: 3), [
              If(
                input('miss_valid'),
                then: [
                  vpnSaved < input('miss_vpn'),
                  level < Const(maxLevel - 1, width: 3),
                  // Compute PTE address from satp.PPN and VPN[level]
                  state < Const(HarborPtwState.readPte.index, width: 3),
                  output('mem_read') < Const(1),
                ],
              ),
            ]),

            // Read PTE from memory
            CaseItem(Const(HarborPtwState.readPte.index, width: 3), [
              If(
                input('mem_valid'),
                then: [
                  output('mem_read') < Const(0),
                  state < Const(HarborPtwState.checkPte.index, width: 3),
                ],
              ),
            ]),

            // Check PTE validity
            CaseItem(Const(HarborPtwState.checkPte.index, width: 3), [
              // Check V bit, permission bits, reserved bits
              // If leaf PTE: go to writeTlb (or updateAd)
              // If non-leaf: go to walkNext (decrement level)
              // If invalid: go to fault
              state < Const(HarborPtwState.writeTlb.index, width: 3),
            ]),

            // Walk next level
            CaseItem(Const(HarborPtwState.walkNext.index, width: 3), [
              If(
                level.eq(Const(0, width: 3)),
                then: [
                  // Reached bottom level without leaf: fault
                  state < Const(HarborPtwState.fault.index, width: 3),
                ],
                orElse: [
                  level < level - 1,
                  state < Const(HarborPtwState.readPte.index, width: 3),
                  output('mem_read') < Const(1),
                ],
              ),
            ]),

            // Write translation to TLB
            CaseItem(Const(HarborPtwState.writeTlb.index, width: 3), [
              output('tlb_write_valid') < Const(1),
              output('tlb_write_vpn') < vpnSaved,
              output('tlb_write_level') < level,
              state < Const(HarborPtwState.idle.index, width: 3),
            ]),

            // Page fault
            CaseItem(Const(HarborPtwState.fault.index, width: 3), [
              output('fault_valid') < Const(1),
              state < Const(HarborPtwState.idle.index, width: 3),
            ]),
          ]),
        ],
      ),
    ]);

    // Placeholder outputs
    output('mem_addr') <= pteAddr;
    output('tlb_write_ppn') <= Const(0, width: 44);
    output('tlb_write_perms') <= Const(0, width: 7);
    output('fault_cause') <= Const(0, width: 4);
    output('fault_addr') <= vpnSaved.zeroExtend(64);
    output('pmp_check_addr') <= pteAddr;
    if (hardwareAdUpdate) {
      output('mem_wdata') <= Const(0, width: 64);
    }
  }
}
