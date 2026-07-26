@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart' show HarborFrameHeaderParse;
import 'package:harbor/src/media/global_mv.dart';
import 'package:harbor/src/media/gm_params.dart';
import 'package:harbor/src/media/global_warp_model.dart';
import 'package:harbor/src/media/warp_affine.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// block_size_wide / block_size_high (pixels), [BLOCK_SIZES_ALL]. Copied from the
// SW reference tables (constant data).
const _blockSizeWide = [
  4,
  4,
  8,
  8,
  8,
  16,
  16,
  16,
  32,
  32,
  32,
  64,
  64,
  64,
  128,
  128,
  4,
  16,
  8,
  32,
  16,
  64,
];
const _blockSizeHigh = [
  4,
  8,
  4,
  8,
  16,
  8,
  16,
  32,
  16,
  32,
  64,
  32,
  64,
  128,
  64,
  128,
  16,
  4,
  32,
  8,
  64,
  16,
];

// Bit-exact tests for the Harbor global-motion HW blocks against the conformant
// SW oracle. Three sub-parts:
//   (2) HarborGlobalMv       vs SW gmGetMotionVector  (gm_get_motion_vector)
//   (3a) HarborGlobalWarpModel vs SW globalWarpModel  (av1_get_shear_params)
//   (3b) HarborWarpAffine fed the GLOBAL shear vs SW warpAffine over an 8x8 block
//
// Real ROTZOOM global-motion matrices captured from aomenc 3.12.1 pan/zoom
// streams (confirmed gmType==ROTZOOM fired via SW parseFrameHeader) are folded
// into the random corpus so the tests exercise real decoder output, not only
// synthetic models.
const _realRotzoom = <List<int>>[
  [1007616, -575488, 65600, 8, -8, 65600], // pan  ref=1
  [1011712, 957440, 65566, -4, 4, 65566], // pan  ref=1 (later)
  [1010688, 930816, 65632, -42, 42, 65632], // panc ref=4
  [151552, 151552, 63622, 8, -8, 63622], // zoom ref=1
  [167936, 176128, 63746, 42, -42, 63746], // zoom ref=1
  [1047552, 1135616, 61964, 44, -44, 61964], // zoom ref=2
  [641024, 645120, 58506, 18, -18, 58506], // zoom ref=7
  [463872, 468992, 60658, 20, -20, 60658], // zoom ref=4
];

int _asSigned(int v, int width) {
  final m = 1 << (width - 1);
  return (v & (m - 1)) - (v & m);
}

int _fit(int v, int width) => v & ((1 << width) - 1);

// Goldens captured from the SW reference (decodeGlobalMotionParams,
// gmGetMotionVector, globalWarpModel, warpAffine, and a real ROTZOOM OBU
// header) for the seeded corpora below.
const _t1 = <({List<int> gmType, List<List<int>> gmParams, int bitsConsumed})>[
  (
    gmType: [0, 0, 0, 0, 0, 0, 2],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-365568, 625664, 69272, 378, -378, 69272],
    ],
    bitsConsumed: 25,
  ),
  (
    gmType: [0, 3, 0, 2, 0, 3, 1],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [549888, -273408, 67942, -7872, -4256, 63428],
      [0, 0, 65536, 0, 0, 65536],
      [-139264, 37888, 63014, -6442, 6442, 63014],
      [0, 0, 65536, 0, 0, 65536],
      [232448, -120832, 68420, -1110, -3500, 72280],
      [688128, -802816, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 120,
  ),
  (
    gmType: [2, 0, 1, 2, 0, 0, 0],
    gmParams: [
      [-650240, 529408, 72154, -1338, 1338, 72154],
      [0, 0, 65536, 0, 0, 65536],
      [0, -589824, 65536, 0, 0, 65536],
      [-179200, 1054720, 69886, -2688, 2688, 69886],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 76,
  ),
  (
    gmType: [0, 0, 0, 0, 0, 2, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [12288, 474112, 72726, -6268, 6268, 72726],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 28,
  ),
  (
    gmType: [0, 1, 0, 2, 0, 0, 3],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [385024, -630784, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [367616, -602112, 62326, 1906, -1906, 62326],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-483328, 658432, 64524, -5992, -5274, 59628],
    ],
    bitsConsumed: 78,
  ),
  (
    gmType: [0, 0, 1, 2, 0, 1, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [835584, 884736, 65536, 0, 0, 65536],
      [671744, -261120, 66792, 7982, -7982, 66792],
      [0, 0, 65536, 0, 0, 65536],
      [-557056, 425984, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 49,
  ),
  (
    gmType: [0, 2, 1, 0, 1, 3, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [431104, -519168, 58938, 5110, -5110, 58938],
      [507904, -458752, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [475136, 147456, 65536, 0, 0, 65536],
      [-344064, -1024, 73198, 2902, 898, 60874],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 105,
  ),
  (
    gmType: [1, 0, 0, 2, 0, 0, 0],
    gmParams: [
      [557056, 819200, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [156672, -62464, 61526, -4652, 4652, 61526],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 44,
  ),
  (
    gmType: [0, 1, 2, 0, 0, 3, 2],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [65536, -958464, 65536, 0, 0, 65536],
      [336896, 1040384, 63838, -2202, 2202, 63838],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [215040, -258048, 59278, 4010, 1326, 65762],
      [41984, 862208, 71030, 3400, -3400, 71030],
    ],
    bitsConsumed: 96,
  ),
  (
    gmType: [0, 1, 0, 0, 2, 3, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [-475136, -802816, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-795648, -342016, 64044, -4984, 4984, 64044],
      [132096, 568320, 65554, 5822, -6482, 72966],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 89,
  ),
  (
    gmType: [2, 0, 0, 0, 2, 1, 0],
    gmParams: [
      [799744, 150528, 60164, 7034, -7034, 60164],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [208896, 39936, 70190, 5928, -5928, 70190],
      [974848, -909312, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 60,
  ),
  (
    gmType: [0, 0, 2, 0, 1, 0, 1],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [875520, -91136, 58188, -2370, 2370, 58188],
      [0, 0, 65536, 0, 0, 65536],
      [-65536, 466944, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-884736, -1064960, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 64,
  ),
  (
    gmType: [1, 2, 2, 2, 0, 3, 0],
    gmParams: [
      [188416, 598016, 65536, 0, 0, 65536],
      [241664, -102400, 68042, -1556, 1556, 68042],
      [-562176, -933888, 64238, -1308, 1308, 64238],
      [224256, 438272, 61108, 5830, -5830, 61108],
      [0, 0, 65536, 0, 0, 65536],
      [-112640, -715776, 71068, -2820, -5042, 57868],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 111,
  ),
  (
    gmType: [2, 2, 0, 0, 3, 0, 1],
    gmParams: [
      [628736, 555008, 66566, -2208, 2208, 66566],
      [-727040, 141312, 61390, 5686, -5686, 61390],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [671744, -565248, 59868, 5460, 4842, 66638],
      [0, 0, 65536, 0, 0, 65536],
      [49152, 483328, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 99,
  ),
  (
    gmType: [1, 0, 0, 0, 0, 2, 0],
    gmParams: [
      [966656, 720896, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [538624, -106496, 65974, 452, -452, 65974],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 35,
  ),
  (
    gmType: [0, 0, 2, 0, 3, 2, 2],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-263168, -712704, 70472, -4882, 4882, 70472],
      [0, 0, 65536, 0, 0, 65536],
      [-517120, -983040, 66984, 134, 3914, 69942],
      [-219136, 118784, 58272, 3334, -3334, 58272],
      [-41984, 349184, 64262, 5290, -5290, 64262],
    ],
    bitsConsumed: 122,
  ),
  (
    gmType: [0, 0, 2, 0, 3, 2, 2],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [609280, 330752, 59352, -3888, 3888, 59352],
      [0, 0, 65536, 0, 0, 65536],
      [896000, 1010688, 63354, 5958, 6208, 68268],
      [673792, 427008, 72162, 844, -844, 72162],
      [-103424, -906240, 62936, -3502, 3502, 62936],
    ],
    bitsConsumed: 94,
  ),
  (
    gmType: [2, 0, 2, 2, 2, 0, 0],
    gmParams: [
      [147456, 500736, 63922, 4802, -4802, 63922],
      [0, 0, 65536, 0, 0, 65536],
      [806912, -419840, 60446, -2086, 2086, 60446],
      [-314368, -230400, 71158, -620, 620, 71158],
      [242688, 578560, 71300, -7232, 7232, 71300],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 88,
  ),
  (
    gmType: [0, 0, 1, 0, 3, 0, 1],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-688128, -811008, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [976896, 432128, 58104, -3206, -862, 66390],
      [0, 0, 65536, 0, 0, 65536],
      [966656, -32768, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 63,
  ),
  (
    gmType: [0, 3, 3, 2, 0, 2, 2],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [194560, 765952, 69046, 7708, -2800, 61380],
      [955392, 139264, 62948, 3974, 2338, 67466],
      [-611328, 239616, 67726, 768, -768, 67726],
      [0, 0, 65536, 0, 0, 65536],
      [309248, -93184, 63656, -4402, 4402, 63656],
      [-509952, -754688, 72010, 1558, -1558, 72010],
    ],
    bitsConsumed: 137,
  ),
  (
    gmType: [1, 0, 1, 2, 3, 2, 3],
    gmParams: [
      [647168, 8192, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [679936, 974848, 65536, 0, 0, 65536],
      [550912, -226304, 70704, -4602, 4602, 70704],
      [692224, 215040, 61674, 4710, 3792, 72198],
      [-201728, -804864, 62840, -338, 338, 62840],
      [-744448, -894976, 62252, -5970, 6196, 72394],
    ],
    bitsConsumed: 131,
  ),
  (
    gmType: [0, 0, 0, 2, 2, 0, 2],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [350208, 820224, 62744, 6460, -6460, 62744],
      [-544768, -595968, 62054, 3586, -3586, 62054],
      [0, 0, 65536, 0, 0, 65536],
      [-219136, 300032, 62480, -382, 382, 62480],
    ],
    bitsConsumed: 66,
  ),
  (
    gmType: [0, 2, 2, 2, 1, 3, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [-774144, 683008, 69710, -7380, 7380, 69710],
      [520192, 467968, 61034, 2158, -2158, 61034],
      [-243712, -2058240, 73644, 2210, -2210, 73644],
      [-229376, -696320, 65536, 0, 0, 65536],
      [-184320, -95232, 58480, -4664, -6902, 71056],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 138,
  ),
  (
    gmType: [3, 2, 0, 3, 0, 1, 3],
    gmParams: [
      [642048, -87040, 70546, 2736, -6832, 58738],
      [1040384, -417792, 69930, -3320, 3320, 69930],
      [0, 0, 65536, 0, 0, 65536],
      [375808, -759808, 59360, -7228, 3426, 62036],
      [0, 0, 65536, 0, 0, 65536],
      [-458752, 393216, 65536, 0, 0, 65536],
      [860160, -906240, 71128, -2114, -4026, 61744],
    ],
    bitsConsumed: 149,
  ),
  (
    gmType: [1, 0, 1, 3, 0, 0, 0],
    gmParams: [
      [491520, 770048, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-770048, 311296, 65536, 0, 0, 65536],
      [-325632, -380928, 71818, -904, 7874, 62916],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 71,
  ),
  (
    gmType: [3, 0, 2, 0, 2, 2, 2],
    gmParams: [
      [-577536, 674816, 65344, -4548, 1406, 70344],
      [0, 0, 65536, 0, 0, 65536],
      [205824, -501760, 72504, -5728, 5728, 72504],
      [0, 0, 65536, 0, 0, 65536],
      [-727040, -464896, 73150, 6442, -6442, 73150],
      [949248, 308224, 70102, 1816, -1816, 70102],
      [-644096, 468992, 60238, 7562, -7562, 60238],
    ],
    bitsConsumed: 127,
  ),
  (
    gmType: [0, 0, 0, 1, 0, 1, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-966656, -737280, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [647168, 950272, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 31,
  ),
  (
    gmType: [0, 0, 3, 3, 0, 3, 1],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-632832, 226304, 58488, -5730, -2948, 63524],
      [-619520, -502784, 67286, -5246, 5516, 73406],
      [0, 0, 65536, 0, 0, 65536],
      [7168, -908288, 67994, -6238, 1832, 62022],
      [581632, -974848, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 142,
  ),
  (
    gmType: [0, 0, 1, 1, 1, 2, 3],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-393216, -458752, 65536, 0, 0, 65536],
      [376832, -2654208, 65536, 0, 0, 65536],
      [229376, 655360, 65536, 0, 0, 65536],
      [132096, -594944, 65686, -5820, 5820, 65686],
      [949248, 532480, 63838, 2360, 4590, 67570],
    ],
    bitsConsumed: 118,
  ),
  (
    gmType: [0, 1, 2, 0, 1, 0, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [-16384, -311296, 65536, 0, 0, 65536],
      [797696, -406528, 66082, -4794, 4794, 66082],
      [0, 0, 65536, 0, 0, 65536],
      [589824, -1048576, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 59,
  ),
  (
    gmType: [2, 0, 1, 0, 1, 1, 2],
    gmParams: [
      [705536, -596992, 68280, -5122, 5122, 68280],
      [0, 0, 65536, 0, 0, 65536],
      [933888, 425984, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-360448, 704512, 65536, 0, 0, 65536],
      [-737280, -409600, 65536, 0, 0, 65536],
      [-523264, 284672, 61606, -5054, 5054, 61606],
    ],
    bitsConsumed: 88,
  ),
  (
    gmType: [2, 0, 1, 2, 0, 0, 0],
    gmParams: [
      [-760832, -477184, 68368, -354, 354, 68368],
      [0, 0, 65536, 0, 0, 65536],
      [245760, -802816, 65536, 0, 0, 65536],
      [-765952, -555008, 68058, -7942, 7942, 68058],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 55,
  ),
  (
    gmType: [0, 0, 0, 2, 2, 2, 1],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-865280, -322560, 65608, -6344, 6344, 65608],
      [-831488, 453632, 58610, -3582, 3582, 58610],
      [62464, -992256, 70548, -226, 226, 70548],
      [-360448, 786432, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 84,
  ),
  (
    gmType: [0, 0, 3, 0, 3, 0, 0],
    gmParams: [
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [209920, -222208, 70650, 5434, -3714, 58934],
      [0, 0, 65536, 0, 0, 65536],
      [929792, 138240, 71482, -2772, -7110, 68860],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 63,
  ),
  (
    gmType: [2, 2, 2, 0, 0, 0, 3],
    gmParams: [
      [-898048, -483328, 60900, -4362, 4362, 60900],
      [51200, -826368, 58696, -2508, 2508, 58696],
      [1013760, 24576, 66056, -3510, 3510, 66056],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-268288, 709632, 73140, 534, 554, 71078],
    ],
    bitsConsumed: 98,
  ),
  (
    gmType: [1, 0, 0, 0, 1, 2, 2],
    gmParams: [
      [-655360, -1048576, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [147456, -2031616, 65536, 0, 0, 65536],
      [-39936, 503808, 65884, -640, 640, 65884],
      [273408, 452608, 61516, 1246, -1246, 61516],
    ],
    bitsConsumed: 90,
  ),
  (
    gmType: [3, 0, 2, 3, 0, 0, 0],
    gmParams: [
      [-318464, 498688, 60108, -6414, 6750, 61030],
      [0, 0, 65536, 0, 0, 65536],
      [-185344, 135168, 60472, -1396, 1396, 60472],
      [-753664, -165888, 73106, 2386, -7440, 66422],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 93,
  ),
  (
    gmType: [1, 1, 2, 0, 0, 0, 2],
    gmParams: [
      [-966656, 819200, 65536, 0, 0, 65536],
      [-360448, 98304, 65536, 0, 0, 65536],
      [-915456, -693248, 65688, -328, 328, 65688],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [-567296, 918528, 63872, 3854, -3854, 63872],
    ],
    bitsConsumed: 76,
  ),
  (
    gmType: [3, 0, 2, 1, 2, 1, 0],
    gmParams: [
      [-971776, 889856, 59542, 3596, 4430, 67746],
      [0, 0, 65536, 0, 0, 65536],
      [-307200, -186368, 60466, 3124, -3124, 60466],
      [-180224, 163840, 65536, 0, 0, 65536],
      [-482304, -352256, 68948, 430, -430, 68948],
      [524288, -491520, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 109,
  ),
  (
    gmType: [2, 0, 1, 0, 0, 0, 1],
    gmParams: [
      [734208, -254976, 63744, 5762, -5762, 63744],
      [0, 0, 65536, 0, 0, 65536],
      [868352, -1032192, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [0, 0, 65536, 0, 0, 65536],
      [3670016, 180224, 65536, 0, 0, 65536],
    ],
    bitsConsumed: 60,
  ),
];
const _t2 = <List<int>>[
  [0, 0],
  [-20, -84],
  [160, 88],
  [-64, 128],
  [88, -168],
  [24, 104],
  [-64, 128],
  [-16, 24],
  [0, 0],
  [-66, 33],
  [266, 236],
  [0, 0],
  [-77, 57],
  [-20, -304],
  [-144, -128],
  [120, 128],
  [-240, 16],
  [64, 26],
  [120, 128],
  [0, 0],
  [240, -272],
  [-64, 128],
  [-448, -136],
  [-120, -144],
  [-66, 124],
  [152, -432],
  [128, -542],
  [0, 0],
  [-271, -228],
  [96, 40],
  [118, 125],
  [-1, -7],
  [162, -183],
  [64, -56],
  [-64, 344],
  [-16, -104],
  [0, 0],
  [0, 0],
  [65, 87],
  [0, 0],
  [-168, 142],
  [-363, 158],
  [118, 124],
  [412, -192],
  [0, 0],
  [-57, 79],
  [104, 64],
  [-16, 0],
  [-91, 88],
  [-40, -128],
  [0, 0],
  [-67, 125],
  [-40, -32],
  [-128, -72],
  [-104, -8],
  [0, 0],
  [0, 0],
  [64, -24],
  [64, 104],
  [416, 344],
  [0, 0],
  [-120, 128],
  [98, -312],
  [-72, 128],
  [-144, 192],
  [-107, 31],
  [8, -32],
  [-85, 144],
  [56, -192],
  [-202, -158],
  [166, 282],
  [96, 48],
  [0, 0],
  [32, -112],
  [-452, -34],
  [0, -98],
  [-468, -142],
  [0, 0],
  [0, 0],
  [56, 64],
  [-206, -326],
  [0, 0],
  [126, -238],
  [466, 193],
  [120, 124],
  [0, 0],
  [0, 0],
  [-368, -224],
  [91, 483],
  [-248, -160],
  [0, 0],
  [52, 188],
  [102, 51],
  [-16, -2],
  [-97, 46],
  [0, 0],
  [0, 0],
  [0, 0],
  [101, 39],
  [121, 121],
  [32, 64],
  [104, -96],
  [8, -40],
  [0, 0],
  [192, -208],
  [0, 0],
  [0, 0],
  [304, -296],
  [0, 0],
  [114, 3],
  [272, -136],
  [-158, -84],
  [-56, 152],
  [-40, 8],
  [0, 0],
  [-344, -16],
  [-160, 64],
  [0, 0],
  [432, 416],
  [-16, -192],
  [-184, -272],
  [-188, -78],
  [0, 0],
  [69, -21],
  [-96, 88],
  [0, 0],
  [0, 0],
  [103, -114],
  [320, -352],
  [-64, 128],
  [436, -316],
  [0, 0],
  [0, 0],
  [40, 120],
  [120, 48],
  [110, 98],
  [0, 0],
  [32, 80],
  [0, 0],
  [56, -184],
  [-309, -229],
  [-19, 61],
  [105, -34],
  [0, 0],
  [-480, -128],
  [32, 40],
  [180, 272],
  [0, 0],
  [-22, 57],
  [-56, 232],
  [-16, -56],
  [-106, -297],
  [-88, 72],
  [0, 0],
  [0, 0],
  [0, 0],
  [-376, -64],
  [0, 0],
  [0, 0],
  [-312, -96],
  [0, 0],
  [0, 0],
  [-192, -40],
  [578, -402],
  [0, 0],
  [-8, -24],
  [200, 248],
  [182, 255],
  [-120, -24],
  [-144, 210],
  [0, 0],
  [-72, 128],
  [147, -291],
  [19, 8],
  [-182, -83],
  [-48, -32],
  [88, 72],
  [0, 0],
  [-27, 115],
  [0, 0],
  [0, 0],
  [0, 0],
  [0, 0],
  [57, 48],
  [280, 24],
  [50, 47],
  [0, 0],
  [236, 298],
  [27, -92],
  [118, 124],
  [0, 0],
  [-120, -152],
  [0, 0],
  [0, 0],
  [0, 0],
  [-16, -8],
  [0, 0],
  [0, 0],
  [0, 0],
  [112, -48],
  [-213, -26],
  [-64, -232],
  [278, 808],
  [64, -328],
  [46, -8],
  [-8, 88],
  [-552, 248],
  [8, 40],
  [-200, -176],
  [-530, -626],
  [-15, 102],
  [0, 0],
  [0, 0],
  [0, 0],
  [0, 0],
  [0, 0],
  [48, 48],
  [-313, 17],
  [152, -40],
  [32, -16],
  [-44, -106],
  [568, 85],
  [-66, 124],
  [0, 0],
  [-56, -88],
  [34, 14],
  [-2, -58],
  [0, 0],
  [0, 0],
  [0, 0],
  [114, -81],
  [-149, -54],
  [-44, -52],
  [-103, 2],
  [-248, -8],
  [368, 232],
  [-18, 26],
  [-96, -176],
  [207, -76],
  [37, -21],
  [-31, -48],
  [0, 0],
  [-320, 90],
  [104, -8],
  [256, -312],
  [0, 0],
  [-240, -560],
  [0, 0],
  [0, 0],
  [0, 0],
  [392, 0],
  [218, -44],
  [16, -40],
  [305, 413],
  [-110, -594],
  [-72, 120],
  [-16, 77],
  [-333, 192],
  [128, 128],
  [-66, 425],
  [0, 0],
  [-24, -72],
  [280, -208],
  [-7, 87],
  [73, 120],
  [-82, -313],
  [0, 0],
  [-3, -107],
  [-24, 272],
  [-450, 55],
  [-56, -152],
  [150, 72],
  [42, -116],
  [120, 128],
  [64, 48],
  [-72, -126],
  [-120, 24],
  [16, -40],
  [-107, -42],
  [-498, -616],
  [0, 0],
  [70, 284],
  [-64, 128],
  [30, -42],
  [25, -83],
  [-23, -90],
  [68, 758],
  [38, 23],
  [120, 124],
  [0, 0],
  [360, -32],
  [0, 0],
  [-280, -176],
  [0, 0],
  [124, 124],
  [0, 0],
  [-80, 0],
  [0, -112],
  [0, 0],
  [-120, -64],
  [-32, 40],
  [0, 0],
  [328, 208],
  [102, 9],
  [0, 0],
  [0, 0],
  [-122, -179],
  [0, 0],
  [0, 0],
  [120, 120],
  [-232, -208],
  [49, 72],
  [7, 124],
  [0, 0],
  [0, 0],
  [-40, 8],
  [0, 0],
  [0, 0],
  [0, -536],
  [-136, -280],
  [-152, -56],
  [84, 23],
  [0, 0],
  [-80, 192],
  [101, -32],
  [96, -20],
  [0, 0],
  [-128, -112],
  [120, 56],
  [0, -96],
  [85, -66],
  [-332, 488],
  [113, 155],
  [-131, -9],
  [-16, -104],
  [-247, -85],
  [118, 126],
  [-79, -61],
  [248, -106],
  [7, 105],
  [0, 0],
  [0, 0],
  [-64, 128],
  [16, 152],
  [0, 0],
  [0, 0],
  [40, -339],
  [167, -149],
  [0, 0],
  [278, -116],
  [538, -142],
  [-68, 130],
  [0, 0],
  [-224, 64],
  [120, 132],
  [112, 0],
  [-96, 64],
  [-97, 4],
  [0, 0],
  [-152, -168],
  [0, 0],
  [88, 368],
  [112, 240],
  [-38, -172],
  [-248, 176],
  [-41, 114],
  [-64, 128],
  [40, 112],
  [396, 205],
  [-208, -200],
  [-74, -3],
  [0, 0],
  [-48, -48],
  [200, 256],
  [-38, 26],
  [-496, -584],
  [-586, -172],
  [-24, 192],
  [0, 0],
  [68, 44],
  [222, -28],
  [-72, -40],
  [-88, -296],
  [0, 0],
  [-64, 128],
  [-240, 384],
  [-70, 43],
  [61, -126],
  [79, 75],
  [-24, 56],
  [127, 124],
  [-380, -91],
  [0, 0],
  [0, -128],
  [0, 0],
  [-72, 72],
  [0, 0],
  [0, 0],
  [0, 0],
  [-111, -123],
];
const _t3 = <({bool valid, int alpha, int beta, int gamma, int delta})>[
  (valid: true, alpha: 64, beta: 0, gamma: 0, delta: 64),
  (valid: true, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 128, beta: -64, gamma: 64, delta: 128),
  (valid: true, alpha: -1920, beta: 0, gamma: 0, delta: -1920),
  (valid: true, alpha: -1792, beta: 64, gamma: -64, delta: -1792),
  (valid: true, alpha: -3584, beta: 64, gamma: -64, delta: -3584),
  (valid: true, alpha: -7040, beta: 0, gamma: 0, delta: -7040),
  (valid: true, alpha: -4864, beta: 0, gamma: 0, delta: -4864),
  (valid: true, alpha: -1728, beta: 4992, gamma: -704, delta: -3712),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -2432, beta: -960, gamma: 6016, delta: -5952),
  (valid: true, alpha: 2304, beta: -5312, gamma: -4800, delta: 4608),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 3328, beta: 5120, gamma: 4928, delta: 192),
  (valid: true, alpha: -4224, beta: 5504, gamma: -3072, delta: -1408),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -3776, beta: -4544, gamma: -3328, delta: 7424),
  (valid: true, alpha: 6848, beta: 512, gamma: 4352, delta: -2944),
  (valid: true, alpha: 7488, beta: -640, gamma: -7168, delta: -5696),
  (valid: true, alpha: 2560, beta: 4096, gamma: 4096, delta: 1408),
  (valid: true, alpha: -832, beta: -4928, gamma: 4032, delta: 4096),
  (valid: true, alpha: 4608, beta: -5184, gamma: 4416, delta: -448),
  (valid: true, alpha: 1728, beta: 6016, gamma: 3392, delta: -1024),
  (valid: true, alpha: -6656, beta: 3328, gamma: 320, delta: 1088),
  (valid: true, alpha: -2688, beta: -4032, gamma: -7872, delta: 5312),
  (valid: true, alpha: -1792, beta: -3840, gamma: -2432, delta: 7168),
  (valid: true, alpha: 4608, beta: -576, gamma: 3136, delta: 6528),
  (valid: true, alpha: 1472, beta: -2560, gamma: 5888, delta: 3328),
  (valid: true, alpha: -2560, beta: -2240, gamma: 4352, delta: -192),
  (valid: true, alpha: -4864, beta: 1856, gamma: 8320, delta: 7232),
  (valid: true, alpha: -4928, beta: 6080, gamma: -8704, delta: 1216),
  (valid: true, alpha: 3072, beta: 3264, gamma: -1280, delta: -3968),
  (valid: true, alpha: -6208, beta: -2304, gamma: 2624, delta: -1408),
  (valid: true, alpha: -256, beta: 7104, gamma: 7232, delta: 3520),
  (valid: true, alpha: 5504, beta: -4352, gamma: 5376, delta: -1664),
  (valid: true, alpha: 2368, beta: -3072, gamma: 2752, delta: -4032),
  (valid: true, alpha: 1856, beta: 6528, gamma: -6208, delta: -4992),
  (valid: true, alpha: -1664, beta: 6720, gamma: -7168, delta: 6656),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 1408, beta: -7808, gamma: 1088, delta: 3456),
  (valid: true, alpha: -7232, beta: 4992, gamma: 6784, delta: 6720),
  (valid: true, alpha: 6208, beta: 1472, gamma: 5632, delta: -2368),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 1536, beta: -704, gamma: 2944, delta: -7232),
  (valid: true, alpha: -4800, beta: -1216, gamma: 1856, delta: 3712),
  (valid: true, alpha: -6656, beta: 1792, gamma: 1728, delta: -7488),
  (valid: true, alpha: -4736, beta: 2944, gamma: -2688, delta: 7040),
  (valid: true, alpha: -1792, beta: -7744, gamma: 2560, delta: 7488),
  (valid: true, alpha: 5568, beta: -5824, gamma: -6720, delta: -1024),
  (valid: true, alpha: 128, beta: 1088, gamma: 2752, delta: -7616),
  (valid: true, alpha: -128, beta: -4416, gamma: -1152, delta: 5440),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 64, beta: -4480, gamma: 768, delta: -3072),
  (valid: true, alpha: -1408, beta: -3072, gamma: 4224, delta: 1408),
  (valid: true, alpha: 512, beta: -5760, gamma: -5056, delta: 448),
  (valid: true, alpha: 960, beta: 1344, gamma: -5952, delta: -7360),
  (valid: true, alpha: -576, beta: -1984, gamma: -3264, delta: 4352),
  (valid: true, alpha: -1344, beta: -4352, gamma: 2048, delta: -2880),
  (valid: true, alpha: -4096, beta: -2304, gamma: 1152, delta: 2304),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -6400, beta: -1920, gamma: -576, delta: -64),
  (valid: true, alpha: -2176, beta: -2816, gamma: -7744, delta: -64),
  (valid: true, alpha: -4800, beta: -6080, gamma: -1344, delta: -6912),
  (valid: true, alpha: 2944, beta: -2944, gamma: -320, delta: 128),
  (valid: true, alpha: -7488, beta: 4096, gamma: 4928, delta: -3968),
  (valid: true, alpha: 384, beta: -2688, gamma: 6912, delta: 8064),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 704, beta: -3136, gamma: 5568, delta: 832),
  (valid: true, alpha: -4736, beta: 1088, gamma: -1344, delta: -1344),
  (valid: true, alpha: 3264, beta: 5248, gamma: -2624, delta: 3840),
  (valid: true, alpha: 6720, beta: -128, gamma: -3520, delta: 6400),
  (valid: true, alpha: -832, beta: -1856, gamma: -2432, delta: -2368),
  (valid: true, alpha: -7808, beta: -3200, gamma: -8640, delta: -5760),
  (valid: true, alpha: -3072, beta: -3072, gamma: 2240, delta: 6592),
  (valid: true, alpha: 7424, beta: -1856, gamma: 6912, delta: -576),
  (valid: true, alpha: 7680, beta: 4096, gamma: -5888, delta: 256),
  (valid: true, alpha: 832, beta: 3264, gamma: -7232, delta: -4864),
  (valid: true, alpha: -2688, beta: -4736, gamma: -384, delta: 5312),
  (valid: true, alpha: 4352, beta: -512, gamma: 3648, delta: 2880),
  (valid: true, alpha: -896, beta: 4864, gamma: -1152, delta: 7552),
  (valid: true, alpha: 0, beta: -8128, gamma: -5120, delta: -7680),
  (valid: true, alpha: 8000, beta: -3072, gamma: 512, delta: 3776),
  (valid: true, alpha: -7360, beta: -2304, gamma: -2048, delta: -3008),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 2752, beta: -576, gamma: -2624, delta: 7360),
  (valid: true, alpha: -3392, beta: 4672, gamma: 640, delta: -5312),
  (valid: true, alpha: 3200, beta: -1024, gamma: 7488, delta: -1408),
  (valid: true, alpha: 4544, beta: -4544, gamma: 2880, delta: 5440),
  (valid: true, alpha: -5696, beta: -3136, gamma: -3584, delta: -5248),
  (valid: true, alpha: 7488, beta: 1856, gamma: 4096, delta: 7360),
  (valid: true, alpha: -8000, beta: 3968, gamma: -2240, delta: -4480),
  (valid: true, alpha: -4608, beta: 4608, gamma: 576, delta: 6784),
  (valid: true, alpha: -5568, beta: 768, gamma: -5824, delta: 5632),
  (valid: true, alpha: -1920, beta: 6656, gamma: -5056, delta: -7040),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -8064, beta: 2880, gamma: 192, delta: -1280),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 640, beta: -5504, gamma: 3776, delta: -2624),
  (valid: true, alpha: -7872, beta: -1664, gamma: 3200, delta: 6336),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 192, beta: 3968, gamma: 384, delta: 4800),
  (valid: true, alpha: 3520, beta: 5056, gamma: 3072, delta: 4352),
  (valid: true, alpha: 4096, beta: 1152, gamma: 2048, delta: 3904),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 2624, beta: -5376, gamma: -4032, delta: -6720),
  (valid: true, alpha: -3392, beta: 3392, gamma: -1344, delta: 512),
  (valid: true, alpha: 2880, beta: 896, gamma: 512, delta: -5568),
  (valid: true, alpha: 2176, beta: -2944, gamma: 3456, delta: -2880),
  (valid: true, alpha: 4864, beta: 5440, gamma: 5504, delta: -7424),
  (valid: true, alpha: 4096, beta: -6976, gamma: -1984, delta: 4032),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 1344, beta: -640, gamma: -6464, delta: -4672),
  (valid: true, alpha: -5888, beta: -2624, gamma: 3712, delta: -2240),
  (valid: true, alpha: -5632, beta: -4672, gamma: -3520, delta: -4608),
  (valid: true, alpha: 7104, beta: 1728, gamma: -5376, delta: 6976),
  (valid: true, alpha: -4608, beta: 5376, gamma: 896, delta: 896),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 7360, beta: 2944, gamma: -4800, delta: -6656),
  (valid: true, alpha: -4992, beta: -1216, gamma: -3264, delta: 1600),
  (valid: true, alpha: 5504, beta: -3200, gamma: -4416, delta: 2944),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -4160, beta: -3520, gamma: 7040, delta: 6976),
  (valid: true, alpha: -8064, beta: -3200, gamma: 7616, delta: -2176),
  (valid: true, alpha: 0, beta: -1920, gamma: -4544, delta: 5440),
  (valid: true, alpha: -1408, beta: -2112, gamma: 2496, delta: 2048),
  (valid: true, alpha: -2688, beta: -5120, gamma: 128, delta: 3968),
  (valid: true, alpha: -1472, beta: 2048, gamma: -3520, delta: -1536),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 2496, beta: 640, gamma: -4672, delta: 6336),
  (valid: true, alpha: 3328, beta: -2112, gamma: -3008, delta: -2240),
  (valid: true, alpha: -320, beta: -384, gamma: -3712, delta: -640),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -5824, beta: 3520, gamma: 8576, delta: 5184),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 1216, beta: -128, gamma: -4672, delta: 192),
  (valid: true, alpha: 6976, beta: 4352, gamma: -2560, delta: -2624),
  (valid: true, alpha: -1280, beta: 640, gamma: -6080, delta: 4160),
  (valid: true, alpha: -192, beta: 1280, gamma: -6912, delta: 5056),
  (valid: true, alpha: -6400, beta: 896, gamma: 1216, delta: 1024),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -5568, beta: -2176, gamma: 2240, delta: 192),
  (valid: true, alpha: 8128, beta: -4288, gamma: -1536, delta: -8064),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -6016, beta: 5056, gamma: 768, delta: 3200),
  (valid: true, alpha: 3264, beta: 5440, gamma: 5760, delta: -5952),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 2432, beta: -3392, gamma: 2944, delta: 1856),
  (valid: true, alpha: 2240, beta: -192, gamma: 3200, delta: 192),
  (valid: true, alpha: -3392, beta: -4032, gamma: -3776, delta: -960),
  (valid: true, alpha: -896, beta: 6400, gamma: 1920, delta: 5632),
  (valid: true, alpha: -128, beta: 2560, gamma: -7104, delta: 2560),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -7872, beta: 2624, gamma: 7040, delta: -2688),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 1920, beta: 7360, gamma: -6144, delta: 5888),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -2752, beta: 7232, gamma: 4224, delta: 2816),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -2432, beta: 1088, gamma: -1728, delta: -7424),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -4736, beta: 1344, gamma: 3456, delta: 5056),
  (valid: true, alpha: 1024, beta: -3136, gamma: 8000, delta: -128),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 1600, beta: 6720, gamma: -1856, delta: 1408),
  (valid: true, alpha: 1728, beta: 1984, gamma: 896, delta: 4672),
  (valid: true, alpha: 6400, beta: -5504, gamma: 1472, delta: -7936),
  (valid: true, alpha: 1792, beta: 3072, gamma: -7232, delta: -3200),
  (valid: true, alpha: 192, beta: -3072, gamma: -4928, delta: -7808),
  (valid: true, alpha: 64, beta: 7616, gamma: -6272, delta: 8000),
  (valid: true, alpha: 384, beta: 7296, gamma: -7104, delta: -2112),
  (valid: true, alpha: -320, beta: 7168, gamma: 384, delta: 7232),
  (valid: true, alpha: 1088, beta: -7040, gamma: 2368, delta: 5440),
  (valid: true, alpha: -5376, beta: 2560, gamma: -3200, delta: 128),
  (valid: true, alpha: -7680, beta: 2432, gamma: -4800, delta: -5248),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 5952, beta: 3712, gamma: 640, delta: -3584),
  (valid: true, alpha: -7744, beta: -960, gamma: -4672, delta: -4416),
  (valid: true, alpha: -3520, beta: 2752, gamma: -6912, delta: -3968),
  (valid: true, alpha: -6656, beta: -1664, gamma: 4992, delta: -576),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 5248, beta: -1792, gamma: 1152, delta: -5312),
  (valid: true, alpha: -1792, beta: -832, gamma: -3328, delta: 4800),
  (valid: true, alpha: 2112, beta: -2560, gamma: 7552, delta: -320),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -1920, beta: 8128, gamma: -640, delta: 1984),
  (valid: true, alpha: -3776, beta: 1152, gamma: -6592, delta: -6400),
  (valid: true, alpha: -1792, beta: 448, gamma: -704, delta: -2176),
  (valid: true, alpha: -3264, beta: -192, gamma: 4160, delta: 768),
  (valid: true, alpha: 1600, beta: 6528, gamma: 7680, delta: 3712),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 3200, beta: 5248, gamma: 1216, delta: -3968),
  (valid: true, alpha: 1536, beta: 7296, gamma: -6784, delta: 2688),
  (valid: true, alpha: -1216, beta: 2048, gamma: 6400, delta: -7168),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -1984, beta: -1472, gamma: -7104, delta: 3968),
  (valid: true, alpha: 1088, beta: -3072, gamma: -2816, delta: -4480),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -2880, beta: 7104, gamma: -2944, delta: 4096),
  (valid: true, alpha: 1536, beta: 256, gamma: -4416, delta: 448),
  (valid: true, alpha: -2176, beta: 4288, gamma: -8000, delta: 7936),
  (valid: true, alpha: -5440, beta: -4800, gamma: -7872, delta: 704),
  (valid: true, alpha: 4608, beta: 3136, gamma: 2112, delta: -4288),
  (valid: true, alpha: -128, beta: -1536, gamma: -6016, delta: 7744),
  (valid: true, alpha: 7744, beta: 2368, gamma: -6976, delta: -6784),
  (valid: true, alpha: -4096, beta: 3648, gamma: 4288, delta: 1472),
  (valid: true, alpha: -1408, beta: 3328, gamma: -4224, delta: -7616),
  (valid: true, alpha: 1344, beta: -2432, gamma: 2048, delta: -2496),
  (valid: true, alpha: 3904, beta: 640, gamma: -5824, delta: -5312),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 6784, beta: -832, gamma: 4224, delta: 2752),
  (valid: true, alpha: -128, beta: 3200, gamma: 6464, delta: -7040),
  (valid: true, alpha: -1344, beta: -3392, gamma: 4544, delta: -3136),
  (valid: true, alpha: 2688, beta: -3200, gamma: 256, delta: 2048),
  (valid: true, alpha: -6528, beta: -3520, gamma: -8576, delta: -3072),
  (valid: true, alpha: 3648, beta: 2944, gamma: 7424, delta: -2432),
  (valid: true, alpha: -5504, beta: -1728, gamma: -6912, delta: -6528),
  (valid: true, alpha: -4352, beta: -5120, gamma: 8384, delta: -5184),
  (valid: true, alpha: -6656, beta: -1472, gamma: -832, delta: 576),
  (valid: true, alpha: 4736, beta: -5184, gamma: -5888, delta: -6848),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -2048, beta: -1280, gamma: 1600, delta: 2560),
  (valid: true, alpha: -7616, beta: 1344, gamma: -3456, delta: 7680),
  (valid: true, alpha: -192, beta: 2432, gamma: 3328, delta: -6976),
  (valid: true, alpha: -5568, beta: 3136, gamma: 4352, delta: -7104),
  (valid: true, alpha: 1920, beta: -1792, gamma: 2432, delta: -7040),
  (valid: true, alpha: 768, beta: 4992, gamma: 7616, delta: -5248),
  (valid: true, alpha: 4672, beta: -5632, gamma: 2624, delta: 6976),
  (valid: true, alpha: 2368, beta: -7040, gamma: 5376, delta: 3968),
  (valid: true, alpha: -7168, beta: -704, gamma: 1984, delta: 6272),
  (valid: true, alpha: -2176, beta: -2944, gamma: 5376, delta: 3584),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 7040, beta: -4480, gamma: 2304, delta: 4992),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 2048, beta: 3840, gamma: -5376, delta: 1408),
  (valid: true, alpha: -2752, beta: 2176, gamma: 6144, delta: -5632),
  (valid: true, alpha: -1216, beta: -3840, gamma: 1920, delta: 4160),
  (valid: true, alpha: 5696, beta: 5440, gamma: 1216, delta: 2752),
  (valid: true, alpha: 1408, beta: -3776, gamma: -1792, delta: 1024),
  (valid: true, alpha: 1920, beta: -4544, gamma: 1088, delta: -6400),
  (valid: true, alpha: -3968, beta: 3840, gamma: 8704, delta: -5376),
  (valid: true, alpha: 5568, beta: 6016, gamma: -1856, delta: 4800),
  (valid: true, alpha: -1408, beta: -2112, gamma: -7744, delta: -8448),
  (valid: true, alpha: 4096, beta: -5568, gamma: -4864, delta: -7488),
  (valid: true, alpha: -7360, beta: 4288, gamma: 6272, delta: -7936),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 3008, beta: -7296, gamma: 4800, delta: 6784),
  (valid: true, alpha: -8192, beta: -2688, gamma: 4800, delta: -1088),
  (valid: true, alpha: -1856, beta: 3072, gamma: 576, delta: -6144),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -3328, beta: 1344, gamma: 6656, delta: -1792),
  (valid: true, alpha: -3136, beta: -2880, gamma: 6080, delta: 576),
  (valid: true, alpha: -2176, beta: 2368, gamma: 5760, delta: -8320),
  (valid: true, alpha: -256, beta: 6400, gamma: -3584, delta: -1984),
  (valid: true, alpha: -896, beta: 1472, gamma: 1344, delta: -6720),
  (valid: true, alpha: 960, beta: -2048, gamma: 6528, delta: -7296),
  (valid: true, alpha: 7872, beta: -1472, gamma: -1408, delta: 64),
  (valid: true, alpha: 4352, beta: 3648, gamma: 704, delta: -4928),
  (valid: true, alpha: 832, beta: 5376, gamma: 6272, delta: 7552),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -5888, beta: -256, gamma: -7040, delta: -5440),
  (valid: true, alpha: 1408, beta: -2432, gamma: -1216, delta: 5760),
  (valid: true, alpha: 7680, beta: 1408, gamma: 2432, delta: 2112),
  (valid: true, alpha: 2688, beta: -128, gamma: -2048, delta: -896),
  (valid: true, alpha: -3328, beta: 6848, gamma: -7040, delta: 5952),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -1792, beta: -2752, gamma: -256, delta: -4672),
  (valid: true, alpha: 2176, beta: 3776, gamma: -64, delta: -6720),
  (valid: true, alpha: -1024, beta: 5504, gamma: 3328, delta: -1344),
  (valid: true, alpha: 6912, beta: 1472, gamma: -3712, delta: -3712),
  (valid: true, alpha: 4096, beta: -2112, gamma: 6016, delta: 1216),
  (valid: true, alpha: -2688, beta: -4480, gamma: -2816, delta: -896),
  (valid: true, alpha: -1280, beta: -3648, gamma: -1472, delta: -1280),
  (valid: true, alpha: 896, beta: -1664, gamma: 7424, delta: -3968),
  (valid: true, alpha: -1216, beta: 384, gamma: -4416, delta: 256),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -640, beta: -1472, gamma: 3200, delta: -3392),
  (valid: true, alpha: 5184, beta: -5760, gamma: -4544, delta: -5760),
  (valid: true, alpha: -4032, beta: 4928, gamma: 1664, delta: 6016),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -3520, beta: 640, gamma: -256, delta: -320),
  (valid: true, alpha: 3008, beta: 2816, gamma: -1216, delta: 7616),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -3904, beta: 7104, gamma: -1920, delta: -5952),
  (valid: true, alpha: -2752, beta: 1664, gamma: 6784, delta: 2752),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: -4480, beta: 4160, gamma: 2368, delta: -2240),
  (valid: true, alpha: 6592, beta: 3456, gamma: -1408, delta: -4032),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 4992, beta: 3200, gamma: 5504, delta: 5760),
  (valid: true, alpha: -2624, beta: -2944, gamma: -1280, delta: -3200),
  (valid: true, alpha: -8128, beta: 2304, gamma: 64, delta: 5568),
  (valid: true, alpha: 1856, beta: 896, gamma: 4032, delta: 7040),
  (valid: true, alpha: 2880, beta: 1472, gamma: -5952, delta: 8000),
  (valid: false, alpha: 0, beta: 0, gamma: 0, delta: 0),
  (valid: true, alpha: 7104, beta: 3072, gamma: -2176, delta: -4352),
];
const _t4 =
    <
      ({bool valid, int alpha, int beta, int gamma, int delta, List<int> block})
    >[
      (
        valid: true,
        alpha: 64,
        beta: 0,
        gamma: 0,
        delta: 64,
        block: [
          119,
          95,
          147,
          91,
          146,
          255,
          112,
          29,
          102,
          79,
          121,
          99,
          114,
          196,
          0,
          141,
          123,
          95,
          168,
          104,
          169,
          197,
          246,
          112,
          94,
          194,
          150,
          197,
          54,
          46,
          116,
          10,
          67,
          66,
          182,
          47,
          73,
          92,
          42,
          192,
          239,
          199,
          159,
          79,
          180,
          141,
          160,
          132,
          161,
          133,
          80,
          78,
          154,
          139,
          22,
          136,
          107,
          138,
          31,
          6,
          127,
          194,
          163,
          255,
        ],
      ),
      (
        valid: true,
        alpha: 0,
        beta: 0,
        gamma: 0,
        delta: 0,
        block: [
          173,
          72,
          107,
          182,
          138,
          99,
          99,
          98,
          53,
          54,
          76,
          165,
          192,
          115,
          3,
          120,
          148,
          203,
          78,
          6,
          104,
          102,
          48,
          68,
          56,
          65,
          174,
          174,
          142,
          92,
          0,
          72,
          33,
          69,
          85,
          185,
          202,
          183,
          118,
          156,
          241,
          254,
          155,
          42,
          78,
          131,
          85,
          97,
          110,
          165,
          77,
          36,
          114,
          174,
          173,
          47,
          69,
          99,
          128,
          128,
          161,
          214,
          255,
          221,
        ],
      ),
      (
        valid: true,
        alpha: 128,
        beta: -64,
        gamma: 64,
        delta: 128,
        block: [
          50,
          148,
          232,
          64,
          110,
          186,
          0,
          119,
          26,
          82,
          12,
          123,
          93,
          158,
          198,
          174,
          94,
          47,
          143,
          182,
          120,
          63,
          161,
          131,
          77,
          37,
          187,
          159,
          29,
          70,
          62,
          188,
          255,
          109,
          81,
          255,
          113,
          73,
          144,
          135,
          166,
          126,
          196,
          190,
          107,
          73,
          233,
          144,
          82,
          81,
          175,
          211,
          155,
          90,
          41,
          156,
          161,
          135,
          124,
          148,
          178,
          199,
          0,
          123,
        ],
      ),
      (
        valid: true,
        alpha: -1920,
        beta: 0,
        gamma: 0,
        delta: -1920,
        block: [
          88,
          148,
          201,
          161,
          129,
          171,
          169,
          194,
          81,
          71,
          208,
          210,
          135,
          145,
          255,
          165,
          90,
          164,
          176,
          132,
          158,
          19,
          102,
          110,
          53,
          208,
          92,
          168,
          21,
          55,
          153,
          122,
          70,
          63,
          22,
          12,
          136,
          101,
          183,
          0,
          157,
          140,
          130,
          135,
          255,
          0,
          70,
          68,
          206,
          203,
          92,
          183,
          146,
          123,
          200,
          51,
          170,
          138,
          70,
          0,
          36,
          144,
          245,
          127,
        ],
      ),
      (
        valid: true,
        alpha: -1792,
        beta: 64,
        gamma: -64,
        delta: -1792,
        block: [
          212,
          131,
          53,
          194,
          215,
          122,
          236,
          46,
          127,
          201,
          253,
          169,
          75,
          188,
          37,
          96,
          103,
          9,
          113,
          116,
          97,
          5,
          145,
          182,
          238,
          219,
          0,
          10,
          181,
          225,
          52,
          244,
          185,
          44,
          194,
          188,
          234,
          114,
          122,
          252,
          136,
          44,
          151,
          176,
          217,
          130,
          204,
          91,
          133,
          160,
          52,
          101,
          196,
          39,
          101,
          197,
          248,
          212,
          110,
          4,
          200,
          177,
          54,
          50,
        ],
      ),
      (
        valid: true,
        alpha: -3584,
        beta: 64,
        gamma: -64,
        delta: -3584,
        block: [
          79,
          92,
          193,
          148,
          67,
          59,
          185,
          159,
          73,
          55,
          128,
          255,
          168,
          29,
          112,
          131,
          67,
          119,
          58,
          52,
          119,
          70,
          101,
          4,
          110,
          114,
          145,
          73,
          75,
          166,
          169,
          52,
          206,
          62,
          149,
          159,
          120,
          184,
          184,
          197,
          135,
          34,
          161,
          78,
          53,
          87,
          87,
          88,
          189,
          255,
          81,
          38,
          170,
          163,
          214,
          176,
          105,
          93,
          112,
          89,
          170,
          225,
          241,
          187,
        ],
      ),
      (
        valid: true,
        alpha: -7040,
        beta: 0,
        gamma: 0,
        delta: -7040,
        block: [
          193,
          81,
          153,
          53,
          108,
          134,
          145,
          244,
          196,
          135,
          73,
          23,
          198,
          207,
          84,
          191,
          162,
          53,
          81,
          199,
          223,
          219,
          139,
          151,
          83,
          129,
          184,
          50,
          130,
          255,
          252,
          231,
          2,
          85,
          184,
          156,
          128,
          219,
          247,
          83,
          190,
          65,
          229,
          237,
          180,
          185,
          150,
          68,
          197,
          39,
          128,
          165,
          88,
          162,
          145,
          0,
          122,
          135,
          155,
          229,
          82,
          86,
          147,
          63,
        ],
      ),
      (
        valid: true,
        alpha: -4864,
        beta: 0,
        gamma: 0,
        delta: -4864,
        block: [
          130,
          135,
          204,
          133,
          82,
          149,
          236,
          85,
          186,
          223,
          116,
          32,
          43,
          186,
          74,
          57,
          178,
          236,
          135,
          143,
          40,
          69,
          121,
          217,
          23,
          185,
          210,
          207,
          87,
          23,
          228,
          70,
          120,
          204,
          185,
          103,
          98,
          39,
          255,
          52,
          156,
          81,
          102,
          146,
          42,
          69,
          157,
          101,
          145,
          1,
          120,
          137,
          30,
          64,
          166,
          48,
          77,
          16,
          128,
          147,
          139,
          78,
          137,
          6,
        ],
      ),
    ];
const _t5Window = [
  48,
  6,
  194,
  4,
  4,
  0,
  65,
  20,
  0,
  0,
  1,
  65,
  250,
  14,
  79,
  251,
  182,
  255,
  99,
  64,
  232,
  27,
  175,
  82,
  231,
  239,
  253,
  117,
  221,
  197,
  191,
  15,
  54,
  61,
  89,
  187,
  191,
  9,
  89,
  183,
  169,
  12,
  108,
  197,
  5,
  172,
  112,
  34,
  78,
  232,
  83,
  228,
  83,
  34,
  126,
  223,
  246,
  34,
  148,
  99,
  12,
  206,
  92,
  211,
  130,
  80,
  169,
  14,
  94,
  250,
  179,
  11,
  140,
  81,
  80,
  53,
  116,
  234,
  27,
  1,
  18,
  214,
  39,
  157,
  112,
  170,
  110,
  227,
  197,
  116,
  28,
  87,
  186,
  107,
  188,
  189,
];
const _t5GmType = [0, 0, 0, 2, 0, 0, 0];
const _t5GmParams = [
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [1010688, 930816, 65632, -42, 42, 65632],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
];
const _t5RefPP = [
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
  [0, 0, 65536, 0, 0, 65536],
];
const _t5Seq = (
  reducedStillPicture: false,
  frameIdNumbersPresent: false,
  deltaFrameIdLengthMinus2: 0,
  additionalFrameIdLengthMinus1: 0,
  seqForceScreenContentTools: 2,
  seqForceIntegerMv: 2,
  orderHintBits: 7,
  enableOrderHint: true,
  decoderModelInfoPresent: false,
  frameWidthBitsMinus1: 7,
  frameHeightBitsMinus1: 7,
  maxFrameWidthMinus1: 191,
  maxFrameHeightMinus1: 191,
  enableSuperres: false,
  use128x128Superblock: false,
  numPlanes: 3,
  separateUvDeltaQ: false,
  enableCdef: false,
  enableRestoration: false,
  subsamplingX: 1,
  subsamplingY: 1,
  filmGrainParamsPresent: false,
  enableRefFrameMvs: false,
  enableWarpedMotion: false,
);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'HarborGmParams == SW decodeGlobalMotionParams (subexp header decode)',
    () async {
      const maxBytes = 160;
      final dut = HarborGmParams(maxBytes: maxBytes);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final allowHp = Logic(name: 'allow_hp');
      final refParams = Logic(name: 'ref_params', width: 7 * 6 * 32);
      final baseOff = Logic(
        name: 'base_off',
        width: dut.input('base_offset').width,
      );
      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('start').srcConnection! <= start;
      dut.input('bytes').srcConnection! <= bytes;
      dut.input('allow_high_precision_mv').srcConnection! <= allowHp;
      dut.input('base_offset').srcConnection! <= baseOff;
      dut.input('ref_params').srcConnection! <= refParams;
      await dut.build();
      Simulator.setMaxSimTime(2000000000);
      unawaited(Simulator.run());

      final rng = Random(0x6D0);
      var checked = 0;
      final typeSeen = <int>{};
      for (var iter = 0; iter < 40; iter++) {
        // Random header bits (any pattern is a valid subexp decode).
        final buf = List<int>.generate(maxBytes, (_) => rng.nextInt(256));
        // Realistic per-ref primary-ref saved models.
        final rp = List<List<int>>.generate(7, (_) {
          return [
            rng.nextInt(1 << 21) - (1 << 20), // trans
            rng.nextInt(1 << 21) - (1 << 20),
            (1 << 16) + (rng.nextInt(16385) - 8192), // diag
            rng.nextInt(16385) - 8192, // ndiag
            rng.nextInt(16385) - 8192,
            (1 << 16) + (rng.nextInt(16385) - 8192),
          ];
        });
        final hp = rng.nextBool();

        // Golden (captured from SW decodeGlobalMotionParams).
        final res = _t1[iter];

        // Drive HW.
        var bpk = BigInt.zero;
        for (var i = 0; i < maxBytes; i++) {
          bpk |= BigInt.from(buf[i] & 0xFF) << (i * 8);
        }
        var rpk = BigInt.zero;
        for (var ref = 0; ref < 7; ref++) {
          for (var j = 0; j < 6; j++) {
            rpk |= BigInt.from(_fit(rp[ref][j], 32)) << ((ref * 6 + j) * 32);
          }
        }
        reset.inject(1);
        start.inject(0);
        bytes.inject(bpk);
        allowHp.inject(hp ? 1 : 0);
        baseOff.inject(0);
        refParams.inject(rpk);
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (dut.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 20000) fail('gm_params timeout iter=$iter');
        }

        // Compare all 7 refs (LAST..ALTREF == SW ref 1..7, HW ref 0..6).
        for (var hwRef = 0; hwRef < 7; hwRef++) {
          final swRef = hwRef + 1;
          final ty = dut.output('gm_type_$hwRef').value.toInt();
          expect(
            ty,
            equals(res.gmType[hwRef]),
            reason: 'iter=$iter ref=$swRef type',
          );
          typeSeen.add(ty);
          for (var j = 0; j < 6; j++) {
            final hv = _asSigned(
              dut.output('mat_${hwRef}_$j').value.toInt(),
              32,
            );
            expect(
              hv,
              equals(res.gmParams[hwRef][j]),
              reason: 'iter=$iter ref=$swRef mat$j hp=$hp rp=${rp[hwRef]}',
            );
          }
        }
        expect(
          dut.output('bits_consumed').value.toInt(),
          equals(res.bitsConsumed),
          reason: 'iter=$iter bits_consumed',
        );
        checked++;
      }
      expect(checked, equals(40));
      // Ensure the corpus exercised more than pure IDENTITY.
      expect(
        typeSeen.length,
        greaterThan(1),
        reason: 'types exercised: $typeSeen',
      );
      await Simulator.endSimulation();
    },
  );

  test(
    'HarborGlobalMv == SW gm_get_motion_vector (IDENTITY/TRANS/ROTZOOM/AFFINE)',
    () async {
      final dut = HarborGlobalMv();
      final clk = SimpleClockGenerator(10).clk;
      final ports = <String, Logic>{};
      void mk(String n, int w) {
        final l = Logic(name: n, width: w);
        dut.input(n).srcConnection! <= l;
        ports[n] = l;
      }

      for (var i = 0; i < 6; i++) {
        mk('mat$i', 32);
      }
      mk('gm_type', 2);
      mk('block_wide', 8);
      mk('block_high', 8);
      mk('mi_r', 16);
      mk('mi_c', 16);
      mk('allow_hp', 1);
      mk('force_integer', 1);
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      final rng = Random(0x6109);
      // valid AV1 block sizes (BLOCK_4X4 .. BLOCK_128X128 and rects) that carry a
      // global MV, skip degenerate. Use the whole table range present.
      final bSizes = [for (var b = 0; b < _blockSizeWide.length; b++) b];

      var checked = 0;
      for (var iter = 0; iter < 400; iter++) {
        // Build a random model. Type mix across all four.
        final type = iter < 4
            ? iter // guarantee one of each early
            : rng.nextInt(4);
        final mat = List<int>.filled(6, 0);
        mat[2] = 1 << 16;
        mat[5] = 1 << 16;
        if (iter % 3 == 0 && type >= 2) {
          // real captured ROTZOOM matrix
          final r = _realRotzoom[rng.nextInt(_realRotzoom.length)];
          for (var i = 0; i < 6; i++) {
            mat[i] = r[i];
          }
        } else {
          // synthetic: trans large, diag near 2^16, ndiag small.
          mat[0] = rng.nextInt(1 << 21) - (1 << 20);
          mat[1] = rng.nextInt(1 << 21) - (1 << 20);
          if (type >= 2) {
            mat[2] = (1 << 16) + (rng.nextInt(8193) - 4096);
            mat[3] = rng.nextInt(8193) - 4096;
            if (type >= 3) {
              mat[4] = rng.nextInt(8193) - 4096;
              mat[5] = (1 << 16) + (rng.nextInt(8193) - 4096);
            } else {
              mat[4] = -mat[3];
              mat[5] = mat[2];
            }
          }
        }

        final bSize = bSizes[rng.nextInt(bSizes.length)];
        final r = rng.nextInt(240);
        final c = rng.nextInt(240);
        final allowHp = rng.nextBool();
        final forceInt = rng.nextBool();

        // Golden (captured from SW gmGetMotionVector).
        final gold = _t2[iter];

        // Drive HW.
        ports['gm_type']!.put(type);
        for (var i = 0; i < 6; i++) {
          ports['mat$i']!.put(_fit(mat[i], 32));
        }
        ports['block_wide']!.put(_blockSizeWide[bSize]);
        ports['block_high']!.put(_blockSizeHigh[bSize]);
        ports['mi_r']!.put(r);
        ports['mi_c']!.put(c);
        ports['allow_hp']!.put(allowHp ? 1 : 0);
        ports['force_integer']!.put(forceInt ? 1 : 0);
        await clk.nextPosedge;

        final mvRow = _asSigned(dut.output('mv_row').value.toInt(), 32);
        final mvCol = _asSigned(dut.output('mv_col').value.toInt(), 32);
        expect(
          [mvRow, mvCol],
          equals(gold),
          reason:
              'iter=$iter type=$type bSize=$bSize r=$r c=$c '
              'hp=$allowHp int=$forceInt mat=$mat',
        );
        checked++;
      }
      expect(checked, equals(400));
      await Simulator.endSimulation();
    },
  );

  test('HarborGlobalWarpModel == SW globalWarpModel shear + valid', () async {
    final dut = HarborGlobalWarpModel();
    final clk = SimpleClockGenerator(10).clk;
    final mats = [for (var i = 0; i < 6; i++) Logic(name: 'mat$i', width: 32)];
    for (var i = 0; i < 6; i++) {
      dut.input('mat$i').srcConnection! <= mats[i];
    }
    await dut.build();
    Simulator.setMaxSimTime(600000000);
    unawaited(Simulator.run());

    final rng = Random(0x5EA);
    var checked = 0;
    for (var iter = 0; iter < 300; iter++) {
      final mat = List<int>.filled(6, 0);
      mat[2] = 1 << 16;
      mat[5] = 1 << 16;
      if (iter < _realRotzoom.length) {
        for (var i = 0; i < 6; i++) {
          mat[i] = _realRotzoom[iter][i];
        }
      } else {
        mat[0] = rng.nextInt(1 << 21) - (1 << 20);
        mat[1] = rng.nextInt(1 << 21) - (1 << 20);
        mat[2] = (1 << 16) + (rng.nextInt(16385) - 8192);
        mat[3] = rng.nextInt(16385) - 8192;
        mat[4] = rng.nextInt(16385) - 8192;
        mat[5] = (1 << 16) + (rng.nextInt(16385) - 8192);
      }

      final wm = _t3[iter];
      for (var i = 0; i < 6; i++) {
        mats[i].put(_fit(mat[i], 32));
      }
      await clk.nextPosedge;

      final valid = dut.output('valid').value.toInt() == 1;
      expect(valid, equals(wm.valid), reason: 'iter=$iter mat=$mat');
      if (wm.valid) {
        expect(
          _asSigned(dut.output('alpha').value.toInt(), 16),
          equals(wm.alpha),
          reason: 'alpha iter=$iter mat=$mat',
        );
        expect(
          _asSigned(dut.output('beta').value.toInt(), 16),
          equals(wm.beta),
          reason: 'beta iter=$iter mat=$mat',
        );
        expect(
          _asSigned(dut.output('gamma').value.toInt(), 16),
          equals(wm.gamma),
          reason: 'gamma iter=$iter mat=$mat',
        );
        expect(
          _asSigned(dut.output('delta').value.toInt(), 16),
          equals(wm.delta),
          reason: 'delta iter=$iter mat=$mat',
        );
      }
      checked++;
    }
    expect(checked, equals(300));
    await Simulator.endSimulation();
  });

  test(
    'global warp MC: HarborWarpAffine(global shear) == SW warpAffine block',
    () async {
      // Composition: global model -> shear (proven above) -> HarborWarpAffine.
      // Compare an 8x8 warped block against SW warpAffine driven by the same global
      // matrix over a synthetic reference frame.
      final dut = HarborWarpAffine();
      final clk = SimpleClockGenerator(10).clk;
      final patch = Logic(name: 'patch', width: 15 * 15 * 8);
      final sx4 = Logic(name: 'sx4', width: 20);
      final sy4 = Logic(name: 'sy4', width: 20);
      final alpha = Logic(name: 'alpha', width: 16);
      final beta = Logic(name: 'beta', width: 16);
      final gamma = Logic(name: 'gamma', width: 16);
      final delta = Logic(name: 'delta', width: 16);
      dut.input('patch').srcConnection! <= patch;
      dut.input('sx4').srcConnection! <= sx4;
      dut.input('sy4').srcConnection! <= sy4;
      dut.input('alpha').srcConnection! <= alpha;
      dut.input('beta').srcConnection! <= beta;
      dut.input('gamma').srcConnection! <= gamma;
      dut.input('delta').srcConnection! <= delta;
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      const w = 64, h = 64;
      final rng = Random(0xBEEF);
      var checked = 0;
      for (var iter = 0; iter < _realRotzoom.length; iter++) {
        final mat = List<int>.from(_realRotzoom[iter]);
        final wm = _t4[iter];
        if (!wm.valid) continue; // model rejects fast-filter (fallback path)

        // Synthetic reference frame.
        final ref = List<List<int>>.generate(
          h,
          (_) => [for (var x = 0; x < w; x++) rng.nextInt(256)],
        );

        // Block origin inside the frame (multiple of 8, leaving warp support).
        final pRow = 8 + 8 * rng.nextInt(3);
        final pCol = 8 + 8 * rng.nextInt(3);

        // Per-8x8 setup exactly as SW warpAffine (subX=subY=0).
        const prec = 16;
        final srcX = (pCol + 4);
        final srcY = (pRow + 4);
        final dstX = mat[2] * srcX + mat[3] * srcY + mat[0];
        final dstY = mat[4] * srcX + mat[5] * srcY + mat[1];
        final ix4 = dstX >> prec;
        final iy4 = dstY >> prec;
        var sxv = (dstX & ((1 << prec) - 1)) + wm.alpha * -4 + wm.beta * -4;
        var syv = (dstY & ((1 << prec) - 1)) + wm.gamma * -4 + wm.delta * -4;
        sxv &= ~63;
        syv &= ~63;

        // 15x15 edge-clamped patch: patch[r][c] = ref[clamp(iy4-7+r)][clamp(ix4-7+c)].
        int clampI(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
        final px = List<int>.filled(15 * 15, 0);
        for (var rr = 0; rr < 15; rr++) {
          for (var cc = 0; cc < 15; cc++) {
            final yy = clampI(iy4 - 7 + rr, 0, h - 1);
            final xx = clampI(ix4 - 7 + cc, 0, w - 1);
            px[rr * 15 + cc] = ref[yy][xx];
          }
        }

        var packed = BigInt.zero;
        for (var i = 0; i < px.length; i++) {
          packed |= BigInt.from(px[i]) << (i * 8);
        }
        patch.put(packed);
        sx4.put(_fit(sxv, 20));
        sy4.put(_fit(syv, 20));
        alpha.put(_fit(wm.alpha, 16));
        beta.put(_fit(wm.beta, 16));
        gamma.put(_fit(wm.gamma, 16));
        delta.put(_fit(wm.delta, 16));
        await clk.nextPosedge;

        final pv = dut.output('pred').value;
        for (var k = 0; k < 64; k++) {
          expect(
            pv.getRange(k * 8, k * 8 + 8).toInt(),
            equals(wm.block[k]),
            reason: 'iter=$iter k=$k mat=$mat',
          );
        }
        checked++;
      }
      expect(checked, greaterThanOrEqualTo(1));
      await Simulator.endSimulation();
    },
  );

  // End-to-end header parse on a REAL aomenc global-motion stream: the full
  // HarborFrameHeaderParse FSM (inter path + nested gm subexp FSM) must reproduce
  // SW parseFrameHeader gm_type / gm_params for the frame that fired a
  // non-identity (ROTZOOM) global model. Reads a conservative aomenc 3.12.1 OBU
  // stream from the scratchpad, skips gracefully if it is absent.
  test(
    'HarborFrameHeaderParse end-to-end: real ROTZOOM gm frame bit-exact',
    () async {
      // Golden captured from the SW decode of a real aomenc ROTZOOM gm stream:
      // the 96-byte frame-header window, the parsed gm_type / gm_params, the
      // resolved primary-ref params, and the sequence-header fields.
      const maxBytes = 96;
      const window = _t5Window;
      const seq = _t5Seq;

      final p = HarborFrameHeaderParse(maxBytes: maxBytes);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      void ci(String port, Logic sig) => p.input(port).srcConnection! <= sig;
      ci('clk', clk);
      ci('reset', reset);
      ci('start', start);
      ci('bytes', bytes);

      final ins = <String, Logic>{};
      Logic mkc(String port, int w) {
        final l = Logic(name: 'i_$port', width: w);
        ci(port, l);
        ins[port] = l;
        return l;
      }

      mkc('seq_reduced_still_picture', 1);
      mkc('seq_frame_id_numbers_present', 1);
      mkc('seq_delta_frame_id_length_minus2', 4);
      mkc('seq_additional_frame_id_length_minus1', 3);
      mkc('seq_force_screen_content_tools', 2);
      mkc('seq_force_integer_mv', 2);
      mkc('seq_order_hint_bits', 4);
      mkc('seq_enable_order_hint', 1);
      mkc('seq_decoder_model_info_present', 1);
      mkc('seq_frame_width_bits_minus1', 4);
      mkc('seq_frame_height_bits_minus1', 4);
      mkc('seq_max_frame_width_minus1', 32);
      mkc('seq_max_frame_height_minus1', 32);
      mkc('seq_enable_superres', 1);
      mkc('seq_use_128x128_superblock', 1);
      mkc('seq_num_planes', 2);
      mkc('seq_separate_uv_delta_q', 1);
      mkc('seq_enable_cdef', 1);
      mkc('seq_enable_restoration', 1);
      mkc('seq_subsampling_x', 1);
      mkc('seq_subsampling_y', 1);
      mkc('seq_film_grain_params_present', 1);
      mkc('seq_enable_ref_frame_mvs', 1);
      mkc('seq_enable_warped_motion', 1);
      mkc('shown_frame_type', 2);
      mkc('shown_order_hint', 8);
      final gmRef = mkc('gm_ref_params', 7 * 6 * 32);

      await p.build();

      BigInt pack(List<int> b) {
        var v = BigInt.zero;
        for (var i = 0; i < b.length; i++) {
          v |= BigInt.from(b[i] & 0xFF) << (i * 8);
        }
        return v;
      }

      void inj(String port, int v) => ins[port]!.inject(v);
      reset.inject(1);
      start.inject(0);
      bytes.inject(pack(window));
      inj('seq_reduced_still_picture', seq.reducedStillPicture ? 1 : 0);
      inj('seq_frame_id_numbers_present', seq.frameIdNumbersPresent ? 1 : 0);
      inj('seq_delta_frame_id_length_minus2', seq.deltaFrameIdLengthMinus2);
      inj(
        'seq_additional_frame_id_length_minus1',
        seq.additionalFrameIdLengthMinus1,
      );
      inj('seq_force_screen_content_tools', seq.seqForceScreenContentTools);
      inj('seq_force_integer_mv', seq.seqForceIntegerMv);
      inj('seq_order_hint_bits', seq.orderHintBits);
      inj('seq_enable_order_hint', seq.enableOrderHint ? 1 : 0);
      inj(
        'seq_decoder_model_info_present',
        seq.decoderModelInfoPresent ? 1 : 0,
      );
      inj('seq_frame_width_bits_minus1', seq.frameWidthBitsMinus1);
      inj('seq_frame_height_bits_minus1', seq.frameHeightBitsMinus1);
      inj('seq_max_frame_width_minus1', seq.maxFrameWidthMinus1);
      inj('seq_max_frame_height_minus1', seq.maxFrameHeightMinus1);
      inj('seq_enable_superres', seq.enableSuperres ? 1 : 0);
      inj('seq_use_128x128_superblock', seq.use128x128Superblock ? 1 : 0);
      inj('seq_num_planes', seq.numPlanes);
      inj('seq_separate_uv_delta_q', seq.separateUvDeltaQ ? 1 : 0);
      inj('seq_enable_cdef', seq.enableCdef ? 1 : 0);
      inj('seq_enable_restoration', seq.enableRestoration ? 1 : 0);
      inj('seq_subsampling_x', seq.subsamplingX);
      inj('seq_subsampling_y', seq.subsamplingY);
      inj('seq_film_grain_params_present', seq.filmGrainParamsPresent ? 1 : 0);
      inj('seq_enable_ref_frame_mvs', seq.enableRefFrameMvs ? 1 : 0);
      inj('seq_enable_warped_motion', seq.enableWarpedMotion ? 1 : 0);
      inj('shown_frame_type', 0);
      inj('shown_order_hint', 0);
      var rpk = BigInt.zero;
      for (var ref = 0; ref < 7; ref++) {
        for (var j = 0; j < 6; j++) {
          rpk |=
              BigInt.from(_fit(_t5RefPP[ref][j], 32)) << ((ref * 6 + j) * 32);
        }
      }
      gmRef.inject(rpk);

      Simulator.setMaxSimTime(400000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (p.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 8000) fail('header parse timeout');
      }

      expect(
        p.output('unsupported').value.toInt(),
        equals(0),
        reason: 'real gm inter header must be supported',
      );
      for (var hwRef = 0; hwRef < 7; hwRef++) {
        final swRef = hwRef + 1;
        expect(
          p.output('gm_type_$hwRef').value.toInt(),
          equals(_t5GmType[hwRef]),
          reason: 'gm_type ref=$swRef',
        );
        for (var j = 0; j < 6; j++) {
          expect(
            _asSigned(p.output('gm_mat_${hwRef}_$j').value.toInt(), 32),
            equals(_t5GmParams[hwRef][j]),
            reason: 'gm_mat ref=$swRef j=$j',
          );
        }
      }
      await Simulator.endSimulation();
    },
  );
}
