import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborRetainer', () {
    test('no holds completes immediately', () async {
      final r = HarborRetainer();
      await r.wait;
    });

    test('single hold', () async {
      final r = HarborRetainer();
      final hold = r.apply();

      expect(hold.isReleased, isFalse);
      hold.release();
      expect(hold.isReleased, isTrue);

      await r.wait;
    });

    test('multiple holds all must release', () async {
      final r = HarborRetainer();
      final h1 = r.apply();
      final h2 = r.apply();
      final h3 = r.apply();

      h1.release();
      h2.release();
      // Not done yet, h3 still held
      h3.release();

      await r.wait;
    });

    test('wait suspends until all released', () async {
      final r = HarborRetainer();
      final h1 = r.apply();
      final h2 = r.apply();
      final log = <String>[];

      final waiter = r.wait.then((_) => log.add('done'));

      log.add('release_h1');
      h1.release();

      // Yield to let microtasks run
      await Future<void>.delayed(Duration.zero);
      expect(log, equals(['release_h1']));

      log.add('release_h2');
      h2.release();

      await waiter;
      expect(log, equals(['release_h1', 'release_h2', 'done']));
    });

    test('double release throws', () {
      final r = HarborRetainer();
      final hold = r.apply();
      hold.release();
      expect(() => hold.release(), throwsStateError);
    });
  });
}
