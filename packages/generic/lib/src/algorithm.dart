import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'database.dart';
import 'migration.dart';

/// An extension on [SyncDatabase] that adds a [migrate] method.
extension SyncMigrateExt<T> on SyncDatabase<T> {
  /// Migrates the database using the given [migrations].
  void migrate(List<Migration<T>> migrations) {
    SyncMigrator<T>()(db: this, defined: migrations.iterator);
  }
}

/// An extension on [AsyncDatabase] that adds a [migrate] method.
extension AsyncMigrateExt<T> on AsyncDatabase<T> {
  /// Migrates the database using the given [migrations].
  Future<void> migrate(List<Migration<T>> migrations) {
    return AsyncMigrator<T>()(db: this, defined: migrations.iterator);
  }
}

/// {@template dmwmt.migrator}
/// A migrator that applies and rolls back migrations.
///
/// Use [call] to perform a schema update.
// Unfortunatly this ended up being an object instead of a function
// but this made it easier to test
/// {@endtemplate}
class SyncMigrator<T> {
  /// Creates a new [SyncMigrator] with an optional [logger].
  ///
  /// {@template dmwmt.migrator.new}
  /// The [logger] is used to log messages during the migration process.
  /// If no [Logger] is provided, a new logger named 'db.migrate' is created.
  /// {@endtemplate}
  SyncMigrator({Logger? logger})
      : log = logger ?? Logger('db.migrate'),
        _hasDefined = false,
        _hasApplied = false;

  /// {@template dmwmt.migrator.log}
  /// The logger used during migrations.
  ///
  /// Conforms to the [Logger] class from the `logging` package.
  ///
  /// Defaults to a logger named 'db.migrate'.
  /// {@endtemplate}
  final Logger log;

  SyncDatabase<T>? _db;

  /// {@template dmwmt.migrator._defined}
  /// The migrations that are defined in code.
  /// {@endtemplate}
  Iterator<Migration<T>>? _defined;

  /// {@template dmwmt.migrator._applied}
  /// The migrations that have been applied to the database.
  /// {@endtemplate}
  Iterator<Migration<T>>? _applied;

  /// {@template dmwmt.migrator._hasDefined}
  /// Whether there are any [_defined] migrations left to apply.
  ///
  /// This is the result of [_defined.moveNext].
  /// {@endtemplate}
  bool _hasDefined;

  /// {@template dmwmt.migrator._hasApplied}
  /// Whether there are any [_applied] migrations left to rollback.
  ///
  /// This is the result of [_applied.moveNext].
  /// {@endtemplate}
  bool _hasApplied;

  /// {@template dmwmt.migrator._previousDefined}
  /// The previous migration obtained from [_defined] before calling [_defined.moveNext].
  ///
  /// Used to ensure that migrations are being iterated in the correct order.
  /// {@endtemplate}
  Migration<T>? _previousDefined;

  /// {@template dmwmt.migrator._previousApplied}
  /// The previous migration obtained from [_applied] before calling [_applied.moveNext].
  ///
  /// Used to ensure that migrations are being iterated in the correct order.
  /// {@endtemplate}
  Migration<T>? _previousApplied;

  void _moveNextDefined() {
    _previousDefined = _defined!.current;
    _hasDefined = _defined!.moveNext();
    if (_hasDefined && (_previousDefined! >= _defined!.current)) {
      throw StateError(
        'Defined migrations are not in ascending order: $_previousDefined should not come before ${_defined!.current}.',
      );
    }
  }

  void _moveNextApplied() {
    _previousApplied = _applied!.current;
    _hasApplied = _applied!.moveNext();
    if (_hasApplied && _previousApplied! >= _applied!.current) {
      throw StateError(
        'Applied migrations are not in ascending order: $_previousApplied should not come before ${_applied!.current}.',
      );
    }
  }

  /// {@template dmwmt.migrator.call}
  /// Makes the migrator work with the given database and migrations.
  ///
  /// Throws a [StateError] if the [Migration]s in [defined] are not in ascending order.
  /// Throws a [StateError] the [Migration]s obtained from the db are not in ascending order.
  /// {@endtemplate}
  void call({required SyncDatabase<T> db, required Iterator<Migration<T>> defined}) {
    initialize(db, defined);
    // [_defined] and [_applied] are moved to the first migration

    _db!.beginTransaction();
    try {
      findLastCommonMigration();
      // [_defined] and [_applied] are moved to the migration after the last common migration

      /// The loop is only there to be able to first rollback with [rollbackRemainingAppliedMigrations]
      /// and then [applyRemainingDefinedMigrations] to apply the rest.
      loop:
      while (true) {
        switch ((_hasDefined, _hasApplied)) {
          case (false, false):
            // No remaining migrations to apply or rollback.
            // we're done
            break loop;
          case (true, false):
            // [_applied] is moved to the end
            applyRemainingDefinedMigrations();
          // [_defined] is moved to the end
          case (_, true):
            rollbackRemainingAppliedMigrations();
          // [_applied] is moved to the end
        }
      }

      _db!.commitTransaction();
    } catch (e) {
      _db!.rollbackTransaction();
      rethrow;
    }

    log.fine('migration complete');

    reset();
  }

  /// {@template dmwmt.migrator.initialize}
  /// Sets up the migrator to work with the given database and migrations.
  ///
  /// Throws a [ConcurrentModificationError] if the migrator is already [working].
  /// {@endtemplate}
  @visibleForTesting
  void initialize(SyncDatabase<T> db, Iterator<Migration<T>> defined) {
    log.finer('initializing migrator...');

    _db = db;
    _defined = defined;

    if (!_db!.isMigrationsTableInitialized()) {
      log.fine('initializing migrations table');
      _db!.initializeMigrationsTable();
    }

    _applied = db.retrieveAllMigrations();
    _hasDefined = _defined!.moveNext();
    _hasApplied = _applied!.moveNext();
  }

  /// {@template dmwmt.migrator.findLastCommonMigration}
  /// Find the last common migration between defined and applied migrations.
  ///
  /// The last common migration is the last (going forwards in time) migration that is both defined and applied.
  /// {@endtemplate}
  @visibleForTesting
  Migration<T>? findLastCommonMigration() {
    log.finer('finding last common migration...');
    Migration<T>? lastCommon;
    while (_hasDefined && _hasApplied && _defined!.current == _applied!.current) {
      lastCommon = _defined!.current;
      _moveNextDefined();
      _moveNextApplied();
    }

    if (lastCommon != null) {
      log.finer('last common migration: ${lastCommon.humanReadableId}');
    } else {
      log.finer('no common migrations found');
    }

    return lastCommon;
  }

  /// {@template dmwmt.migrator.rollbackRemainingAppliedMigrations}
  /// Rollback all incoming [_applied] migrations.
  ///
  /// This is done in reverse order: the last applied [Migration] is rolled back first.
  ///
  /// The migrations are then removed from the migrations table in the [MaybeAsyncDatabase].
  /// {@endtemplate}
  @visibleForTesting
  void rollbackRemainingAppliedMigrations() {
    log.fine('rolling back applied migrations...');

    if (!_hasApplied) {
      log.finer('no migrations to rollback');
      return;
    }

    final toRollback = [for (; _hasApplied; _moveNextApplied()) _applied!.current].reversed.toList();

    for (final migration in toRollback) {
      log.finer('|_ - migration ${migration.humanReadableId}');
      _db!.performMigration(migration.down);
    }
    log.finest('updating applied migrations database table...');
    _db!.removeMigrations(toRollback);
  }

  /// {@template dmwmt.migrator.applyRemainingDefinedMigrations}
  /// Apply all remaining defined migrations.
  ///
  /// The migrations are applied in order: the first defined [Migration] is applied first.
  ///
  /// The migrations are then added to the migrations table in the [MaybeAsyncDatabase].
  /// {@endtemplate}
  @visibleForTesting
  void applyRemainingDefinedMigrations() {
    log.fine('applying all remaining defined migrations');

    final toApply = List<Migration<T>>.empty(growable: true);
    final now = DateTime.now().toUtc();
    while (_hasDefined) {
      final migration = _defined!.current.copyWith(appliedAt: now);
      log.finer('|_ + migration ${migration.humanReadableId}');
      _db!.performMigration(migration.up);
      toApply.add(migration);
      _moveNextDefined();
    }
    log.finest('updating applied migrations database table...');
    _db!.storeMigrations(toApply);
  }

  /// {@template dmwmt.migrator}
  /// Resets the migrator to its initial state, allowing it to be used again.
  /// {@endtemplate}
  @visibleForTesting
  void reset() {
    _defined = null;
    _applied = null;
    _hasDefined = false;
    _hasApplied = false;
    _previousDefined = null;
    _previousApplied = null;
    _db = null;
    log.finer('migrator resetted');
  }
}

/// {@macro dmwmt.migrator}
class AsyncMigrator<T> {
  /// Creates a new [AsyncMigrator] with an optional [logger].
  ///
  /// {@macro dmwmt.migrator.new}
  AsyncMigrator({Logger? logger})
      : log = logger ?? Logger('db.migrate'),
        _hasDefined = false,
        _hasApplied = false;

  /// {@macro dmwmt.migrator.log}
  final Logger log;

  AsyncDatabase<T>? _db;

  /// Flag to check if the migrator is already working.
  ///
  /// When this is `true`, calling [call] will throw a [ConcurrentModificationError].
  bool get working => _db != null;

  /// {@macro dmwmt.migrator._defined}
  Iterator<Migration<T>>? _defined;

  /// {@macro dmwmt.migrator._applied}
  StreamIterator<Migration<T>>? _applied;

  /// {@macro dmwmt.migrator._hasDefined}
  bool _hasDefined;

  /// {@macro dmwmt.migrator._hasApplied}
  bool _hasApplied;

  /// {@macro dmwmt.migrator._previousDefined}
  Migration<T>? _previousDefined;

  /// {@macro dmwmt.migrator._previousApplied}
  Migration<T>? _previousApplied;

  void _moveNextDefined() {
    _previousDefined = _defined!.current;
    _hasDefined = _defined!.moveNext();
    if (_hasDefined && (_previousDefined! >= _defined!.current)) {
      throw StateError(
        'Defined migrations are not in ascending order: $_previousDefined should not come before ${_defined!.current}.',
      );
    }
  }

  Future<void> _moveNextApplied() async {
    _previousApplied = _applied!.current;
    _hasApplied = await _applied!.moveNext();
    if (_hasApplied && _previousApplied! >= _applied!.current) {
      throw StateError(
        'Applied migrations are not in ascending order: $_previousApplied should not come before ${_applied!.current}.',
      );
    }
  }

  /// {@macro dmwmt.migrator.call}
  /// Throws a [ConcurrentModificationError] if the migrator is already [working].
  /// To prevent this, check [working] before calling this method.
  Future<void> call({required AsyncDatabase<T> db, required Iterator<Migration<T>> defined}) async {
    if (working) throw ConcurrentModificationError(this);

    await initialize(db, defined);

    await _db!.beginTransaction();
    try {
      await findLastCommonMigration();

      loop:
      while (true) {
        switch ((_hasDefined, _hasApplied)) {
          case (false, false):
            break loop;
          case (true, false):
            await applyRemainingDefinedMigrations();
          case (_, true):
            await rollbackRemainingAppliedMigrations();
        }
      }

      await _db!.commitTransaction();
    } catch (e) {
      await _db!.rollbackTransaction();
      rethrow;
    }

    log.fine('migration complete');

    reset();
  }

  /// {@macro dmwmt.migrator.initialize}
  @visibleForTesting
  Future<void> initialize(AsyncDatabase<T> db, Iterator<Migration<T>> defined) async {
    log.finer('initializing migrator...');

    _db = db;
    _defined = defined;

    if (!await _db!.isMigrationsTableInitialized()) {
      log.fine('initializing migrations table');
      await _db!.initializeMigrationsTable();
    }

    _applied = StreamIterator(_db!.retrieveAllMigrations());
    _hasDefined = _defined!.moveNext();
    _hasApplied = await _applied!.moveNext();
  }

  /// {@macro dmwmt.migrator.findLastCommonMigration}
  @visibleForTesting
  Future<Migration<T>?> findLastCommonMigration() async {
    log.finer('finding last common migration...');
    Migration<T>? lastCommon;
    while (_hasDefined && _hasApplied && _defined!.current == _applied!.current) {
      lastCommon = _defined!.current;
      _moveNextDefined();
      await _moveNextApplied();
    }

    if (lastCommon != null) {
      log.finer('last common migration: ${lastCommon.humanReadableId}');
    } else {
      log.finer('no common migrations found');
    }

    return lastCommon;
  }

  /// {@macro dmwmt.migrator.rollbackRemainingAppliedMigrations}
  @visibleForTesting
  Future<void> rollbackRemainingAppliedMigrations() async {
    log.fine('rolling back applied migrations...');

    if (!_hasApplied) {
      log.finer('no migrations to rollback');
      return;
    }

    final toRollback = [for (; _hasApplied; await _moveNextApplied()) _applied!.current].reversed.toList();

    for (final migration in toRollback) {
      log.finer('|_ - migration ${migration.humanReadableId}');
      await _db!.performMigration(migration.down);
    }
    log.finest('updating applied migrations database table...');
    await _db!.removeMigrations(toRollback);
  }

  /// {@macro dmwmt.migrator.applyRemainingDefinedMigrations}
  @visibleForTesting
  Future<void> applyRemainingDefinedMigrations() async {
    log.fine('applying all remaining defined migrations');

    final toApply = List<Migration<T>>.empty(growable: true);
    final now = DateTime.now().toUtc();
    while (_hasDefined) {
      final migration = _defined!.current.copyWith(appliedAt: now);
      log.finer('|_ + migration ${migration.humanReadableId}');
      await _db!.performMigration(migration.up);
      toApply.add(migration);
      _moveNextDefined();
    }
    log.finest('updating applied migrations database table...');
    await _db!.storeMigrations(toApply);
  }

  /// {@macro dmwmt.migrator}
  @visibleForTesting
  void reset() {
    _defined = null;
    _applied = null;
    _hasDefined = false;
    _hasApplied = false;
    _previousDefined = null;
    _previousApplied = null;
    _db = null;
    log.finer('migrator resetted');
  }
}
