part of 'plugin.dart';

/// A contextual service registry and elaboration engine for plugins.
///
/// Each [PluginHost] is a fully independent context: no global state.
/// Multiple hosts can coexist and elaborate in parallel.
///
/// ```dart
/// final host = PluginHost()
///   ..addPlugin(RiscvPlugin(xlen: 32))
///   ..addPlugin(IntAluPlugin())
///   ..addPlugin(DecoderPlugin());
///
/// await host.elaborate();
/// ```
class PluginHost {
  final List<FiberPlugin> _plugins = [];
  final HarborDatabase database;
  final HarborFiber _fiber = HarborFiber();

  /// Creates a plugin host with an optional shared [database].
  PluginHost({HarborDatabase? database})
    : database = database ?? HarborDatabase();

  /// All registered plugins.
  List<FiberPlugin> get plugins => List.unmodifiable(_plugins);

  /// Adds a plugin to this host.
  ///
  /// Must be called before [elaborate]. Throws [StateError] if the
  /// plugin is already bound to another host.
  void addPlugin(FiberPlugin plugin) {
    _plugins.add(plugin);
    plugin._bind(this);
  }

  /// Adds multiple plugins.
  void addPlugins(Iterable<FiberPlugin> plugins) {
    for (final p in plugins) {
      addPlugin(p);
    }
  }

  /// Returns all plugins of type [T].
  List<T> list<T extends FiberPlugin>() => _plugins.whereType<T>().toList();

  /// Returns the single plugin of type [T].
  ///
  /// Throws [StateError] if zero or more than one plugin of that
  /// type exists.
  T apply<T extends FiberPlugin>() {
    final matches = list<T>();
    if (matches.isEmpty) {
      throw StateError('No plugin of type $T found.');
    }
    if (matches.length > 1) {
      throw StateError(
        'Multiple plugins of type $T found (${matches.length}). '
        'Use list<$T>() to get all of them.',
      );
    }
    return matches.first;
  }

  /// Returns the single plugin of type [T], or `null` if not found.
  ///
  /// Throws [StateError] if more than one plugin of that type exists.
  T? tryApply<T extends FiberPlugin>() {
    final matches = list<T>();
    if (matches.isEmpty) return null;
    if (matches.length > 1) {
      throw StateError(
        'Multiple plugins of type $T found (${matches.length}). '
        'Use list<$T>() to get all of them.',
      );
    }
    return matches.first;
  }

  /// Finds plugins matching [predicate] among those of type [T].
  List<T> where<T extends FiberPlugin>(bool Function(T) predicate) =>
      list<T>().where(predicate).toList();

  /// Validates the dependency graph and runs all plugins through
  /// the elaboration phases.
  ///
  /// Validation checks:
  /// - All declared plugin [FiberPlugin.dependencies] are present
  /// - No dependency cycles
  ///
  /// Post-elaboration checks:
  /// - All [HarborBlockingElement]s in the database have been resolved
  ///
  /// Throws [PluginDependencyException] if validation fails.
  /// Throws [HarborFiberElaborationException] if any task fails.
  Future<void> elaborate() async {
    _validateDependencies();

    for (final plugin in _plugins) {
      plugin._registerTasks(_fiber);
    }

    await _fiber.run();

    _validatePostElaboration();
  }

  /// Checks that all declared dependencies are satisfied.
  void _validateDependencies() {
    final availableTypes = _plugins.map((p) => p.runtimeType).toSet();

    for (final plugin in _plugins) {
      for (final dep in plugin.dependencies) {
        final satisfied = _plugins.any((p) => p.runtimeType == dep);
        if (!satisfied) {
          throw PluginDependencyException(
            'Plugin "${plugin.name}" depends on $dep, '
            'but no plugin of that type is registered. '
            'Available: $availableTypes',
          );
        }
      }
    }

    // Cycle detection via topological sort
    final visited = <Type>{};
    final visiting = <Type>{};

    void visit(FiberPlugin plugin) {
      final type = plugin.runtimeType;
      if (visited.contains(type)) return;
      if (visiting.contains(type)) {
        throw PluginDependencyException(
          'Dependency cycle detected involving ${plugin.name} ($type)',
        );
      }
      visiting.add(type);
      for (final dep in plugin.dependencies) {
        final depPlugin = _plugins.firstWhere((p) => p.runtimeType == dep);
        visit(depPlugin);
      }
      visiting.remove(type);
      visited.add(type);
    }

    for (final plugin in _plugins) {
      visit(plugin);
    }
  }

  /// Post-elaboration validation.
  void _validatePostElaboration() {
    final unresolved = database.unresolvedBlockingKeys;
    if (unresolved.isNotEmpty) {
      throw HarborFiberElaborationException(
        'Unresolved blocking database elements after elaboration: '
        '${unresolved.join(", ")}',
        phase: HarborFiberPhase.check,
      );
    }
  }

  /// Serializes this host's plugin configuration to JSON.
  Map<String, dynamic> toJson() {
    return {'plugins': _plugins.map((p) => p.toJson()).toList()};
  }

  /// Reconstructs a [PluginHost] from JSON using the given [registry]
  /// to instantiate plugins by name.
  factory PluginHost.fromJson(
    Map<String, dynamic> json,
    PluginRegistry registry,
  ) {
    final host = PluginHost();
    final pluginList = json['plugins'] as List<dynamic>;
    for (final pluginJson in pluginList) {
      final config = pluginJson as Map<String, dynamic>;
      final plugin = registry.create(config);
      host.addPlugin(plugin);
    }
    return host;
  }
}

/// Thrown when plugin dependency validation fails.
class PluginDependencyException implements Exception {
  final String message;

  const PluginDependencyException(this.message);

  @override
  String toString() => 'PluginDependencyException: $message';
}
