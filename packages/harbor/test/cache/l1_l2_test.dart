import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborL1ICache', () {
    test('creates direct-mapped with word-wide serve + paced refill', () {
      final cache = HarborL1ICache(
        config: const HarborL1iCacheConfig(size: 4096, ways: 1, lineSize: 8),
        xlen: 64,
      );
      expect(cache.reqAddr.width, equals(64));
      expect(cache.reqValid.width, equals(1));
      // One machine word is served per fetch, not a whole line.
      expect(cache.respData.width, equals(64));
      expect(cache.respValid.width, equals(1));
      expect(cache.miss.width, equals(1));
      // Word-granular refill handshake to the MMU ifetch port.
      expect(cache.memEn.width, equals(1));
      expect(cache.memAddr.width, equals(64));
      expect(cache.memRdata.width, equals(64));
    });

    test('rejects set-associative config (direct-mapped only)', () {
      expect(
        () => HarborL1ICache(
          config: const HarborL1iCacheConfig(size: 4096, ways: 2),
        ),
        throwsArgumentError,
      );
    });
  });

  group('HarborL1DCache', () {
    test('creates with word-granular read/write memory port', () {
      final cache = HarborL1DCache(
        config: const HarborL1dCacheConfig(size: 4096, ways: 1, lineSize: 8),
        xlen: 64,
      );
      expect(cache.reqAddr.width, equals(64));
      expect(cache.reqWrite.width, equals(1));
      expect(cache.reqData.width, equals(64));
      expect(cache.respData.width, equals(64));
      expect(cache.memWe.width, equals(1));
      expect(cache.memWdata.width, equals(64));
      expect(cache.memSize.width, equals(3));
    });

    test('rejects set-associative config (direct-mapped only)', () {
      expect(
        () => HarborL1DCache(
          config: const HarborL1dCacheConfig(size: 4096, ways: 2),
        ),
        throwsArgumentError,
      );
    });
  });

  group('HarborL2Cache', () {
    test('creates with 2 requestors', () {
      final cache = HarborL2Cache(
        config: const HarborCacheConfig(size: 256 * 1024, ways: 8),
        numRequestors: 2,
      );
      expect(cache.numRequestors, equals(2));
      expect(cache.output('resp0_valid').width, equals(1));
      expect(cache.output('resp1_valid').width, equals(1));
    });

    test('snoop outputs per requestor', () {
      final cache = HarborL2Cache(
        config: const HarborCacheConfig(size: 256 * 1024, ways: 8),
        numRequestors: 3,
      );
      expect(cache.output('snoop0_addr').width, equals(32));
      expect(cache.output('snoop1_addr').width, equals(32));
      expect(cache.output('snoop2_addr').width, equals(32));
    });

    test('performance counter outputs', () {
      final cache = HarborL2Cache(
        config: const HarborCacheConfig(size: 256 * 1024, ways: 8),
      );
      expect(cache.output('perf_hits').width, equals(32));
      expect(cache.output('perf_misses').width, equals(32));
      expect(cache.output('perf_evictions').width, equals(32));
    });

    test('coherency protocol', () {
      final cache = HarborL2Cache(
        config: const HarborCacheConfig(size: 256 * 1024, ways: 8),
        coherencyProtocol: HarborCoherencyProtocol.moesi,
      );
      expect(cache.coherencyProtocol, equals(HarborCoherencyProtocol.moesi));
    });
  });
}
