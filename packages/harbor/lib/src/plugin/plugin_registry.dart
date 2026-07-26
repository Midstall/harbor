part of 'plugin.dart';

/// Factory function that creates a [FiberPlugin] from JSON configuration.
typedef PluginFactory = FiberPlugin Function(Map<String, dynamic> json);

/// A registry mapping plugin names to factory functions for JSON
/// deserialization.
///
/// ```dart
/// final registry = PluginRegistry()
///   ..register('IntAlu', (json) => IntAluPlugin.fromJson(json))
///   ..register('Decoder', (json) => DecoderPlugin.fromJson(json))
///
/// final host = PluginHost.fromJson(json, registry)
/// ```
class PluginRegistry {
  final Map<String, PluginFactory> _factories = {};

  /// Registers a factory for plugins with the given [name].
  ///
  /// Throws [StateError] if a factory for [name] is already registered.
  void register(String name, PluginFactory factory) {
    if (_factories.containsKey(name)) {
      throw StateError('Plugin factory for "$name" is already registered.');
    }
    _factories[name] = factory;
  }

  /// Creates a plugin from [json] using the registered factory.
  ///
  /// The JSON must contain a `"name"` field matching a registered factory.
  /// Throws [StateError] if no factory is found.
  FiberPlugin create(Map<String, dynamic> json) {
    final name = json['name'] as String?;
    if (name == null) {
      throw StateError('Plugin JSON must contain a "name" field. Got: $json');
    }
    final factory = _factories[name];
    if (factory == null) {
      throw StateError(
        'No factory registered for plugin "$name". '
        'Available: ${_factories.keys.join(", ")}',
      );
    }
    return factory(json);
  }

  /// Whether a factory for [name] is registered.
  bool has(String name) => _factories.containsKey(name);

  /// All registered plugin names.
  Iterable<String> get names => _factories.keys;
}
