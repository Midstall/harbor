/// RISC-V Hypervisor (H) extension constants.
///
/// Per the RISC-V Privileged Architecture specification.

/// Hypervisor instructions: all encoded as SYSTEM (opcode 0x73).
///
/// These use R-type encoding with funct7 discriminating the operation.
abstract final class HypervisorFunct7 {
  /// HFENCE.VVMA: hypervisor fence for VS-stage address translation.
  static const hfenceVvma = 0x11;

  /// HFENCE.GVMA: hypervisor fence for G-stage address translation.
  static const hfenceGvma = 0x31;

  /// HLV.B: hypervisor load byte (virtual).
  static const hlvB = 0x30;

  /// HLV.BU: hypervisor load byte unsigned (virtual).
  static const hlvBu = 0x30; // distinguished by rs2

  /// HLV.H: hypervisor load halfword (virtual).
  static const hlvH = 0x32;

  /// HLV.HU: hypervisor load halfword unsigned (virtual).
  static const hlvHu = 0x32; // distinguished by rs2

  /// HLV.W: hypervisor load word (virtual).
  static const hlvW = 0x34;

  /// HLV.WU: hypervisor load word unsigned (virtual, RV64).
  static const hlvWu = 0x34; // distinguished by rs2

  /// HLV.D: hypervisor load doubleword (virtual, RV64).
  static const hlvD = 0x36;

  /// HSV.B: hypervisor store byte (virtual).
  static const hsvB = 0x31;

  /// HSV.H: hypervisor store halfword (virtual).
  static const hsvH = 0x33;

  /// HSV.W: hypervisor store word (virtual).
  static const hsvW = 0x35;

  /// HSV.D: hypervisor store doubleword (virtual, RV64).
  static const hsvD = 0x37;

  /// HLVX.HU: hypervisor load halfword execute unsigned.
  static const hlvxHu = 0x32; // rs2=0x3

  /// HLVX.WU: hypervisor load word execute unsigned.
  static const hlvxWu = 0x34; // rs2=0x3
}

/// Hypervisor CSR addresses.
abstract final class HypervisorCsr {
  // Hypervisor trap setup
  static const hstatus = 0x600;
  static const hedeleg = 0x602;
  static const hideleg = 0x603;
  static const hie = 0x604;
  static const hcounteren = 0x606;
  static const hgeie = 0x607;

  // Hypervisor trap handling
  static const htval = 0x643;
  static const hip = 0x644;
  static const hvip = 0x645;
  static const htinst = 0x64A;
  static const hgeip = 0xE12;

  // Hypervisor configuration
  static const henvcfg = 0x60A;
  static const henvcfgh = 0x61A; // RV32 only

  // Hypervisor counter delegation
  static const htimedeltah = 0x615; // RV32 only
  static const htimedelta = 0x605;

  // Virtual supervisor CSRs (VS-mode trap handling)
  static const vsstatus = 0x200;
  static const vsie = 0x204;
  static const vstvec = 0x205;
  static const vsscratch = 0x240;
  static const vsepc = 0x241;
  static const vscause = 0x242;
  static const vstval = 0x243;
  static const vsip = 0x244;
  static const vsatp = 0x280;

  // Hypervisor guest address translation
  static const hgatp = 0x680;
}

/// hstatus register field layout.
///
/// `[...|VSXL(33:32)|...|VTSR(22)|VTW(21)|VTVM(20)|...|VGEIN(17:12)|...|HU(9)|SPVP(8)|SPV(7)|GVA(6)|VSBE(5)]`
abstract final class HstatusFields {
  /// Virtual supervisor XLEN (bits 33:32, RV64 only).
  static const vsxlShift = 32;

  /// Virtual TVM (trap virtual memory): bit 20.
  static const vtvmBit = 20;

  /// Virtual TW (timeout wait): bit 21.
  static const vtwBit = 21;

  /// Virtual TSR (trap SRET): bit 22.
  static const vtsrBit = 22;

  /// Virtual guest external interrupt number (bits 17:12).
  static const vgeinShift = 12;
  static const vgeinMask = 0x3F;

  /// Hypervisor user mode (bit 9).
  static const huBit = 9;

  /// Supervisor previous virtual privilege (bit 8).
  static const spvpBit = 8;

  /// Supervisor previous virtualization mode (bit 7).
  static const spvBit = 7;

  /// Guest virtual address (bit 6).
  static const gvaBit = 6;

  /// VS-mode big-endian (bit 5).
  static const vsbeBit = 5;
}

/// Hypervisor-related trap causes.
abstract final class HypervisorTrap {
  /// Virtual instruction exception.
  static const virtualInstruction = 22;

  /// Guest page fault: fetch.
  static const guestInstructionPageFault = 20;

  /// Guest page fault: load.
  static const guestLoadPageFault = 21;

  /// Guest page fault: store/AMO.
  static const guestStorePageFault = 23;
}

/// Two-stage address translation modes for hgatp.
abstract final class HgatpMode {
  /// No translation (bare).
  static const bare = 0;

  /// Sv32x4 (RV32).
  static const sv32x4 = 1;

  /// Sv39x4 (RV64).
  static const sv39x4 = 8;

  /// Sv48x4 (RV64).
  static const sv48x4 = 9;

  /// Sv57x4 (RV64).
  static const sv57x4 = 10;
}
