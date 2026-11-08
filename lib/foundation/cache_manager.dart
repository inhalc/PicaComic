import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:sqlite3/sqlite3.dart';

/// Default lifetime of a cache entry: 7 days.
const int kDefaultCacheLifetimeMs = 7 * 24 * 60 * 60 * 1000;

/// Upper bound on the number of cache records, independent of their size.
const int kMaxCacheEntries = 2000;

/// `duration <= 0` marks the entry as permanent (`expires == 0`).
///
/// Previously a zero/negative duration was stored as `now + duration`, i.e.
/// already expired. `CacheExpiredTime.persistent` therefore never persisted.
int cacheExpiresAt(int durationMs, int nowMs) =>
    durationMs <= 0 ? 0 : nowMs + durationMs;

/// Permanent entries (`expires == 0`) never expire.
bool isCacheExpired(int expires, int nowMs) =>
    expires != 0 && expires <= nowMs;

/// Must be a top-level / static function so it can be sent to an isolate.
Future<int> _calculateDirectorySize(String path) => Directory(path).size;

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  int get limitSize => _limitSize;

  bool _calibrated = false;

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    // Cache writes happen on the UI isolate while the reader is decoding.
    // WAL + NORMAL keeps the fsync cost bounded (same fix as history.db).
    try {
      _db.execute('PRAGMA journal_mode = WAL;');
      _db.execute('PRAGMA synchronous = NORMAL;');
    } catch (_) {
      // Some platforms ship a sqlite build without these pragmas.
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    _ensureColumn('type', 'TEXT');
    _ensureColumn(
        'lifetime', 'INTEGER NOT NULL DEFAULT $kDefaultCacheLifetimeMs');
    // Startup calibration runs in the background: it fixes the size counter,
    // removes stale DB rows and orphaned files left by interrupted writes.
    _calibrate();
  }

  factory CacheManager() => instance ??= CacheManager._create();

  void _ensureColumn(String name, String definition) {
    try {
      _db.execute('ALTER TABLE cache ADD COLUMN $name $definition');
    } catch (_) {
      // Column already exists (or an old sqlite build refuses the default).
    }
  }

  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
    // A smaller limit must take effect immediately. The old implementation
    // only checked the limit on the *next* write, so the cache kept growing.
    if (currentSize > _limitSize) {
      checkCache();
    }
  }

  void setType(String key, String? type) {
    _db.execute('''
      UPDATE cache
      SET type = ?
      WHERE key = ?
    ''', [type, key]);
  }

  String? getType(String key) {
    var res = _db.select('''
      SELECT type FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    return res.first[0];
  }

  /// Adjust the running size counter. While the startup calibration is still
  /// in flight the value is unknown; [checkCache] always measures it for real.
  void _addSize(int delta) {
    final size = _currentSize;
    if (size == null) return;
    final next = size + delta;
    _currentSize = next < 0 ? 0 : next;
  }

  Future<int> _directorySize() async {
    try {
      return await compute(_calculateDirectorySize, cachePath);
    } catch (_) {
      // `compute` is unavailable on web; fall back to the streaming counter.
      return await Directory(cachePath).size;
    }
  }

  Future<void> _calibrate() async {
    if (_calibrated) return;
    _calibrated = true;
    try {
      final rows = _db.select('SELECT key, dir, name FROM cache').toList();
      final referenced = <String>{};
      final staleKeys = <String>[];
      for (final row in rows) {
        final relative = '${row[1]}/${row[2]}';
        referenced.add(relative);
        if (!File('$cachePath/$relative').existsSync()) {
          staleKeys.add(row[0] as String);
        }
      }
      for (final key in staleKeys) {
        _db.execute('DELETE FROM cache WHERE key = ?', [key]);
      }

      // Orphaned files are the reason the cache kept growing after lowering
      // its limit: overwriting a key used to leave the old file behind.
      // Only delete files older than a day so an in-flight write is safe.
      final cutoff = DateTime.now().millisecondsSinceEpoch -
          const Duration(days: 1).inMilliseconds;
      await for (final entity in Directory(cachePath).list(recursive: true)) {
        if (entity is! File) continue;
        final relative = entity.path.substring(cachePath.length + 1);
        if (referenced.contains(relative)) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.millisecondsSinceEpoch < cutoff) {
            await entity.delete();
          }
        } catch (_) {
          // A file may disappear while we scan.
        }
      }
      _currentSize = await _directorySize();
      if (currentSize > _limitSize) {
        await checkCache();
      }
    } catch (_) {
      // Calibration is best-effort; never let it break app startup.
    }
  }

  /// Remove the file and row currently associated with [key].
  Future<void> _removeExisting(String key) async {
    final rows = _db.select('''
      SELECT dir, name FROM cache
      WHERE key = ?
    ''', [key]).toList();
    for (final row in rows) {
      final file = File('$cachePath/${row[0]}/${row[1]}');
      if (await file.exists()) {
        final size = await file.length();
        try {
          await file.delete();
        } catch (_) {
          // The file is already gone.
        }
        _addSize(-size);
      }
    }
    _db.execute('''
      DELETE FROM cache
      WHERE key = ?
    ''', [key]);
  }

  Future<String> _createCacheFile(String key) async {
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dir/$name');
    while (await file.exists()) {
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dir/$name');
    }
    await file.create(recursive: true);
    return '$dir/$name';
  }

  Future<void> writeCache(String key, Uint8List data,
      [int duration = kDefaultCacheLifetimeMs]) async {
    // Writing the same key twice used to leave the first file orphaned.
    await _removeExisting(key);
    final relative = await _createCacheFile(key);
    final parts = relative.split('/');
    await File('$cachePath/$relative').writeAsBytes(data);
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires, type, lifetime)
      VALUES (?, ?, ?, ?, NULL, ?)
    ''', [
      key,
      parts[0],
      parts[1],
      cacheExpiresAt(duration, now),
      duration > 0 ? duration : 0,
    ]);
    _addSize(data.length);
    await _enforceLimit();
  }

  Future<CachingFile> openWrite(String key) async {
    await _removeExisting(key);
    final relative = await _createCacheFile(key);
    final parts = relative.split('/');
    return CachingFile._(key, parts[0], parts[1],
        File('$cachePath/$relative'));
  }

  Future<String?> findCache(String key) async {
    var res = _db.select('''
      SELECT dir, name, expires, lifetime FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row[0] as String;
    var name = row[1] as String;
    var expires = row[2] as int;
    var lifetime = row[3] as int;
    var file = File('$cachePath/$dir/$name');
    if (!await file.exists()) {
      // A deleted/moved file leaves a dangling DB row. Clean it up so the
      // next request really goes to the network instead of failing oddly.
      _db.execute('DELETE FROM cache WHERE key = ?', [key]);
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (isCacheExpired(expires, now)) {
      final size = await file.length();
      try {
        await file.delete();
      } catch (_) {}
      _db.execute('DELETE FROM cache WHERE key = ?', [key]);
      _addSize(-size);
      return null;
    }
    if (expires != 0) {
      // Sliding expiration: a page the user keeps reading must stay readable
      // offline instead of disappearing exactly 7 days after first load.
      final effectiveLifetime =
          lifetime > 0 ? lifetime : kDefaultCacheLifetimeMs;
      _db.execute('''
        UPDATE cache SET expires = ? WHERE key = ?
      ''', [now + effectiveLifetime, key]);
    }
    return file.path;
  }

  /// The in-flight cleanup, if any. Repeat callers await the same run instead
  /// of silently skipping it (which used to leave the limit unenforced).
  Future<void>? _checkingFuture;

  Future<void> _enforceLimit() async {
    if (currentSize > _limitSize) {
      await checkCache();
    }
  }

  Future<int> _deleteRows(List<List<Object?>> rows) async {
    var deleted = 0;
    for (var row in rows) {
      var key = row[0] as String;
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if (await file.exists()) {
        var size = await file.length();
        try {
          await file.delete();
        } catch (_) {}
        _addSize(-size);
      }
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [key]);
      deleted++;
    }
    return deleted;
  }

  Future<void> checkCache() => _checkingFuture ??= _runCheckCache();

  Future<void> _runCheckCache() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Permanent entries (expires == 0) must never be swept here.
      final expired = _db
          .select('''
            SELECT key, dir, name FROM cache
            WHERE expires != 0 AND expires < ?
          ''', [now])
          .map((r) => [r[0], r[1], r[2]])
          .toList();
      await _deleteRows(expired);

      // Measure for real before evicting. The old code fired an unawaited
      // compute() and then looped on a stale (possibly null) counter.
      _currentSize = await _directorySize();
      var count = (_db.select('SELECT COUNT(*) FROM cache').first[0] as int);

      while (currentSize > _limitSize || count > kMaxCacheEntries) {
        final rows = _db
            .select('''
              SELECT key, dir, name FROM cache
              WHERE expires != 0
              ORDER BY expires ASC
              LIMIT 20
            ''')
            .map((r) => [r[0], r[1], r[2]])
            .toList();
        if (rows.isEmpty) {
          // Only permanent entries remain; evicting them would be wrong.
          break;
        }
        final deleted = await _deleteRows(rows);
        if (deleted == 0) {
          break;
        }
        count -= deleted;
        if (count < 0) count = 0;
      }
    } catch (_) {
      // Cleanup is best-effort: a broken cache must never abort an image
      // download or crash the reader.
    } finally {
      // An exception used to leave the guard true forever, freezing all
      // future cache cleanup.
      _checkingFuture = null;
    }
  }

  Future<void> delete(String key) async {
    final rows = _db
        .select('SELECT key, dir, name FROM cache WHERE key = ?', [key])
        .map((r) => [r[0], r[1], r[2]])
        .toList();
    await _deleteRows(rows);
  }

  Future<void> clear() async {
    await Directory(cachePath).delete(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }

  Future<void> deleteKeyword(String keyword) async {
    var res = _db
        .select('''
          SELECT key, dir, name FROM cache
          WHERE key LIKE ?
        ''', ['%$keyword%'])
        .map((r) => [r[0], r[1], r[2]])
        .toList();
    await _deleteRows(res);
  }
}

class CachingFile {
  CachingFile._(this.key, this.dir, this.name, this.file);

  final String key;

  final String dir;

  final String name;

  final File file;

  final List<int> _buffer = [];

  int _written = 0;

  Future<void> writeBytes(List<int> data) async {
    _written += data.length;
    _buffer.addAll(data);
    if (_buffer.length > 1024 * 1024) {
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _buffer.clear();
    }
  }

  Future<void> close() async {
    if (_buffer.isNotEmpty) {
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _buffer.clear();
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final manager = CacheManager();
    manager._db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires, type, lifetime)
      VALUES (?, ?, ?, ?, NULL, ?)
    ''', [
      key,
      dir,
      name,
      cacheExpiresAt(kDefaultCacheLifetimeMs, now),
      kDefaultCacheLifetimeMs,
    ]);
    // Streaming writes were previously invisible to the size counter, so the
    // limit was never enforced for downloaded comic pages.
    manager._addSize(_written);
    await manager._enforceLimit();
  }

  Future<void> cancel() async {
    await file.deleteIgnoreError();
    CacheManager()._db.execute('DELETE FROM cache WHERE key = ?', [key]);
  }

  void reset() {
    _buffer.clear();
    // A retry re-downloads the whole file; counting it twice would make the
    // cache limit fire far too early.
    _written = 0;
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
