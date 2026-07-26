@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Phase 3 gate G2-min/G3/G4-spatial/G5: HW INTER mode-info entropy decode of the
// minimal single-ref target: a whole-frame BLOCK_64X64 that is INTER,
// mode = NEWMV, motion = SIMPLE, ref0 = LAST_FRAME, MV = (-16,-24) 1/8-pel,
// decoded bit-exact vs the conformant SW TileDecoder. The stream
// is the same 2-frame 64x64 4:2:0 OBU used by the inter frame-header test
// (frame 0 = KEY, frame 1 = the single-ref simple-motion INTER frame).
//
// The inter frame uses primary_ref_frame, so its starting per-context CDFs are
// the KEYFRAME's adapted CDF state (loaded via _loadCdfState). The test extracts
// those exact starting ICDFs from the SW decoder and injects them into the HW
// od_ec contexts, so both decode from an identical probability model. The HW
// then reads partition / skip / is_inter / single_ref / inter_mode / read_mv off
// the same tile-data window and must reproduce the SW ref/mode/mv and, as the
// sync check, the od_ec range at mode-info end.

// Goldens captured from the SW TileDecoder ingest of the embedded 2-frame OBU:
// packed HW inputs (starting CDF banks, tile-data window, mv-precision flags)
// and the SW od_ec range at mode-info end.
final _bytesPk = BigInt.parse('824641175836');
final _cdfPk = BigInt.parse(
  '258662411172003178788758758553726342105433239836111118345565656954586572734132611598967751361406543438774387004824846108486388057316288554116734936346549731260125604469468982945441077640156755008049062531953537581665732660117908215392924701132485891589187860433940671919884687701632390594001800962226920794983226665401967754170973910697577302802933024184375842889246763335624247482521773378944314287771276932551779737026399259163251690410335480691271578657433506256493826350251297864698807099272668942078034138169819584881754961281119136837191719328479659440574772464884916904662511577318499303810710232667692942149126630811542273086590050786166970289129205737118633087379272329289153128588476850165575140907314512147030875116835041057580742232970305058185259876272473426069893458578777033057995261335398755034123121033992354466779098783998843259198185121881352030190230036211071174758952934626831230281457744395388838038244533583860887754202698214441164083581060230221838032470024692896210292506946390311972186443416004971690155021663012982367334750718721963274908497217210705358275415147756270782873159211466968722486992500034535821769956949775783296964057354345844225564547778956656917243337991709156197433890340892637675887534180061914366702189230919442062183340057920740764216535242376739027622169714991678632174220858362465034128207500316598929384737103157689211106793008404052958398380353279361404703228399776592737913635846290376413271902540896794591750499710529453238487553913817730047753081183312196870178172858423515577316448190209871918609740163889327891906175735423549034949474966918959775630632684791986086643178979960330914171444723836762626997316685510235637746474639337814254942635281804225041231125113859379656800336512558169631911466646401360359678056824301508082639575254635902018400303146334278137085786987484116967982741704882169312970419094192051635518212886265841210308802583360243243793944603358989118930056082410425668332477668016665043761416721834787136739555184351645863115297820792993342137762110914976453927100199130327859644693010398641798968902323863060027011250319995466184415637579587786540151124228505077752480420152074901443875232132330209965235005415340222328302013303927160873490784698392034350864718708670611173746217639317658075602006166183844812027599734978871768991722614986461561340575732719159461852026236095126498940144143229235486323823427316445546246745140293460658109383140245978428318012789053369767112940883746557631110281432211266169498429803950134004613108701195683027199297405059135414897882060',
);
final _nsymsPk = BigInt.parse(
  '3647684262768277325591323872501509196710631001657867657048564226471299146',
);
const _allowHp = 1;
const _forceInt = 0;
const _goldRng = 61704;
// SW sanity: isInter=1 ref0=1 mode=16 mv=(-16,-24) motion=0 frameType=1 refMode=0

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'HarborInterModeWalk: single-ref NEWMV block decodes bit-exact vs SW',
    () async {
      const maxBytes = 16;
      const ms = HarborInterModeWalk.maxSyms;

      final t = HarborInterModeWalk(maxBytes: maxBytes);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final allowHp = Logic(name: 'allow_hp');
      final forceInt = Logic(name: 'force_int');
      final cdfIn = Logic(
        name: 'cdf_in',
        width: HarborInterModeWalk.numCtx * ms * 16,
      );
      final nsymsIn = Logic(
        name: 'nsyms_in',
        width: HarborInterModeWalk.numCtx * 5,
      );

      void conn(String p, Logic s) => t.input(p).srcConnection! <= s;
      conn('clk', clk);
      conn('reset', reset);
      conn('start', start);
      conn('bytes', bytes);
      conn('allow_hp', allowHp);
      conn('force_integer_mv', forceInt);
      conn('cdf_in', cdfIn);
      conn('nsyms_in', nsymsIn);
      await t.build();

      reset.inject(1);
      start.inject(0);
      bytes.inject(_bytesPk);
      allowHp.inject(_allowHp);
      forceInt.inject(_forceInt);
      cdfIn.inject(_cdfPk);
      nsymsIn.inject(_nsymsPk);

      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (t.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 2000) fail('inter decode timeout');
      }

      int o(String n) => t.output(n).value.toInt();
      int sgn16(int v) => v >= 0x8000 ? v - 0x10000 : v;

      expect(o('partition'), equals(0), reason: 'PARTITION_NONE');
      expect(o('is_inter'), equals(1), reason: 'is_inter');
      expect(o('ref0'), equals(1), reason: 'ref0 = LAST_FRAME');
      expect(o('inter_mode'), equals(16), reason: 'inter_mode = NEWMV');
      expect(o('motion_mode'), equals(0), reason: 'motion = SIMPLE');
      expect(sgn16(o('mv_row')), equals(-16), reason: 'mv_row');
      expect(sgn16(o('mv_col')), equals(-24), reason: 'mv_col');
      // od_ec range at mode-info end must match SW exactly (bit-exact sync).
      expect(
        o('rng'),
        equals(_goldRng),
        reason: 'od_ec rng sync at mode-info end',
      );
      expect(
        o('sym_count'),
        equals(18),
        reason: 'partition + 17 mode-info symbols',
      );

      await Simulator.endSimulation();
    },
  );
}
