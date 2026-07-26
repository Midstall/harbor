import 'dart:async';

/// Elaboration phases, ordered by priority.
///
/// Each phase runs to completion before the next begins. Within a
/// phase, all tasks run concurrently via [Future.wait].
enum HarborFiberPhase implements Comparable<HarborFiberPhase> {
  /// Initial setup: plugins declare what they provide and need.
  setup(0),

  /// Main build: plugins create hardware logic.
  build(1000000),

  /// Post-build patching: plugins apply modifications.
  patch(1500000),

  /// Final checks: validation and assertions.
  check(2000000);

  /// Numeric priority for ordering.
  final int priority;

  const HarborFiberPhase(this.priority);

  @override
  int compareTo(HarborFiberPhase other) => priority.compareTo(other.priority);
}

/// An async task scheduled to run during a specific [HarborFiberPhase].
typedef HarborFiberTask = Future<void> Function();

/// Phase-based task scheduler for hardware elaboration.
///
/// Collects async tasks into phases, then executes all tasks within
/// each phase concurrently, proceeding through phases in order.
///
/// Tasks within the same phase that depend on each other coordinate
/// via [HarborHandle]s: a task awaiting a HarborHandle suspends until another
/// task loads it.
class HarborFiber {
  final Map<HarborFiberPhase, List<HarborFiberTask>> _tasks = {
    for (final phase in HarborFiberPhase.values) phase: [],
  };

  /// Schedules a [task] in the given [phase].
  void schedule(HarborFiberPhase phase, HarborFiberTask task) {
    _tasks[phase]!.add(task);
  }

  /// Schedules a task in the [HarborFiberPhase.setup] phase.
  void setup(HarborFiberTask task) => schedule(HarborFiberPhase.setup, task);

  /// Schedules a task in the [HarborFiberPhase.build] phase.
  void build(HarborFiberTask task) => schedule(HarborFiberPhase.build, task);

  /// Schedules a task in the [HarborFiberPhase.patch] phase.
  void patch(HarborFiberTask task) => schedule(HarborFiberPhase.patch, task);

  /// Schedules a task in the [HarborFiberPhase.check] phase.
  void check(HarborFiberTask task) => schedule(HarborFiberPhase.check, task);

  /// Executes all scheduled tasks phase by phase.
  ///
  /// Within each phase, all tasks run concurrently. The next phase
  /// does not begin until all tasks in the current phase have
  /// completed (including awaiting their dependencies).
  ///
  /// Throws [HarborFiberElaborationException] if any task fails.
  Future<void> run() async {
    final phases = HarborFiberPhase.values.toList()..sort();

    for (final phase in phases) {
      final tasks = _tasks[phase]!;
      if (tasks.isEmpty) continue;

      try {
        await Future.wait(tasks.map((t) => t()), eagerError: true);
      } on Object catch (e, st) {
        throw HarborFiberElaborationException(
          'Elaboration failed during $phase phase',
          phase: phase,
          cause: e,
          stackTrace: st,
        );
      }
    }
  }
}

/// Thrown when elaboration fails during a [HarborFiberPhase].
class HarborFiberElaborationException implements Exception {
  final String message;
  final HarborFiberPhase phase;
  final Object? cause;
  final StackTrace? stackTrace;

  const HarborFiberElaborationException(
    this.message, {
    required this.phase,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() {
    final buf = StringBuffer('HarborFiberElaborationException: $message');
    if (cause != null) {
      buf.write('\n  Caused by: $cause');
    }
    return buf.toString();
  }
}
