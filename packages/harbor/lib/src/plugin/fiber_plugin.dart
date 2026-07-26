part of 'plugin.dart';

/// Provides `during.setup(...)`, `during.build(...)` etc. for
/// registering phase tasks in a [FiberPlugin].
class _PhaseAccessor {
  final FiberPlugin _plugin;
  const _PhaseAccessor(this._plugin);

  /// Registers a task in the [HarborFiberPhase.setup] phase.
  void setup(HarborFiberTask task) =>
      _plugin._phaseTasks[HarborFiberPhase.setup]!.add(task);

  /// Registers a task in the [HarborFiberPhase.build] phase.
  void build(HarborFiberTask task) =>
      _plugin._phaseTasks[HarborFiberPhase.build]!.add(task);

  /// Registers a task in the [HarborFiberPhase.patch] phase.
  void patch(HarborFiberTask task) =>
      _plugin._phaseTasks[HarborFiberPhase.patch]!.add(task);

  /// Registers a task in the [HarborFiberPhase.check] phase.
  void check(HarborFiberTask task) =>
      _plugin._phaseTasks[HarborFiberPhase.check]!.add(task);
}

/// Base class for plugins in the Harbor fiber system.
///
/// Subclasses override [init] to register phase tasks via [during].
/// Plugins declare their [dependencies] so the framework can validate
/// the dependency graph before elaboration.
///
/// Each plugin instance is bound to exactly one [PluginHost] context.
/// There is no global state. Multiple hosts can coexist and elaborate
/// in parallel.
///
/// ```dart
/// class MyAluPlugin extends FiberPlugin {
///   @override
///   String get name => 'IntAlu'
///
///   @override
///   Set<Type> get dependencies => {DecoderPlugin}
///
///   @override
///   void init() {
///     during.build(() async {
///       final decoder = host.apply<DecoderPlugin>()
///       // ... build ALU hardware ...
///     })
///   }
///
///   @override
///   Map<String, dynamic> toJson() => {'name': name}
/// }
/// ```
abstract class FiberPlugin {
  PluginHost? _host;
  final HarborLock hostLock = HarborLock();

  final Map<HarborFiberPhase, List<HarborFiberTask>> _phaseTasks = {
    for (final phase in HarborFiberPhase.values) phase: [],
  };

  late final _PhaseAccessor during = _PhaseAccessor(this);

  /// Human-readable name, also used as the JSON key for serialization.
  String get name;

  /// Types of plugins this one depends on.
  ///
  /// The [PluginHost] validates that all dependencies are present
  /// before elaboration begins.
  Set<Type> get dependencies => {};

  /// The host this plugin is bound to.
  ///
  /// Only available after the plugin has been added to a [PluginHost].
  /// Throws [StateError] if accessed before binding.
  PluginHost get host {
    if (_host == null) {
      throw StateError(
        'Plugin "$name" has not been bound to a PluginHost. '
        'Add it via PluginHost.addPlugin() before accessing host.',
      );
    }
    return _host!;
  }

  /// Override to register phase tasks using [during].
  ///
  /// Called once when the plugin is added to a [PluginHost].
  void init();

  /// Serializes this plugin's configuration to JSON.
  Map<String, dynamic> toJson();

  /// Binds this plugin to [host]. Called by [PluginHost.addPlugin].
  void _bind(PluginHost host) {
    if (_host != null) {
      throw StateError(
        'Plugin "$name" is already bound to a PluginHost. '
        'A plugin instance cannot be shared across hosts.',
      );
    }
    _host = host;
    hostLock.retain();
    init();
    hostLock.release();
  }

  /// Registers this plugin's tasks into the given [fiber].
  void _registerTasks(HarborFiber fiber) {
    for (final phase in HarborFiberPhase.values) {
      for (final task in _phaseTasks[phase]!) {
        fiber.schedule(phase, () async {
          await hostLock.wait;
          await task();
        });
      }
    }
  }
}
