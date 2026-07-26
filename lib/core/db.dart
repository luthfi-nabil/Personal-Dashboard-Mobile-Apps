import 'package:sqflite/sqflite.dart' hide Transaction;
import 'package:path/path.dart';
import 'models.dart';

/// Tables that are scoped per-user via a `userId` column. An empty-string
/// `userId` represents the logged-out / demo (seeded) data set.
const _userScopedTables = [
  'sources',
  'categories',
  'transactions',
  'wishlist_items',
  'routine_transactions',
  'routine_payments',
  'activity_categories',
  'activity_templates',
  'daily_activities',
  'pending_deletes',
  'insulin_items',
  'insulin_assigns',
  'insulin_usages',
  'blood_sugar_logs',
];

const _legacyUserScopedTables = [
  'sources',
  'categories',
  'transactions',
  'insulin_items',
  'insulin_assigns',
  'insulin_usages',
];

class AppDb {
  static final AppDb instance = AppDb._();
  AppDb._();

  late Database _db;

  Future<void> init(DatabaseFactory factory) async {
    final path =
        join(await factory.getDatabasesPath(), 'personal_dashboard.db');
    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE sources (
            id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            syncState TEXT DEFAULT 'pending',
            updatedAt TEXT NOT NULL,
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE categories (
            id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            syncState TEXT DEFAULT 'pending',
            updatedAt TEXT NOT NULL,
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE transactions (
            id TEXT NOT NULL,
            type TEXT NOT NULL,
            amount REAL NOT NULL,
            description TEXT DEFAULT '',
            category TEXT,
            source TEXT,
            fromSource TEXT,
            toSource TEXT,
            date TEXT NOT NULL,
            syncState TEXT DEFAULT 'pending',
            updatedAt TEXT NOT NULL,
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE wishlist_items (
            id TEXT NOT NULL,
            itemName TEXT NOT NULL,
            price REAL NOT NULL,
            transactionType TEXT NOT NULL DEFAULT 'spending',
            categoryId TEXT,
            categoryName TEXT,
            notes TEXT,
            priority TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            fulfilledPrice REAL,
            fulfilledAt TEXT,
            canceledAt TEXT,
            createdDate TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE routine_transactions (
            id TEXT NOT NULL,
            itemName TEXT NOT NULL,
            price REAL NOT NULL,
            reminder TEXT NOT NULL,
            categoryId TEXT NOT NULL,
            categoryName TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            lastBoughtAt TEXT,
            createdDate TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE routine_payments (
            id TEXT NOT NULL,
            routineId TEXT NOT NULL,
            itemName TEXT NOT NULL,
            price REAL NOT NULL,
            categoryId TEXT NOT NULL,
            categoryName TEXT NOT NULL,
            sourceId TEXT NOT NULL,
            sourceName TEXT NOT NULL,
            boughtAt TEXT NOT NULL,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await _createActivityTables(db);
          await db.execute('''CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT
          )''');
          await _createPendingDeletesTable(db);
          await db.execute('''CREATE TABLE insulin_items (
            id TEXT NOT NULL,
            name TEXT NOT NULL,
            units REAL NOT NULL,
            uom TEXT NOT NULL,
            date TEXT NOT NULL,
            notes TEXT,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE insulin_assigns (
            id TEXT NOT NULL,
            itemId TEXT NOT NULL,
            batchNo TEXT NOT NULL,
            date TEXT NOT NULL,
            itemName TEXT DEFAULT '',
            totalUnits REAL DEFAULT 0,
            lastUsedAt TEXT,
            notes TEXT,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE insulin_usages (
            id TEXT NOT NULL,
            assignId TEXT NOT NULL,
            units REAL NOT NULL,
            date TEXT NOT NULL,
            notes TEXT,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
          await db.execute('''CREATE TABLE blood_sugar_logs (
            id TEXT NOT NULL,
            level REAL NOT NULL,
            unit TEXT NOT NULL,
            measuredAt TEXT NOT NULL,
            mealContext TEXT,
            notes TEXT,
            syncState TEXT DEFAULT 'synced',
            userId TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (id, userId)
          )''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('DROP TABLE IF EXISTS insulin_items');
            await db.execute('DROP TABLE IF EXISTS insulin_assigns');
            await db.execute('''CREATE TABLE insulin_items (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              units REAL NOT NULL,
              uom TEXT NOT NULL,
              date TEXT NOT NULL,
              notes TEXT
            )''');
            await db.execute('''CREATE TABLE insulin_assigns (
              id TEXT PRIMARY KEY,
              itemId TEXT NOT NULL,
              batchNo TEXT NOT NULL,
              date TEXT NOT NULL,
              itemName TEXT DEFAULT '',
              totalUnits REAL DEFAULT 0,
              lastUsedAt TEXT,
              notes TEXT
            )''');
          }
          if (oldVersion < 3) {
            // Existing cached rows can't be attributed to a user in
            // hindsight, so they become part of the logged-out/demo
            // (userId = '') data set.
            for (final table in _legacyUserScopedTables) {
              await db.execute(
                  "ALTER TABLE $table ADD COLUMN userId TEXT NOT NULL DEFAULT ''");
            }
          }
          if (oldVersion < 4) {
            await _migrateToPerUserPrimaryKeys(db);
          }
          if (oldVersion < 5) {
            await db.execute('''CREATE TABLE IF NOT EXISTS blood_sugar_logs (
              id TEXT NOT NULL,
              level REAL NOT NULL,
              unit TEXT NOT NULL,
              measuredAt TEXT NOT NULL,
              mealContext TEXT,
              notes TEXT,
              userId TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (id, userId)
            )''');
          }
          if (oldVersion < 6) {
            await _addColumnIfMissing(
                db, 'insulin_items', "syncState TEXT DEFAULT 'synced'");
            await _addColumnIfMissing(
                db, 'insulin_assigns', "syncState TEXT DEFAULT 'synced'");
            await _addColumnIfMissing(
                db, 'insulin_usages', "syncState TEXT DEFAULT 'synced'");
            await _addColumnIfMissing(
                db, 'blood_sugar_logs', "syncState TEXT DEFAULT 'synced'");
          }
          if (oldVersion < 7) {
            await _createWishlistAndRoutineTables(db);
          }
          if (oldVersion < 8) {
            await _createActivityTables(db);
          }
          if (oldVersion < 9) {
            await _addColumnIfMissing(
                db, 'activity_templates', "category TEXT DEFAULT ''");
            await _addColumnIfMissing(
                db, 'daily_activities', "category TEXT DEFAULT ''");
          }
          if (oldVersion < 10) {
            await _addColumnIfMissing(db, 'wishlist_items',
                "transactionType TEXT NOT NULL DEFAULT 'spending'");
            await _addColumnIfMissing(db, 'wishlist_items', 'categoryId TEXT');
            await _addColumnIfMissing(
                db, 'wishlist_items', 'categoryName TEXT');
          }
          if (oldVersion < 11) {
            await _createActivityCategoryTable(db);
          }
          if (oldVersion < 12) {
            await _addColumnIfMissing(
                db, 'activity_categories', "syncState TEXT DEFAULT 'synced'");
          }
          if (oldVersion < 13) {
            await _addColumnIfMissing(db, 'activity_categories', 'id TEXT');
            await _addColumnIfMissing(
                db, 'activity_categories', "updatedAt TEXT DEFAULT ''");
          }
          if (oldVersion < 14) {
            await _createPendingDeletesTable(db);
          }
        },
      ),
    );
  }

  // ── Sources ────────────────────────────────────────────────────────
  Future<List<Source>> getSources(String userId) async {
    final rows =
        await _db.query('sources', where: 'userId = ?', whereArgs: [userId]);
    return rows.map(Source.fromMap).toList();
  }

  Future<void> putSource(Source s, String userId) async {
    await _db.insert('sources', {...s.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteSource(String id, String userId) async {
    await _db.delete('sources',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<Source>> getPendingSources(String userId) async {
    final rows = await _db.query('sources',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'updatedAt ASC');
    return rows.map(Source.fromMap).toList();
  }

  // ── Categories ─────────────────────────────────────────────────────
  Future<List<Category>> getCategories(String userId) async {
    final rows =
        await _db.query('categories', where: 'userId = ?', whereArgs: [userId]);
    return rows.map(Category.fromMap).toList();
  }

  Future<void> putCategory(Category c, String userId) async {
    await _db.insert('categories', {...c.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteCategory(String id, String userId) async {
    await _db.delete('categories',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<Category>> getPendingCategories(String userId) async {
    final rows = await _db.query('categories',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'updatedAt ASC');
    return rows.map(Category.fromMap).toList();
  }

  // ── Transactions ───────────────────────────────────────────────────
  Future<List<Transaction>> getTransactions(String userId) async {
    final rows = await _db.query('transactions',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'date DESC');
    return rows.map(Transaction.fromMap).toList();
  }

  Future<void> putTransaction(Transaction t, String userId) async {
    await _db.insert('transactions', {...t.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteTransaction(String id, String userId) async {
    await _db.delete('transactions',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  /// Transactions created while the API was unreachable ("local mode"),
  /// queued here until [Repo.syncPendingTransactions] can push them.
  Future<List<Transaction>> getPendingTransactions(String userId) async {
    final rows = await _db.query('transactions',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'date ASC');
    return rows.map(Transaction.fromMap).toList();
  }

  // Delete queue
  Future<void> putPendingDelete(PendingDelete item, String userId) async {
    await _ensurePendingDeletesTable();
    await _db.insert('pending_deletes', {...item.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PendingDelete>> getPendingDeletes(String userId) async {
    await _ensurePendingDeletesTable();
    final rows = await _db.query('pending_deletes',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'updatedAt ASC');
    return rows.map(PendingDelete.fromMap).toList();
  }

  Future<void> deletePendingDelete(PendingDelete item, String userId) async {
    await _ensurePendingDeletesTable();
    await _db.delete('pending_deletes',
        where: 'id = ? AND resource = ? AND userId = ?',
        whereArgs: [item.id, item.resource, userId]);
  }

  Future<void> _ensurePendingDeletesTable() => _createPendingDeletesTable(_db);

  // ── Meta ───────────────────────────────────────────────────────────
  // Wishlist
  Future<List<WishlistItem>> getWishlistItems(String userId) async {
    final rows = await _db.query('wishlist_items',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'updatedAt DESC');
    return rows.map(WishlistItem.fromMap).toList();
  }

  Future<List<WishlistItem>> getPendingWishlistItems(String userId) async {
    final rows = await _db.query('wishlist_items',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'updatedAt ASC');
    return rows.map(WishlistItem.fromMap).toList();
  }

  Future<void> putWishlistItem(WishlistItem item, String userId) async {
    await _db.insert('wishlist_items', {...item.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteWishlistItem(String id, String userId) async {
    await _db.delete('wishlist_items',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  // Routine transactions
  Future<List<RoutineTransaction>> getRoutineTransactions(String userId) async {
    final rows = await _db.query('routine_transactions',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'updatedAt DESC');
    return rows.map(RoutineTransaction.fromMap).toList();
  }

  Future<List<RoutineTransaction>> getPendingRoutineTransactions(
      String userId) async {
    final rows = await _db.query('routine_transactions',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'updatedAt ASC');
    return rows.map(RoutineTransaction.fromMap).toList();
  }

  Future<void> putRoutineTransaction(
      RoutineTransaction item, String userId) async {
    await _db.insert(
        'routine_transactions', {...item.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteRoutineTransaction(String id, String userId) async {
    await _db.delete('routine_transactions',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<RoutinePayment>> getRoutinePayments(String userId) async {
    final rows = await _db.query('routine_payments',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'boughtAt DESC');
    return rows.map(RoutinePayment.fromMap).toList();
  }

  Future<List<RoutinePayment>> getPendingRoutinePayments(String userId) async {
    final rows = await _db.query('routine_payments',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'boughtAt ASC');
    return rows.map(RoutinePayment.fromMap).toList();
  }

  Future<void> putRoutinePayment(RoutinePayment item, String userId) async {
    await _db.insert('routine_payments', {...item.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteRoutinePayment(String id, String userId) async {
    await _db.delete('routine_payments',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  // Activities
  Future<List<ActivityCategory>> getActivityCategories(String userId) async {
    final rows = await _db.query('activity_categories',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'LOWER(name) ASC');
    return rows.map(ActivityCategory.fromMap).toList();
  }

  Future<void> putActivityCategory(ActivityCategory category, String userId,
      {String syncState = 'synced'}) async {
    await _db.insert(
        'activity_categories',
        {
          ...category.copyWith(syncState: syncState).toMap(),
          'userId': userId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteActivityCategory(String name, String userId) async {
    await _db.delete('activity_categories',
        where: 'name = ? AND userId = ?', whereArgs: [name, userId]);
  }

  Future<List<ActivityCategory>> getPendingActivityCategories(
      String userId) async {
    final rows = await _db.query('activity_categories',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'LOWER(name) ASC');
    return rows.map(ActivityCategory.fromMap).toList();
  }

  Future<List<ActivityTemplate>> getActivityTemplates(String userId) async {
    final rows = await _db.query('activity_templates',
        where: 'userId = ?',
        whereArgs: [userId],
        orderBy: 'sortOrder ASC, title ASC');
    return rows.map(ActivityTemplate.fromMap).toList();
  }

  Future<void> putActivityTemplate(ActivityTemplate item, String userId) async {
    await _db.insert('activity_templates', {...item.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteActivityTemplate(String id, String userId) async {
    await _db.delete('activity_templates',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<DailyActivity>> getDailyActivities(
      String userId, String activityDate) async {
    final rows = await _db.query('daily_activities',
        where: 'userId = ? AND activityDate = ?',
        whereArgs: [userId, activityDate],
        orderBy: 'doneAt DESC');
    return rows.map(DailyActivity.fromMap).toList();
  }

  Future<List<DailyActivity>> getDailyActivitiesBetween(
      String userId, String startDate, String endDate) async {
    final rows = await _db.query('daily_activities',
        where: 'userId = ? AND activityDate BETWEEN ? AND ?',
        whereArgs: [userId, startDate, endDate],
        orderBy: 'activityDate DESC, doneAt DESC');
    return rows.map(DailyActivity.fromMap).toList();
  }

  Future<void> putDailyActivity(DailyActivity item, String userId) async {
    await _db.insert('daily_activities', {...item.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteDailyActivity(String id, String userId) async {
    await _db.delete('daily_activities',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<String?> getMeta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    await _db.insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── Insulin ────────────────────────────────────────────────────────
  Future<List<InsulinItem>> getInsulinItems(String userId) async {
    final rows = await _db
        .query('insulin_items', where: 'userId = ?', whereArgs: [userId]);
    return rows.map(InsulinItem.fromMap).toList();
  }

  Future<List<InsulinItem>> getPendingInsulinItems(String userId) async {
    final rows = await _db.query('insulin_items',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'date ASC');
    return rows.map(InsulinItem.fromMap).toList();
  }

  Future<void> putInsulinItem(InsulinItem t, String userId) async {
    await _db.insert('insulin_items', {...t.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteInsulinItem(String id, String userId) async {
    await _db.delete('insulin_items',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<InsulinAssign>> getInsulinAssigns(String userId) async {
    final rows = await _db
        .query('insulin_assigns', where: 'userId = ?', whereArgs: [userId]);
    return rows.map(InsulinAssign.fromMap).toList();
  }

  Future<List<InsulinAssign>> getPendingInsulinAssigns(String userId) async {
    final rows = await _db.query('insulin_assigns',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'date ASC');
    return rows.map(InsulinAssign.fromMap).toList();
  }

  Future<void> putInsulinAssign(InsulinAssign t, String userId) async {
    await _db.insert('insulin_assigns', {...t.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteInsulinAssign(String id, String userId) async {
    await _db.delete('insulin_assigns',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<InsulinUsage>> getInsulinUsages(String userId) async {
    final rows = await _db
        .query('insulin_usages', where: 'userId = ?', whereArgs: [userId]);
    return rows.map(InsulinUsage.fromMap).toList();
  }

  Future<List<InsulinUsage>> getPendingInsulinUsages(String userId) async {
    final rows = await _db.query('insulin_usages',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'date ASC');
    return rows.map(InsulinUsage.fromMap).toList();
  }

  Future<void> putInsulinUsage(InsulinUsage t, String userId) async {
    await _db.insert('insulin_usages', {...t.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteInsulinUsage(String id, String userId) async {
    await _db.delete('insulin_usages',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  Future<List<BloodSugarLog>> getBloodSugarLogs(String userId) async {
    final rows = await _db.query('blood_sugar_logs',
        where: 'userId = ?', whereArgs: [userId], orderBy: 'measuredAt DESC');
    return rows.map(BloodSugarLog.fromMap).toList();
  }

  Future<List<BloodSugarLog>> getPendingBloodSugarLogs(String userId) async {
    final rows = await _db.query('blood_sugar_logs',
        where: "userId = ? AND syncState = 'pending'",
        whereArgs: [userId],
        orderBy: 'measuredAt ASC');
    return rows.map(BloodSugarLog.fromMap).toList();
  }

  Future<void> putBloodSugarLog(BloodSugarLog t, String userId) async {
    await _db.insert('blood_sugar_logs', {...t.toMap(), 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteBloodSugarLog(String id, String userId) async {
    await _db.delete('blood_sugar_logs',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
  }

  // ── Bulk replace (online-first cache refresh) ───────────────────────
  Future<void> replaceSources(List<Source> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('sources',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final s in items) {
        await txn.insert('sources', {...s.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceCategories(List<Category> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('categories',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final c in items) {
        await txn.insert('categories', {...c.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Replaces the cached server transactions while preserving any rows
  /// still queued in "local mode" (`syncState == 'pending'`), so an
  /// offline-created transaction isn't wiped out before it's synced.
  Future<void> replaceTransactions(
      List<Transaction> items, String userId) async {
    final pendingDeletes = await getPendingDeletes(userId);
    final deletedIds = pendingDeletes
        .where((item) => item.resource == 'transaction')
        .expand((item) =>
            [item.id, if (item.secondaryId != null) item.secondaryId!])
        .toSet();
    await _db.transaction((txn) async {
      await txn.delete('transactions',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final t in items) {
        if (t.type == 'transfer') {
          final parts = t.id.split('_');
          final firstId = parts.first;
          final secondId = parts.length > 1 ? parts.sublist(1).join('_') : '';
          if (deletedIds.contains(firstId) || deletedIds.contains(secondId)) {
            continue;
          }
        } else if (deletedIds.contains(t.id)) {
          continue;
        }
        await txn.insert('transactions', {...t.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceWishlistItems(
      List<WishlistItem> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('wishlist_items',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final item in items) {
        await txn.insert('wishlist_items', {...item.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceRoutineTransactions(
      List<RoutineTransaction> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('routine_transactions',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final item in items) {
        await txn.insert(
            'routine_transactions', {...item.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceRoutinePayments(
      List<RoutinePayment> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('routine_payments',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final item in items) {
        await txn.insert(
            'routine_payments', {...item.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceInsulinItems(
      List<InsulinItem> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('insulin_items',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final i in items) {
        await txn.insert('insulin_items', {...i.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceInsulinAssigns(
      List<InsulinAssign> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('insulin_assigns',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final a in items) {
        await txn.insert('insulin_assigns', {...a.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  // ── Bulk ───────────────────────────────────────────────────────────
  Future<void> replaceInsulinUsages(
      List<InsulinUsage> items, String userId) async {
    final pendingDeletes = await getPendingDeletes(userId);
    final deletedIds = pendingDeletes
        .where((item) => item.resource == 'insulin_usage')
        .map((item) => item.id)
        .toSet();
    await _db.transaction((txn) async {
      await txn.delete('insulin_usages',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final u in items) {
        if (deletedIds.contains(u.id)) continue;
        await txn.insert('insulin_usages', {...u.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> replaceBloodSugarLogs(
      List<BloodSugarLog> items, String userId) async {
    await _db.transaction((txn) async {
      await txn.delete('blood_sugar_logs',
          where: "userId = ? AND syncState != 'pending'", whereArgs: [userId]);
      for (final log in items) {
        await txn.insert('blood_sugar_logs', {...log.toMap(), 'userId': userId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<int> getPendingWriteCount(String userId) async {
    final results = await Future.wait([
      getPendingSources(userId),
      getPendingCategories(userId),
      getPendingActivityCategories(userId),
      getPendingTransactions(userId),
      getPendingWishlistItems(userId),
      getPendingRoutineTransactions(userId),
      getPendingRoutinePayments(userId),
      getPendingDeletes(userId),
      getPendingInsulinItems(userId),
      getPendingInsulinAssigns(userId),
      getPendingInsulinUsages(userId),
      getPendingBloodSugarLogs(userId),
    ]);
    return results.fold<int>(0, (sum, rows) => sum + rows.length);
  }

  Future<void> clearAll() async {
    for (final table in [..._userScopedTables, 'meta']) {
      await _db.delete(table);
    }
  }
}

/// Version 3 added `userId`, but retained `id` as a global primary key.
/// Rebuild the scoped tables so identical server IDs can be cached for
/// different users without one account replacing another account's row.
Future<void> _migrateToPerUserPrimaryKeys(Database db) async {
  const schemas = <String, String>{
    'sources': '''CREATE TABLE sources (
      id TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      syncState TEXT DEFAULT 'pending',
      updatedAt TEXT NOT NULL,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
    'categories': '''CREATE TABLE categories (
      id TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      syncState TEXT DEFAULT 'pending',
      updatedAt TEXT NOT NULL,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
    'transactions': '''CREATE TABLE transactions (
      id TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      description TEXT DEFAULT '',
      category TEXT,
      source TEXT,
      fromSource TEXT,
      toSource TEXT,
      date TEXT NOT NULL,
      syncState TEXT DEFAULT 'pending',
      updatedAt TEXT NOT NULL,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
    'insulin_items': '''CREATE TABLE insulin_items (
      id TEXT NOT NULL,
      name TEXT NOT NULL,
      units REAL NOT NULL,
      uom TEXT NOT NULL,
      date TEXT NOT NULL,
      notes TEXT,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
    'insulin_assigns': '''CREATE TABLE insulin_assigns (
      id TEXT NOT NULL,
      itemId TEXT NOT NULL,
      batchNo TEXT NOT NULL,
      date TEXT NOT NULL,
      itemName TEXT DEFAULT '',
      totalUnits REAL DEFAULT 0,
      lastUsedAt TEXT,
      notes TEXT,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
    'insulin_usages': '''CREATE TABLE insulin_usages (
      id TEXT NOT NULL,
      assignId TEXT NOT NULL,
      units REAL NOT NULL,
      date TEXT NOT NULL,
      notes TEXT,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
    'blood_sugar_logs': '''CREATE TABLE blood_sugar_logs (
      id TEXT NOT NULL,
      level REAL NOT NULL,
      unit TEXT NOT NULL,
      measuredAt TEXT NOT NULL,
      mealContext TEXT,
      notes TEXT,
      userId TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (id, userId)
    )''',
  };

  const columns = <String, String>{
    'sources': 'id, name, kind, syncState, updatedAt, userId',
    'categories': 'id, name, kind, syncState, updatedAt, userId',
    'transactions':
        'id, type, amount, description, category, source, fromSource, toSource, date, syncState, updatedAt, userId',
    'insulin_items': 'id, name, units, uom, date, notes, userId',
    'insulin_assigns':
        'id, itemId, batchNo, date, itemName, totalUnits, lastUsedAt, notes, userId',
    'insulin_usages': 'id, assignId, units, date, notes, userId',
    'blood_sugar_logs':
        'id, level, unit, measuredAt, mealContext, notes, userId',
  };

  for (final table in _legacyUserScopedTables) {
    final oldTable = '${table}_v3';
    await db.execute('ALTER TABLE $table RENAME TO $oldTable');
    await db.execute(schemas[table]!);
    await db.execute(
      'INSERT INTO $table (${columns[table]}) '
      'SELECT ${columns[table]} FROM $oldTable',
    );
    await db.execute('DROP TABLE $oldTable');
  }
}

Future<void> _createWishlistAndRoutineTables(Database db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS wishlist_items (
    id TEXT NOT NULL,
    itemName TEXT NOT NULL,
    price REAL NOT NULL,
    transactionType TEXT NOT NULL DEFAULT 'spending',
    categoryId TEXT,
    categoryName TEXT,
    notes TEXT,
    priority TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    fulfilledPrice REAL,
    fulfilledAt TEXT,
    canceledAt TEXT,
    createdDate TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    syncState TEXT DEFAULT 'synced',
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, userId)
  )''');
  await db.execute('''CREATE TABLE IF NOT EXISTS routine_transactions (
    id TEXT NOT NULL,
    itemName TEXT NOT NULL,
    price REAL NOT NULL,
    reminder TEXT NOT NULL,
    categoryId TEXT NOT NULL,
    categoryName TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    lastBoughtAt TEXT,
    createdDate TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    syncState TEXT DEFAULT 'synced',
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, userId)
  )''');
  await db.execute('''CREATE TABLE IF NOT EXISTS routine_payments (
    id TEXT NOT NULL,
    routineId TEXT NOT NULL,
    itemName TEXT NOT NULL,
    price REAL NOT NULL,
    categoryId TEXT NOT NULL,
    categoryName TEXT NOT NULL,
    sourceId TEXT NOT NULL,
    sourceName TEXT NOT NULL,
    boughtAt TEXT NOT NULL,
    syncState TEXT DEFAULT 'synced',
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, userId)
  )''');
}

Future<void> _createActivityCategoryTable(Database db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS activity_categories (
    id TEXT,
    name TEXT NOT NULL,
    syncState TEXT DEFAULT 'synced',
    updatedAt TEXT DEFAULT '',
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (name, userId)
  )''');
}

Future<void> _createActivityTables(Database db) async {
  await _createActivityCategoryTable(db);
  await db.execute('''CREATE TABLE IF NOT EXISTS activity_templates (
    id TEXT NOT NULL,
    title TEXT NOT NULL,
    notes TEXT DEFAULT '',
    category TEXT DEFAULT '',
    sortOrder INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, userId)
  )''');
  await db.execute('''CREATE TABLE IF NOT EXISTS daily_activities (
    id TEXT NOT NULL,
    templateId TEXT DEFAULT '',
    title TEXT NOT NULL,
    notes TEXT DEFAULT '',
    category TEXT DEFAULT '',
    activityDate TEXT NOT NULL,
    doneAt TEXT NOT NULL,
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, userId)
  )''');
}

Future<void> _createPendingDeletesTable(Database db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS pending_deletes (
    id TEXT NOT NULL,
    resource TEXT NOT NULL,
    resourceType TEXT,
    secondaryId TEXT,
    updatedAt TEXT NOT NULL,
    userId TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id, resource, userId)
  )''');
}

Future<void> _addColumnIfMissing(
    Database db, String table, String columnSql) async {
  final column = columnSql.split(RegExp(r'\s+')).first;
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final exists = columns.any((row) => row['name'] == column);
  if (!exists) {
    await db.execute('ALTER TABLE $table ADD COLUMN $columnSql');
  }
}
