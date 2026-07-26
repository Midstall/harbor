import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `Partition_Subsize` lookup.
///
/// Given a partition type (0=NONE,1=HORZ,2=VERT,3=SPLIT,4=HORZ_A,5=HORZ_B,
/// 6=VERT_A,7=VERT_B,8=HORZ_4,9=VERT_4) and a square block size, returns the
/// sub-block size the partition produces (the BLOCK_* index the tile FSM uses to
/// recurse / reconstruct). Combinational table lookup. Invalid (partition,size)
/// combinations return 31 (BLOCK_INVALID).
///
/// Block size indices follow AV1: 8x8=3, 16x16=6, 32x32=9, 64x64=12,
/// 128x128=15, sub-results include the rectangular and 4-way sizes (e.g.
/// 16x16 HORZ_4 -> 16x4 = 17).
class HarborPartitionSubsize extends BridgeModule {
  // bsize -> [subsize per partition 0..9]. 31 = BLOCK_INVALID.
  static const _table = {
    3: [3, 2, 1, 0, 31, 31, 31, 31, 31, 31], // 8x8
    6: [6, 5, 4, 3, 5, 5, 4, 4, 17, 16], // 16x16
    9: [9, 8, 7, 6, 8, 8, 7, 7, 19, 18], // 32x32
    12: [12, 11, 10, 9, 11, 11, 10, 10, 21, 20], // 64x64
    15: [15, 14, 13, 12, 14, 14, 13, 13, 31, 31], // 128x128
  };

  HarborPartitionSubsize({String? name})
    : super('HarborPartitionSubsize', name: name ?? 'partition_subsize') {
    createPort('partition', PortDirection.input, width: 4);
    createPort('bsize', PortDirection.input, width: 5);
    addOutput('subsize', width: 5);

    final partition = input('partition');
    final bsize = input('bsize');

    // Select the partition row by index (tree mux over 10 consts).
    Logic rowSelect(List<int> row) {
      final items = [for (final v in row) Const(v, width: 5) as Logic];
      var level = items;
      var bit = 0;
      while (level.length > 1) {
        final next = <Logic>[];
        for (var k = 0; k + 1 < level.length; k += 2) {
          next.add(mux(partition[bit], level[k + 1], level[k]));
        }
        if (level.length.isOdd) next.add(level.last);
        level = next;
        bit++;
      }
      return level.first;
    }

    // Default invalid, override for each square block size.
    Logic result = Const(31, width: 5);
    _table.forEach((bs, row) {
      result = mux(bsize.eq(Const(bs, width: 5)), rowSelect(row), result);
    });
    output('subsize') <= result;
  }
}
