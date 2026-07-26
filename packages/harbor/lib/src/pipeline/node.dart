import 'package:rohd/rohd.dart';

import 'payload.dart';
import 'stage.dart';

/// A single stage in a hardware pipeline, identified by a typed
/// [HarborPipelineStage] enum value.
///
/// Each node carries typed [HarborPayload] signals and control signals for
/// flow management (valid/ready handshaking).
///
/// ```dart
/// enum MyStage with HarborPipelineStage { fetch, decode, execute }
///
/// final fetchNode = HarborNode(MyStage.fetch)
/// fetchNode.insert(pc)
/// fetchNode.insert(instruction)
/// ```
class HarborNode<S extends HarborPipelineStage> {
  /// The typed stage identifier for this node.
  final S stage;

  /// HarborPipeline-valid signal: indicates this stage has valid data.
  late final Logic valid = Logic(name: '${stage.name}_valid');

  /// HarborPipeline-ready signal: indicates downstream can accept data.
  late final Logic ready = Logic(name: '${stage.name}_ready');

  /// Cancel signal: invalidates the current transaction.
  late final Logic cancel = Logic(name: '${stage.name}_cancel');

  final Map<HarborPayload, Logic> _payloads = {};

  /// Creates a pipeline node for the given [stage].
  HarborNode(this.stage);

  /// Inserts a [payload] into this node, creating the associated
  /// [Logic] signal.
  ///
  /// Returns the created signal.
  /// Throws [StateError] if the payload already exists.
  Logic insert(HarborPayload payload) {
    if (_payloads.containsKey(payload)) {
      throw StateError(
        'HarborPayload "${payload.name}" already exists in node '
        '"${stage.name}".',
      );
    }
    final signal = Logic(
      name: '${stage.name}_${payload.name}',
      width: payload.width,
    );
    _payloads[payload] = signal;
    return signal;
  }

  /// Accesses the signal for [payload] at this stage.
  ///
  /// Throws [StateError] if the payload has not been inserted.
  Logic operator [](HarborPayload payload) {
    final signal = _payloads[payload];
    if (signal == null) {
      throw StateError(
        'HarborPayload "${payload.name}" not found in node '
        '"${stage.name}". '
        'Available: ${_payloads.keys.map((p) => p.name).join(", ")}',
      );
    }
    return signal;
  }

  /// Whether this node has the given [payload].
  bool has(HarborPayload payload) => _payloads.containsKey(payload);

  /// All payloads registered in this node.
  Iterable<HarborPayload> get payloads => _payloads.keys;

  /// Whether data is firing through this stage (valid & ready & ~cancel).
  Logic get isFiring => valid & ready & ~cancel;

  /// Whether data is moving out of this stage (valid & ready).
  Logic get isMoving => valid & ready;

  /// The stage name, for diagnostics.
  String get name => stage.name;
}
