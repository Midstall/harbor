import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The output-type selector accepts every HarborDisplayInterface value (so
/// genip can offer all of them) but only validates the ones with a built
/// backend. DVI and HDMI ride the TMDS transmitter. VGA and DisplayPort are
/// accepted in the type system but rejected with a clear error for now.
void main() {
  group('display output support', () {
    test('dvi and hdmi are supported', () {
      expect(isDisplayOutputSupported(HarborDisplayInterface.dvi), isTrue);
      expect(isDisplayOutputSupported(HarborDisplayInterface.hdmi), isTrue);
    });

    test('vga, displayPort, and friends are not supported yet', () {
      expect(isDisplayOutputSupported(HarborDisplayInterface.vga), isFalse);
      expect(
        isDisplayOutputSupported(HarborDisplayInterface.displayPort),
        isFalse,
      );
    });

    test('require throws for unsupported and passes for supported', () {
      expect(
        () => requireDisplayOutputSupported(HarborDisplayInterface.displayPort),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => requireDisplayOutputSupported(HarborDisplayInterface.hdmi),
        returnsNormally,
      );
    });
  });

  test('HarborFramebufferDisplay rejects an unsupported output type', () {
    Logic l([int w = 1]) => Logic(width: w);
    expect(
      () => HarborFramebufferDisplay(
        target: const HarborSimTarget(),
        timing: const HarborDisplayTiming.vga640x480(),
        pixelClk: l(),
        pixelReset: l(),
        shiftClk: l(),
        shiftReset: l(),
        enable: l(),
        fbBase: l(32),
        mDataIn: l(32),
        mAck: l(),
        outputType: HarborDisplayInterface.displayPort,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
