import 'dart:async';

/// A deferred value container for inter-task communication during
/// elaboration.
///
/// One task calls [load] to provide the value. Other tasks `await`
/// [value] to receive it. A [HarborHandle] can only be loaded once.
///
/// ```dart
/// final width = HarborHandle<int>()
///
/// // Task A (setup phase):
/// width.load(32)
///
/// // Task B (build phase):
/// final w = await width.value // 32
/// ```
class HarborHandle<T> {
  final Completer<T> _completer = Completer<T>();

  /// Creates an empty handle that must be [load]ed before [value]
  /// can complete.
  HarborHandle();

  /// Creates a handle pre-loaded with [initial].
  HarborHandle.of(T initial) {
    _completer.complete(initial);
  }

  /// Whether this handle has been loaded with a value.
  bool get isLoaded => _completer.isCompleted;

  /// Loads [val] into this handle, completing any pending [value] futures.
  ///
  /// Throws [StateError] if already loaded.
  void load(T val) {
    if (_completer.isCompleted) {
      throw StateError('HarborHandle has already been loaded.');
    }
    _completer.complete(val);
  }

  /// The value once loaded. Suspends the calling async function until
  /// [load] is called.
  Future<T> get value => _completer.future;
}
