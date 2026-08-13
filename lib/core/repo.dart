import 'dart:async';

import 'package:uuid/uuid.dart';
import 'db.dart';
import 'config.dart';
import 'models.dart';
import 'remote_api.dart';
import 'sync.dart';

const _uuid = Uuid();

/// Online-first data layer. When configured (a username is set) and online,
/// reads go straight to transaction-api / health-api and the result is
/// cached locally; otherwise (offline, or not yet configured) cached/seeded
/// data from SQLite is used.
///
/// Writes go straight to the REST APIs. If a write fails because the API is
/// unreachable ([ApiUnavailableException] - timeout or connection failure),
/// the transaction is saved locally with `syncState: 'pending'` ("local
/// mode") and [syncPendingTransactions] retries it once the API is reachable
/// again (see [SyncService]).
class Repo {
  static final Repo instance = Repo._();
  Repo._();

  String _nowIso() => DateTime.now().toIso8601String();
  String _nowGmtPlus7Iso() {
    final d = DateTime.now().toUtc().add(const Duration(hours: 7));
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}'
        'T${two(d.hour)}:${two(d.minute)}:${two(d.second)}'
        '.${three(d.millisecond)}';
  }

  AppConfig get _cfg => ConfigService.instance.current;

  /// Scopes the local SQLite cache to the signed-in user. An empty string
  /// (logged out) maps to the seeded/demo data set.
  String get _userId => _cfg.userId;

  // ── Aggregate read ───────────────────────────────────────────────────
  Future<AppData> all() async {
    try {
      final remote = await refreshRemote();
      if (remote != null) return remote;
    } catch (_) {
      // Fall back to local cache below.
    }
    return cached();
  }

  Future<AppData> cached() => _fromCache(_userId);

  Future<AppData?> refreshRemote() async {
    final cfg = _cfg;
    if (!cfg.isLoggedIn || !SyncService.instance.isOnline) return null;
    try {
      final data = await _fetchRemote(cfg);
      await _cacheRemote(data, cfg.userId);
      return _withPending(data, cfg.userId);
    } on ApiUnauthorizedException {
      // Keep the saved session. The dashboard can continue using cached data,
      // and explicit logout remains the only automatic route back to /login.
      return null;
    }
  }

  /// Merges records still queued in "local mode" into freshly-fetched remote
  /// [data] so they remain visible until sync pushes them.
  Future<AppData> _withPending(AppData data, String userId) async {
    final results = await Future.wait([
      AppDb.instance.getPendingSources(userId),
      AppDb.instance.getPendingCategories(userId),
      AppDb.instance.getPendingTransactions(userId),
      AppDb.instance.getPendingWishlistItems(userId),
      AppDb.instance.getPendingRoutineTransactions(userId),
      AppDb.instance.getPendingRoutinePayments(userId),
      AppDb.instance.getPendingInsulinItems(userId),
      AppDb.instance.getPendingInsulinAssigns(userId),
      AppDb.instance.getPendingInsulinUsages(userId),
      AppDb.instance.getPendingDeletes(userId),
      AppDb.instance.getPendingBloodSugarLogs(userId),
      AppDb.instance.getPendingTransactionDetails(userId),
      AppDb.instance.getPendingConsumables(userId),
      AppDb.instance.getPendingInvestments(userId),
    ]);
    final pendingSources = results[0] as List<Source>;
    final pendingCategories = results[1] as List<Category>;
    final pendingTransactions = results[2] as List<Transaction>;
    final pendingWishlistItems = results[3] as List<WishlistItem>;
    final pendingRoutineTransactions = results[4] as List<RoutineTransaction>;
    final pendingRoutinePayments = results[5] as List<RoutinePayment>;
    final pendingInsulinItems = results[6] as List<InsulinItem>;
    final pendingInsulinAssigns = results[7] as List<InsulinAssign>;
    final pendingInsulinUsages = results[8] as List<InsulinUsage>;
    final pendingDeletes = results[9] as List<PendingDelete>;
    final pendingBloodSugarLogs = results[10] as List<BloodSugarLog>;
    final pendingTransactionDetails = results[11] as List<TransactionDetail>;
    final pendingConsumables = results[12] as List<Consumable>;
    final pendingInvestments = results[13] as List<Investment>;
    if (results.every((rows) => rows.isEmpty)) return data;

    List<T> mergePending<T>(
      List<T> pending,
      List<T> current,
      String Function(T item) idOf,
    ) {
      final pendingIds = pending.map(idOf).toSet();
      return [
        ...pending,
        ...current.where((item) => !pendingIds.contains(idOf(item))),
      ];
    }

    final sources = mergePending(
      pendingSources,
      data.sources,
      (source) => source.id,
    );
    final categories = mergePending(
      pendingCategories,
      data.categories,
      (category) => category.id,
    );
    final deletedTransactionIds = pendingDeletes
        .where((item) => item.resource == 'transaction')
        .expand((item) =>
            [item.id, if (item.secondaryId != null) item.secondaryId!])
        .toSet();
    final deletedInsulinUsageIds = pendingDeletes
        .where((item) => item.resource == 'insulin_usage')
        .map((item) => item.id)
        .toSet();

    final transactions = mergePending(
      pendingTransactions,
      data.transactions.where((t) {
        if (t.type == 'transfer') {
          final ids = _transactionDeleteIds(t);
          return !deletedTransactionIds.contains(ids.$1) &&
              (ids.$2 == null || !deletedTransactionIds.contains(ids.$2));
        }
        return !deletedTransactionIds.contains(t.id);
      }).toList(),
      (transaction) => transaction.id,
    )..sort((a, b) => b.date.compareTo(a.date));
    final wishlistItems = mergePending(
      pendingWishlistItems,
      data.wishlistItems,
      (item) => item.id,
    )..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final routineTransactions = mergePending(
      pendingRoutineTransactions,
      data.routineTransactions,
      (item) => item.id,
    )..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final routinePayments = mergePending(
      pendingRoutinePayments,
      data.routinePayments,
      (payment) => payment.id,
    )..sort((a, b) => b.boughtAt.compareTo(a.boughtAt));
    final insulinItems = mergePending(
      pendingInsulinItems,
      data.insulinItems,
      (item) => item.id,
    );
    final insulinAssigns = mergePending(
      pendingInsulinAssigns,
      data.insulinAssigns,
      (assign) => assign.id,
    );
    final insulinUsages = mergePending(
      pendingInsulinUsages,
      data.insulinUsages
          .where((usage) => !deletedInsulinUsageIds.contains(usage.id))
          .toList(),
      (usage) => usage.id,
    )..sort((a, b) => b.date.compareTo(a.date));
    final bloodSugarLogs = mergePending(
      pendingBloodSugarLogs,
      data.bloodSugarLogs,
      (log) => log.id,
    )..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
    final transactionDetails = mergePending(
      pendingTransactionDetails,
      data.transactionDetails,
      (detail) => detail.id,
    );
    final consumables = mergePending(
      pendingConsumables,
      data.consumables,
      (item) => item.id,
    )..sort((a, b) => b.inDate.compareTo(a.inDate));
    final investments = mergePending(
      pendingInvestments,
      data.investments,
      (item) => item.id,
    )..sort((a, b) => b.acquiredDate.compareTo(a.acquiredDate));
    return AppData(
      sources: sources,
      categories: categories,
      transactions: transactions,
      transactionDetails: transactionDetails,
      wishlistItems: wishlistItems,
      routineTransactions: routineTransactions,
      routinePayments: routinePayments,
      consumables: consumables,
      investments: investments,
      insulinItems: insulinItems,
      insulinAssigns: insulinAssigns,
      insulinUsages: insulinUsages,
      bloodSugarLogs: bloodSugarLogs,
    );
  }

  Future<AppData> _fromCache(String userId) async {
    final results = await Future.wait([
      AppDb.instance.getSources(userId),
      AppDb.instance.getCategories(userId),
      AppDb.instance.getTransactions(userId),
      AppDb.instance.getWishlistItems(userId),
      AppDb.instance.getRoutineTransactions(userId),
      AppDb.instance.getRoutinePayments(userId),
      AppDb.instance.getInsulinItems(userId),
      AppDb.instance.getInsulinAssigns(userId),
      AppDb.instance.getInsulinUsages(userId),
      AppDb.instance.getBloodSugarLogs(userId),
      AppDb.instance.getTransactionDetails(userId),
      AppDb.instance.getConsumables(userId),
      AppDb.instance.getInvestments(userId),
    ]);
    return AppData(
      sources: results[0] as List<Source>,
      categories: results[1] as List<Category>,
      transactions: results[2] as List<Transaction>,
      wishlistItems: results[3] as List<WishlistItem>,
      routineTransactions: results[4] as List<RoutineTransaction>,
      routinePayments: results[5] as List<RoutinePayment>,
      insulinItems: results[6] as List<InsulinItem>,
      insulinAssigns: results[7] as List<InsulinAssign>,
      insulinUsages: results[8] as List<InsulinUsage>,
      bloodSugarLogs: results[9] as List<BloodSugarLog>,
      transactionDetails: results[10] as List<TransactionDetail>,
      consumables: results[11] as List<Consumable>,
      investments: results[12] as List<Investment>,
    );
  }

  Future<AppData> _fetchRemote(AppConfig cfg) async {
    final api = RemoteApi(cfg);

    final results = await Future.wait([
      api.getSources(),
      api.getEarningCategories(),
      api.getSpendingCategories(),
      api.getPlannedExpenseCategories(),
      api.getEarnings(),
      api.getSpendings(),
      api.getWishlist(),
      api.getRoutines(),
      api.getRoutinePayments(),
    ]);
    final rawSources = results[0];
    final rawEarningCats = results[1];
    final rawSpendingCats = results[2];
    final rawPlannedExpenseCats = results[3];
    final rawEarnings = results[4];
    final rawSpendings = results[5];
    final rawWishlist = results[6];
    final rawRoutines = results[7];
    final rawRoutinePayments = results[8];

    // Line items are best-effort: an older transaction-api without
    // /api/user/spending-details must not break the whole refresh. On failure
    // keep whatever is cached locally rather than wiping the breakdowns.
    List<TransactionDetail>? fetchedDetails;
    try {
      fetchedDetails = (await api.getSpendingDetails())
          .map(TransactionDetail.fromApi)
          .toList();
    } catch (_) {
      fetchedDetails = null;
    }
    final transactionDetails = fetchedDetails ??
        await AppDb.instance.getTransactionDetails(cfg.userId);

    // Same treatment for consumables: an older transaction-api without
    // /api/user/consumables must not take the whole refresh down with it.
    List<Consumable>? fetchedConsumables;
    try {
      fetchedConsumables =
          (await api.getConsumables()).map(Consumable.fromApi).toList();
    } catch (_) {
      fetchedConsumables = null;
    }
    final consumables =
        fetchedConsumables ?? await AppDb.instance.getConsumables(cfg.userId);

    // And for investments, which an API older than the Investment page does
    // not serve at all.
    List<Investment>? fetchedInvestments;
    try {
      fetchedInvestments =
          (await api.getInvestments()).map(Investment.fromApi).toList();
    } catch (_) {
      fetchedInvestments = null;
    }
    final investments =
        fetchedInvestments ?? await AppDb.instance.getInvestments(cfg.userId);

    String? transferCategoryName;
    try {
      final settings = await api.getSettings();
      for (final s in settings) {
        if (s['app_setting_key'] == 'TRANSFER_CATEGORY_NAME') {
          transferCategoryName = s['app_setting_value'] as String?;
        }
      }
      // Same payload carries the account's FEATURE_* flags, so this is where
      // a toggle made on another device lands.
      await ConfigService.instance.applyRemoteSettings(settings);
    } catch (_) {
      // transfer pairing and flag sync are both best-effort
    }

    final existingKinds = {
      for (final s in await AppDb.instance.getSources(cfg.userId)) s.id: s.kind,
    };

    final sources = rawSources.map((m) {
      final id = m['source_id'] as String;
      return Source(
        id: id,
        name: m['source'] as String,
        kind: existingKinds[id] ?? 'cash',
        syncState: 'synced',
        updatedAt: (m['created_date'] ?? _nowIso()).toString(),
      );
    }).toList();

    final categories = <Category>[
      ...rawEarningCats.map((m) => Category(
            id: m['earning_category_id'] as String,
            name: m['earning_category'] as String,
            kind: 'earning',
            syncState: 'synced',
            updatedAt: (m['created_date'] ?? _nowIso()).toString(),
          )),
      ...rawSpendingCats.map((m) => Category(
            id: m['spending_category_id'] as String,
            name: m['spending_category'] as String,
            kind: 'spending',
            syncState: 'synced',
            updatedAt: (m['created_date'] ?? _nowIso()).toString(),
          )),
      ...rawPlannedExpenseCats.map((m) => Category(
            id: m['planned_expense_category_id'] as String,
            name: m['planned_expense_category'] as String,
            kind: 'planned_expense',
            syncState: 'synced',
            updatedAt: (m['created_date'] ?? _nowIso()).toString(),
          )),
    ];

    final transactions =
        _pairTransfers(rawEarnings, rawSpendings, transferCategoryName);
    final wishlistItems = rawWishlist.map(WishlistItem.fromMap).toList();
    final routineTransactions =
        rawRoutines.map(RoutineTransaction.fromMap).toList();
    final routinePayments =
        rawRoutinePayments.map(RoutinePayment.fromMap).toList();

    var insulinItems = <InsulinItem>[];
    var insulinAssigns = <InsulinAssign>[];
    var insulinUsages = <InsulinUsage>[];
    var bloodSugarLogs = <BloodSugarLog>[];
    var healthFetched = false;
    try {
      final healthResults = await Future.wait([
        api.getInsulinItems(),
        api.getInsulinAssignUsage(),
        api.getInsulinUsages(),
        api.getBloodSugarLogs(),
      ]);
      insulinItems = healthResults[0].map(InsulinItem.fromMap).toList();
      insulinAssigns = healthResults[1].map(InsulinAssign.fromMap).toList();
      insulinUsages = healthResults[2].map(InsulinUsage.fromMap).toList();
      bloodSugarLogs = healthResults[3].map(BloodSugarLog.fromMap).toList();
      healthFetched = true;
    } catch (_) {
      // health-api may be unreachable independently of transaction-api
    }
    if (!healthFetched) {
      insulinItems = await AppDb.instance.getInsulinItems(cfg.userId);
      insulinAssigns = await AppDb.instance.getInsulinAssigns(cfg.userId);
      insulinUsages = await AppDb.instance.getInsulinUsages(cfg.userId);
      bloodSugarLogs = await AppDb.instance.getBloodSugarLogs(cfg.userId);
    }

    return AppData(
      sources: sources,
      categories: categories,
      transactions: transactions,
      transactionDetails: transactionDetails,
      wishlistItems: wishlistItems,
      routineTransactions: routineTransactions,
      routinePayments: routinePayments,
      consumables: consumables,
      investments: investments,
      insulinItems: insulinItems,
      insulinAssigns: insulinAssigns,
      insulinUsages: insulinUsages,
      bloodSugarLogs: bloodSugarLogs,
    );
  }

  /// Earnings/spendings tagged with the "Transfer" category are recombined
  /// into a single `Transaction(type: 'transfer')` when a matching
  /// description+amount pair is found, so balances/cashflow charts (which
  /// special-case `type == 'transfer'`) behave the same as with seed data.
  List<Transaction> _pairTransfers(
    List<Map<String, dynamic>> earnings,
    List<Map<String, dynamic>> spendings,
    String? transferCategoryName,
  ) {
    final txns = <Transaction>[];
    final usedEarnings = <int>{};
    final usedSpendings = <int>{};

    if (transferCategoryName != null) {
      for (var si = 0; si < spendings.length; si++) {
        final s = spendings[si];
        if (s['spending_category'] != transferCategoryName) {
          continue;
        }

        int? bestIdx;
        Duration? bestDiff;
        for (var ei = 0; ei < earnings.length; ei++) {
          if (usedEarnings.contains(ei)) {
            continue;
          }
          final e = earnings[ei];
          if (e['earning_category'] != transferCategoryName) {
            continue;
          }
          if ((e['total_amount'] as num).toDouble() !=
              (s['total_amount'] as num).toDouble()) {
            continue;
          }
          if (e['description'] != s['description']) {
            continue;
          }
          final ed = DateTime.tryParse(e['created_date']?.toString() ?? '');
          final sd = DateTime.tryParse(s['created_date']?.toString() ?? '');
          final diff = (ed != null && sd != null)
              ? ed.difference(sd).abs()
              : Duration.zero;
          if (bestDiff == null || diff < bestDiff) {
            bestDiff = diff;
            bestIdx = ei;
          }
        }

        if (bestIdx != null) {
          final e = earnings[bestIdx];
          usedSpendings.add(si);
          usedEarnings.add(bestIdx);
          txns.add(Transaction(
            id: '${s['spending_id']}_${e['earning_id']}',
            type: 'transfer',
            amount: (s['total_amount'] as num).toDouble(),
            description: s['description'] as String? ?? '',
            fromSource: s['source'] as String?,
            toSource: e['source'] as String?,
            date: (s['created_date'] ?? _nowIso()).toString(),
            syncState: 'synced',
            updatedAt: (s['created_date'] ?? _nowIso()).toString(),
          ));
        }
      }
    }

    for (var i = 0; i < earnings.length; i++) {
      if (usedEarnings.contains(i)) continue;
      final e = earnings[i];
      txns.add(Transaction(
        id: e['earning_id'] as String,
        type: 'earning',
        amount: (e['total_amount'] as num).toDouble(),
        description: e['description'] as String? ?? '',
        category: e['earning_category'] as String?,
        source: e['source'] as String?,
        date: (e['created_date'] ?? _nowIso()).toString(),
        syncState: 'synced',
        updatedAt: (e['created_date'] ?? _nowIso()).toString(),
      ));
    }
    for (var i = 0; i < spendings.length; i++) {
      if (usedSpendings.contains(i)) continue;
      final s = spendings[i];
      txns.add(Transaction(
        id: s['spending_id'] as String,
        type: 'spending',
        amount: (s['total_amount'] as num).toDouble(),
        description: s['description'] as String? ?? '',
        category: s['spending_category'] as String?,
        source: s['source'] as String?,
        date: (s['created_date'] ?? _nowIso()).toString(),
        syncState: 'synced',
        updatedAt: (s['created_date'] ?? _nowIso()).toString(),
      ));
    }

    txns.sort((a, b) => b.date.compareTo(a.date));
    return txns;
  }

  Future<void> _cacheRemote(AppData data, String userId) async {
    await AppDb.instance.replaceSources(data.sources, userId);
    await AppDb.instance.replaceCategories(data.categories, userId);
    await AppDb.instance.replaceTransactions(data.transactions, userId);
    await AppDb.instance
        .replaceTransactionDetails(data.transactionDetails, userId);
    await AppDb.instance.replaceWishlistItems(data.wishlistItems, userId);
    await AppDb.instance
        .replaceRoutineTransactions(data.routineTransactions, userId);
    await AppDb.instance.replaceRoutinePayments(data.routinePayments, userId);
    await AppDb.instance.replaceConsumables(data.consumables, userId);
    await AppDb.instance.replaceInvestments(data.investments, userId);
    await AppDb.instance.replaceInsulinItems(data.insulinItems, userId);
    await AppDb.instance.replaceInsulinAssigns(data.insulinAssigns, userId);
    await AppDb.instance.replaceInsulinUsages(data.insulinUsages, userId);
    await AppDb.instance.replaceBloodSugarLogs(data.bloodSugarLogs, userId);
    await AppDb.instance.setMeta('lastSync', _nowIso());
  }

  // ── Sources ──────────────────────────────────────────────────────────
  Future<Source> createSource(String name, {String kind = 'cash'}) async {
    Future<Source> savePending() async {
      final source = Source(
        id: _uuid.v4(),
        name: name,
        kind: kind,
        syncState: 'pending',
        updatedAt: _nowIso(),
      );
      await AppDb.instance.putSource(source, _userId);
      await _refreshPendingCount();
      return source;
    }

    if (!SyncService.instance.isOnline) {
      return savePending();
    }

    try {
      final m =
          await _withTokenRefresh(() => RemoteApi(_cfg).createSource(name));
      final source = Source(
        id: m['source_id'] as String,
        name: m['source'] as String,
        kind: kind,
        syncState: 'synced',
        updatedAt: _nowIso(),
      );
      await AppDb.instance.putSource(source, _userId);
      return source;
    } on ApiUnavailableException {
      return savePending();
    }
  }

  Future<void> deleteSource(String id) =>
      _withTokenRefresh(() => RemoteApi(_cfg).deleteSource(id));

  // ── Categories ───────────────────────────────────────────────────────
  Future<Category> createCategory(
      {required String name, required String kind}) async {
    Future<Category> savePending() async {
      final category = Category(
        id: _uuid.v4(),
        name: name,
        kind: kind,
        syncState: 'pending',
        updatedAt: _nowIso(),
      );
      await AppDb.instance.putCategory(category, _userId);
      await _refreshPendingCount();
      return category;
    }

    if (!SyncService.instance.isOnline) {
      return savePending();
    }

    try {
      final m = await _withTokenRefresh(() {
        final api = RemoteApi(_cfg);
        if (kind == 'earning') return api.createEarningCategory(name);
        if (kind == 'planned_expense') {
          return api.createPlannedExpenseCategory(name);
        }
        return api.createSpendingCategory(name);
      });
      final category = Category(
        id: (m['earning_category_id'] ??
            m['spending_category_id'] ??
            m['planned_expense_category_id']) as String,
        name: (m['earning_category'] ??
            m['spending_category'] ??
            m['planned_expense_category']) as String,
        kind: kind,
        syncState: 'synced',
        updatedAt: _nowIso(),
      );
      await AppDb.instance.putCategory(category, _userId);
      return category;
    } on ApiUnavailableException {
      return savePending();
    }
  }

  Future<void> deleteCategory({required String id, required String kind}) =>
      _withTokenRefresh(() {
        final api = RemoteApi(_cfg);
        if (kind == 'earning') return api.deleteEarningCategory(id);
        if (kind == 'planned_expense') {
          return api.deletePlannedExpenseCategory(id);
        }
        return api.deleteSpendingCategory(id);
      });

  // ── Transactions (create-only; the APIs have no edit/delete) ─────────
  //
  // Each `createXxx` returns `true` if the API was unreachable and the
  // transaction was queued locally ("local mode"), or `false` if it was
  // sent to the server immediately. Other failures (e.g. validation errors
  // from a reachable server) are thrown as [ApiException] as before.

  Future<bool> createEarning({
    required double amount,
    required String description,
    required Category category,
    required Source source,
  }) async {
    // Stamped once, before the API is even tried, so the transaction carries
    // the moment it was entered whichever branch it takes.
    final enteredAt = _nowGmtPlus7Iso();
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).createEarning(
            totalAmount: amount,
            description: description,
            earningCategoryId: category.id,
            earningCategory: category.name,
            sourceId: source.id,
            source: source.name,
            createdDate: enteredAt,
          ));
      return false;
    } on ApiUnavailableException {
      await _queuePending(Transaction(
        id: _uuid.v4(),
        type: 'earning',
        amount: amount,
        description: description,
        category: category.name,
        source: source.name,
        date: enteredAt,
        syncState: 'pending',
        updatedAt: _nowIso(),
      ));
      return true;
    }
  }

  /// Creates a spending, optionally with a line-item breakdown ([details]).
  /// Details come from the Add-transaction screen's item editor, which the
  /// receipt scanner pre-fills from a recognised price list.
  ///
  /// Returns `true` when the API was unreachable and the transaction (with its
  /// details) was queued locally instead.
  Future<bool> createSpending({
    required double amount,
    required String description,
    required Category category,
    required Source source,
    List<TransactionDetail> details = const [],
  }) async {
    final enteredAt = _nowGmtPlus7Iso();
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).createSpending(
            totalAmount: amount,
            description: description,
            spendingCategoryId: category.id,
            spendingCategory: category.name,
            sourceId: source.id,
            source: source.name,
            details: details.map((d) => d.toApiPayload()).toList(),
            createdDate: enteredAt,
          ));
      return false;
    } on ApiUnavailableException {
      final localId = _uuid.v4();
      await _queuePending(Transaction(
        id: localId,
        type: 'spending',
        amount: amount,
        description: description,
        category: category.name,
        source: source.name,
        date: enteredAt,
        syncState: 'pending',
        updatedAt: _nowIso(),
      ));
      await _queuePendingDetails(localId, details);
      return true;
    }
  }

  /// Stores [details] against a locally-queued transaction so the breakdown
  /// survives until the parent spending is pushed to the server.
  Future<void> _queuePendingDetails(
      String transactionId, List<TransactionDetail> details) async {
    if (details.isEmpty) return;
    await AppDb.instance.putTransactionDetails(
      details
          .map((d) => d.copyWith(
                id: d.id.isEmpty ? _uuid.v4() : d.id,
                transactionId: transactionId,
                syncState: 'pending',
                updatedAt: _nowIso(),
              ))
          .toList(),
      _userId,
    );
  }

  /// Line items for [transactionId], read straight from the local cache.
  Future<List<TransactionDetail>> getTransactionDetails(
          String transactionId) async =>
      AppDb.instance.getTransactionDetailsFor(transactionId, _userId);

  /// Ticks or unticks one line item.
  ///
  /// Only the local write is awaited, so the checkbox never waits on the
  /// network. A detail still queued with its parent spending keeps
  /// `syncState: 'pending'` and will be created with the right tick; a synced
  /// one is pushed in the background and, if that fails, left as `'checkDirty'`
  /// for [syncPendingDetailChecks] to retry.
  Future<void> setTransactionDetailChecked(
      TransactionDetail detail, bool checked) async {
    if (detail.syncState == 'pending') {
      await AppDb.instance
          .setTransactionDetailChecked(detail.id, _userId, checked, 'pending');
      return;
    }

    // Written as unpushed up front: if the app dies mid-request the tick is
    // still queued rather than silently lost.
    final userId = _userId;
    await AppDb.instance
        .setTransactionDetailChecked(detail.id, userId, checked, 'checkDirty');
    unawaited(() async {
      try {
        await _withTokenRefresh(() => RemoteApi(_cfg)
            .setSpendingDetailChecked(id: detail.id, checked: checked));
        await AppDb.instance
            .setTransactionDetailChecked(detail.id, userId, checked, 'synced');
      } catch (_) {
        // Leave the row dirty for syncPendingDetailChecks to retry.
      }
      await _refreshPendingCount();
    }());
  }

  /// Pushes ticks that were changed while the API was unreachable.
  Future<void> syncPendingDetailChecks() async {
    final cfg = _cfg;
    final dirty = await AppDb.instance.getDirtyTransactionDetails(cfg.userId);
    if (dirty.isEmpty) return;

    final remote = RemoteApi(cfg);
    for (final detail in dirty) {
      try {
        await remote.setSpendingDetailChecked(
            id: detail.id, checked: detail.checked);
        await AppDb.instance.setTransactionDetailChecked(
            detail.id, cfg.userId, detail.checked, 'synced');
      } catch (_) {
        // Still unreachable, or the item is gone server-side. Leave the row
        // dirty and retry on the next sync.
      }
    }

    await _refreshPendingCount();
  }

  /// Creates a transfer as a paired spending (fromSource) + earning
  /// (toSource), both tagged with the server's configured Transfer category.
  Future<bool> createTransfer({
    required double amount,
    required String description,
    required Source fromSource,
    required Source toSource,
  }) async {
    final enteredAt = _nowGmtPlus7Iso();
    try {
      await _withTokenRefresh(() async {
        final remote = RemoteApi(_cfg);
        final settings = await remote.getSettings();
        String catId = '';
        String catName = 'Transfer';
        for (final s in settings) {
          if (s['app_setting_key'] == 'TRANSFER_CATEGORY_ID') {
            catId = s['app_setting_value'] as String? ?? '';
          }
          if (s['app_setting_key'] == 'TRANSFER_CATEGORY_NAME') {
            catName = s['app_setting_value'] as String? ?? catName;
          }
        }
        if (catId.isEmpty) {
          throw const ApiException(
              'Transfer category is not configured on the server.');
        }
        // Both halves carry the same stamp, which is also what keeps
        // [_pairTransfers] recombining them into one transfer on read.
        await remote.createSpending(
          totalAmount: amount,
          description: description,
          spendingCategoryId: catId,
          spendingCategory: catName,
          sourceId: fromSource.id,
          source: fromSource.name,
          createdDate: enteredAt,
        );
        await remote.createEarning(
          totalAmount: amount,
          description: description,
          earningCategoryId: catId,
          earningCategory: catName,
          sourceId: toSource.id,
          source: toSource.name,
          createdDate: enteredAt,
        );
      });
      return false;
    } on ApiUnavailableException {
      await _queuePending(Transaction(
        id: _uuid.v4(),
        type: 'transfer',
        amount: amount,
        description: description,
        fromSource: fromSource.name,
        toSource: toSource.name,
        date: enteredAt,
        syncState: 'pending',
        updatedAt: _nowIso(),
      ));
      return true;
    }
  }

  Future<void> deleteTransaction(Transaction t) async {
    await AppDb.instance.deleteTransaction(t.id, _userId);

    if (t.syncState == 'pending' || !_cfg.isLoggedIn) {
      await _refreshPendingCount();
      return;
    }

    final ids = _transactionDeleteIds(t);
    await AppDb.instance.putPendingDelete(
      PendingDelete(
        id: ids.$1,
        resource: 'transaction',
        resourceType: t.type,
        secondaryId: ids.$2,
        updatedAt: _nowIso(),
      ),
      _userId,
    );
    await _refreshPendingCount();
  }

  // Wishlist
  Future<WishlistItem> createWishlistItem({
    required String itemName,
    required double price,
    required String transactionType,
    required Category category,
    String? notes,
    required String priority,
  }) async {
    // Stamped once, before the API is even tried, so the item carries the
    // moment it was entered whichever branch it takes.
    final enteredAt = _nowGmtPlus7Iso();
    final item = WishlistItem(
      id: _uuid.v4(),
      itemName: itemName,
      price: price,
      transactionType: transactionType,
      categoryId: category.id,
      categoryName: category.name,
      notes: notes,
      priority: priority,
      createdDate: enteredAt,
      updatedAt: _nowIso(),
    );
    try {
      final m = await _withTokenRefresh(() => RemoteApi(_cfg).createWishlist(
            id: item.id,
            itemName: itemName,
            price: price,
            transactionType: transactionType,
            categoryId: category.id,
            categoryName: category.name,
            notes: notes,
            priority: priority,
            createdDate: enteredAt,
          ));
      final synced = WishlistItem.fromMap(m);
      await AppDb.instance.putWishlistItem(synced, _userId);
      return synced;
    } on ApiUnavailableException {
      final pending = item.copyWith(syncState: 'pending');
      await AppDb.instance.putWishlistItem(pending, _userId);
      await _refreshPendingCount();
      return pending;
    }
  }

  Future<bool> fulfillWishlistItem({
    required WishlistItem item,
    required double price,
    required Category category,
    required Source source,
  }) async {
    final savedLocally = item.transactionType == 'earning'
        ? await createEarning(
            amount: price,
            description: item.itemName,
            category: category,
            source: source,
          )
        : await createSpending(
            amount: price,
            description: item.itemName,
            category: category,
            source: source,
          );
    final fulfilledAt = _nowGmtPlus7Iso();
    final updated = item.copyWith(
      status: 'fulfilled',
      fulfilledPrice: price,
      fulfilledAt: fulfilledAt,
      updatedAt: _nowIso(),
      syncState: 'pending',
    );
    await AppDb.instance.putWishlistItem(updated, _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).updateWishlistStatus(
            id: item.id,
            status: 'fulfilled',
            fulfilledPrice: price,
            changedAt: fulfilledAt,
          ));
      await AppDb.instance
          .putWishlistItem(updated.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      await _refreshPendingCount();
    }
    return savedLocally;
  }

  Future<bool> partialPayWishlistItem({
    required WishlistItem item,
    required double price,
    required Category category,
    required Source source,
  }) async {
    if (price >= item.price) {
      return fulfillWishlistItem(
        item: item,
        price: price,
        category: category,
        source: source,
      );
    }

    final savedLocally = item.transactionType == 'earning'
        ? await createEarning(
            amount: price,
            description: item.itemName,
            category: category,
            source: source,
          )
        : await createSpending(
            amount: price,
            description: item.itemName,
            category: category,
            source: source,
          );
    final updated = item.copyWith(
      price: item.price - price,
      updatedAt: _nowIso(),
      syncState: 'pending',
    );
    await AppDb.instance.putWishlistItem(updated, _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).createWishlist(
            id: updated.id,
            itemName: updated.itemName,
            price: updated.price,
            transactionType: updated.transactionType,
            categoryId: updated.categoryId,
            categoryName: updated.categoryName,
            notes: updated.notes,
            priority: updated.priority,
            createdDate: updated.createdDate,
          ));
      await AppDb.instance
          .putWishlistItem(updated.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      await _refreshPendingCount();
    }
    return savedLocally;
  }

  Future<void> cancelWishlistItem(WishlistItem item) async {
    final canceledAt = _nowGmtPlus7Iso();
    final updated = item.copyWith(
      status: 'canceled',
      canceledAt: canceledAt,
      updatedAt: _nowIso(),
      syncState: 'pending',
    );
    await AppDb.instance.putWishlistItem(updated, _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).updateWishlistStatus(
          id: item.id, status: 'canceled', changedAt: canceledAt));
      await AppDb.instance
          .putWishlistItem(updated.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      await _refreshPendingCount();
    }
  }

  Future<void> removeWishlistItem(WishlistItem item) async {
    await AppDb.instance.deleteWishlistItem(item.id, _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).deleteWishlist(item.id));
    } on ApiUnavailableException {
      await _refreshPendingCount();
    }
  }

  // ── Consumables ──────────────────────────────────────────────────────
  /// Adds [count] units of the same thing, each as its own record.
  ///
  /// Buying a three-pack of shampoo makes three units (1/3, 2/3, 3/3) that
  /// share a name and price but run out on their own dates. [transactionId] /
  /// [transactionDetailId] are set when the units came from a transaction's
  /// line item, so the page can point back at the purchase.
  Future<List<Consumable>> addConsumables({
    required String itemName,
    int count = 1,
    String notes = '',
    double price = 0,
    String inDate = '',
    String transactionId = '',
    String transactionDetailId = '',
  }) async {
    final now = _nowIso();
    final total = count < 1 ? 1 : count;
    final units = [
      for (var i = 0; i < total; i++)
        Consumable(
          id: _uuid.v4(),
          itemName: itemName,
          notes: notes,
          unitIndex: i + 1,
          unitTotal: total,
          price: price,
          inDate: inDate.isEmpty ? now : inDate,
          transactionId: transactionId,
          transactionDetailId: transactionDetailId,
          updatedAt: now,
        ),
    ];
    for (final unit in units) {
      await _saveConsumable(unit);
    }
    return units;
  }

  /// Records the date a unit ran out, or puts it back in use when [outDate] is
  /// empty.
  Future<void> setConsumableOutDate(Consumable unit, String outDate) async {
    final updated =
        unit.copyWith(outDate: outDate, updatedAt: _nowIso());
    await AppDb.instance
        .putConsumable(updated.copyWith(syncState: 'pending'), _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).setConsumableOutDate(
            id: unit.id,
            outDate: outDate.isEmpty ? null : outDate,
          ));
      await AppDb.instance
          .putConsumable(updated.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      // Left pending: the queued write re-posts the whole unit, and the API
      // upserts it, so the out date lands either way.
      await _refreshPendingCount();
    }
  }

  Future<void> removeConsumable(Consumable unit) async {
    await AppDb.instance.deleteConsumable(unit.id, _userId);
    try {
      await _withTokenRefresh(
          () => RemoteApi(_cfg).deleteConsumable(unit.id));
    } on ApiUnavailableException {
      await AppDb.instance.putPendingDelete(
        PendingDelete(
          id: unit.id,
          resource: 'consumable',
          updatedAt: _nowIso(),
        ),
        _userId,
      );
      await _refreshPendingCount();
    }
  }

  /// Writes one unit through to the API, queuing it locally when the API is
  /// unreachable. `POST /consumables` upserts on the client-generated id, so a
  /// retry can never duplicate a unit.
  Future<void> _saveConsumable(Consumable unit) async {
    try {
      await _withTokenRefresh(
          () => RemoteApi(_cfg).createConsumable(unit.toApiPayload()));
      await AppDb.instance
          .putConsumable(unit.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      await AppDb.instance
          .putConsumable(unit.copyWith(syncState: 'pending'), _userId);
      await _refreshPendingCount();
    }
  }

  // ── Investments ──────────────────────────────────────────────────────
  /// Records a new holding, or rewrites an existing one when [id] is given.
  ///
  /// [lastUnitPrice] is left null for a fresh holding: until the first price
  /// refresh (metal) or manual NAB update (fund), the buy price is the best
  /// value known, and the API falls back to it.
  Future<Investment> saveInvestment({
    String? id,
    required InvestmentKind kind,
    required String name,
    String provider = '',
    required double units,
    required double buyUnitPrice,
    double? lastUnitPrice,
    String priceSource = '',
    String priceUpdatedAt = '',
    String notes = '',
    String acquiredDate = '',
  }) async {
    final now = _nowIso();
    final item = Investment(
      id: id ?? _uuid.v4(),
      kind: kind,
      name: name,
      provider: provider,
      units: units,
      buyUnitPrice: buyUnitPrice,
      lastUnitPrice: lastUnitPrice ?? buyUnitPrice,
      priceSource: priceSource,
      priceUpdatedAt: priceUpdatedAt,
      notes: notes,
      acquiredDate: acquiredDate.isEmpty ? now : acquiredDate,
      updatedAt: now,
    );
    await _saveInvestment(item);
    return item;
  }

  /// Records a fresh valuation for one holding - a NAB read off a broker app,
  /// or a gold/silver price pulled from a price API by [MetalPriceService].
  ///
  /// Uses the dedicated price route rather than a full upsert so units and
  /// cost basis stay untouched even if the price is wrong.
  Future<void> updateInvestmentPrice(
    Investment item, {
    required double lastUnitPrice,
    String priceSource = '',
    String? priceUpdatedAt,
  }) async {
    final stamp = priceUpdatedAt ?? _nowIso();
    final updated = item.copyWith(
      lastUnitPrice: lastUnitPrice,
      priceSource: priceSource,
      priceUpdatedAt: stamp,
      updatedAt: _nowIso(),
    );
    await AppDb.instance
        .putInvestment(updated.copyWith(syncState: 'pending'), _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).updateInvestmentPrice(
            id: item.id,
            lastUnitPrice: lastUnitPrice,
            priceSource: priceSource,
            priceUpdatedAt: stamp,
          ));
      await AppDb.instance
          .putInvestment(updated.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      // Left pending: the queued write re-posts the whole holding and the API
      // upserts it, so the price lands either way.
      await _refreshPendingCount();
    }
  }

  Future<void> removeInvestment(Investment item) async {
    await AppDb.instance.deleteInvestment(item.id, _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).deleteInvestment(item.id));
    } on ApiUnavailableException {
      await AppDb.instance.putPendingDelete(
        PendingDelete(
          id: item.id,
          resource: 'investment',
          updatedAt: _nowIso(),
        ),
        _userId,
      );
      await _refreshPendingCount();
    }
  }

  /// Writes one holding through to the API, queuing it locally when the API is
  /// unreachable. `POST /investments` upserts on the client-generated id, so a
  /// retry can never duplicate a holding.
  Future<void> _saveInvestment(Investment item) async {
    try {
      await _withTokenRefresh(
          () => RemoteApi(_cfg).createInvestment(item.toApiPayload()));
      await AppDb.instance
          .putInvestment(item.copyWith(syncState: 'synced'), _userId);
    } on ApiUnavailableException {
      await AppDb.instance
          .putInvestment(item.copyWith(syncState: 'pending'), _userId);
      await _refreshPendingCount();
    }
  }

  // Routine transactions
  Future<RoutineTransaction> createRoutineTransaction({
    required String itemName,
    required double price,
    required String reminder,
    required Category category,
  }) async {
    final enteredAt = _nowGmtPlus7Iso();
    final item = RoutineTransaction(
      id: _uuid.v4(),
      itemName: itemName,
      price: price,
      reminder: reminder,
      categoryId: category.id,
      categoryName: category.name,
      createdDate: enteredAt,
      updatedAt: _nowIso(),
    );
    try {
      final m = await _withTokenRefresh(() => RemoteApi(_cfg).createRoutine(
            id: item.id,
            itemName: itemName,
            price: price,
            reminder: reminder,
            spendingCategoryId: category.id,
            spendingCategory: category.name,
            createdDate: enteredAt,
          ));
      final synced = RoutineTransaction.fromMap(m);
      await AppDb.instance.putRoutineTransaction(synced, _userId);
      return synced;
    } on ApiUnavailableException {
      final pending = item.copyWith(syncState: 'pending');
      await AppDb.instance.putRoutineTransaction(pending, _userId);
      await _refreshPendingCount();
      return pending;
    }
  }

  Future<bool> confirmRoutineBought({
    required RoutineTransaction routine,
    required double price,
    required Source source,
  }) async {
    final category = Category(
      id: routine.categoryId,
      name: routine.categoryName,
      kind: 'spending',
      syncState: 'synced',
      updatedAt: routine.updatedAt,
    );
    final savedLocally = await createSpending(
      amount: price,
      description: routine.itemName,
      category: category,
      source: source,
    );
    final payment = RoutinePayment(
      id: _uuid.v4(),
      routineId: routine.id,
      itemName: routine.itemName,
      price: price,
      categoryId: routine.categoryId,
      categoryName: routine.categoryName,
      sourceId: source.id,
      sourceName: source.name,
      boughtAt: _nowGmtPlus7Iso(),
      syncState: 'pending',
    );
    await AppDb.instance.putRoutinePayment(payment, _userId);
    await AppDb.instance.putRoutineTransaction(
      routine.copyWith(lastBoughtAt: payment.boughtAt, updatedAt: _nowIso()),
      _userId,
    );
    try {
      final m =
          await _withTokenRefresh(() => RemoteApi(_cfg).createRoutinePayment(
                routineId: routine.id,
                id: payment.id,
                price: price,
                sourceId: source.id,
                source: source.name,
                boughtAt: payment.boughtAt,
              ));
      await AppDb.instance
          .putRoutinePayment(RoutinePayment.fromMap(m), _userId);
    } on ApiUnavailableException {
      await _refreshPendingCount();
    }
    return savedLocally;
  }

  Future<void> removeRoutineTransaction(RoutineTransaction item) async {
    await AppDb.instance.deleteRoutineTransaction(item.id, _userId);
    try {
      await _withTokenRefresh(() => RemoteApi(_cfg).deleteRoutine(item.id));
    } on ApiUnavailableException {
      await _refreshPendingCount();
    }
  }

  /// Runs [call], and if the server rejects with a 401 (token expired/malformed)
  /// attempts a silent re-login using stored credentials before retrying once.
  Future<T> _withTokenRefresh<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiUnauthorizedException {
      if (!await ConfigService.instance.tryRefreshToken()) rethrow;
      return await call();
    }
  }

  Future<void> _queuePending(Transaction t) async {
    await AppDb.instance.putTransaction(t, _userId);
    await _refreshPendingCount();
  }

  (String, String?) _transactionDeleteIds(Transaction t) {
    if (t.type != 'transfer') return (t.id, null);
    final parts = t.id.split('_');
    if (parts.length >= 2) return (parts.first, parts.sublist(1).join('_'));
    return (t.id, null);
  }

  Future<void> _deleteRemoteTransactionById(
    RemoteApi remote,
    String id,
    String type,
    String? secondaryId,
  ) async {
    switch (type) {
      case 'earning':
        await remote.deleteEarning(id);
        break;
      case 'spending':
        await remote.deleteSpending(id);
        break;
      case 'transfer':
        await remote.deleteSpending(id);
        if (secondaryId != null && secondaryId.isNotEmpty) {
          await remote.deleteEarning(secondaryId);
        }
        break;
      default:
        throw const ApiException('Unsupported transaction type for delete.');
    }
  }

  Future<void> _refreshPendingCount() async {
    final pending = await AppDb.instance.getPendingWriteCount(_userId);
    SyncService.instance.updatePendingCount(pending);
  }

  String _dateKey(DateTime date) {
    final local = date.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  Future<List<ActivityTemplate>> getActivityTemplates() =>
      AppDb.instance.getActivityTemplates(_userId);

  Future<List<ActivityCategory>> getActivityCategories() async {
    if (_cfg.isLoggedIn && SyncService.instance.isOnline) {
      try {
        final raw = await _withTokenRefresh(
            () => RemoteApi(_cfg).getActivityCategories());
        final categories = raw
            .map(ActivityCategory.fromMap)
            .where((category) => category.name.trim().isNotEmpty)
            .toList();
        for (final category in categories) {
          await AppDb.instance.putActivityCategory(category, _userId);
        }
        final merged = [
          ...categories,
          ...await AppDb.instance.getPendingActivityCategories(_userId),
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return merged;
      } on ApiUnavailableException {
        // Fall back to local cache below.
      } on ApiUnauthorizedException {
        // Fall back to local cache below.
      }
    }
    return AppDb.instance.getActivityCategories(_userId);
  }

  Future<ActivityCategory?> createActivityCategory(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;

    Future<ActivityCategory> savePending() async {
      final category = ActivityCategory(
        id: trimmed,
        name: trimmed,
        syncState: 'pending',
        updatedAt: _nowIso(),
      );
      await AppDb.instance.putActivityCategory(
        category,
        _userId,
        syncState: 'pending',
      );
      await _refreshPendingCount();
      return category;
    }

    if (!_cfg.isLoggedIn || !SyncService.instance.isOnline) {
      return savePending();
    }

    try {
      final m = await _withTokenRefresh(
          () => RemoteApi(_cfg).createActivityCategory(trimmed));
      final category = ActivityCategory.fromMap(m).copyWith(
        name: (m['activity_category'] ?? trimmed).toString(),
        syncState: 'synced',
        updatedAt: _nowIso(),
      );
      await AppDb.instance.putActivityCategory(category, _userId);
      return category;
    } on ApiUnavailableException {
      return savePending();
    }
  }

  Future<void> deleteActivityCategory(ActivityCategory category) async {
    if (category.syncState != 'pending' &&
        category.id.trim().isNotEmpty &&
        _cfg.isLoggedIn &&
        SyncService.instance.isOnline) {
      await _withTokenRefresh(
          () => RemoteApi(_cfg).deleteActivityCategory(category.id));
    }
    await AppDb.instance.deleteActivityCategory(category.name, _userId);
  }

  Future<List<DailyActivity>> getDailyActivities(DateTime date) =>
      AppDb.instance.getDailyActivities(_userId, _dateKey(date));

  Future<List<DailyActivity>> getDailyActivitiesBetween(
          DateTime start, DateTime end) =>
      AppDb.instance.getDailyActivitiesBetween(
        _userId,
        _dateKey(start),
        _dateKey(end),
      );

  Future<ActivityTemplate> createActivityTemplate({
    required String title,
    String notes = '',
    String category = '',
  }) async {
    final now = _nowIso();
    final existing = await AppDb.instance.getActivityTemplates(_userId);
    final template = ActivityTemplate(
      id: _uuid.v4(),
      title: title,
      notes: notes,
      category: category,
      sortOrder: existing.length,
      createdAt: now,
      updatedAt: now,
    );
    await AppDb.instance.putActivityTemplate(template, _userId);
    return template;
  }

  Future<void> deleteActivityTemplate(ActivityTemplate template) async {
    await AppDb.instance.deleteActivityTemplate(template.id, _userId);
  }

  Future<DailyActivity?> markActivityDoneToday(
      ActivityTemplate template) async {
    final activityDate = _dateKey(DateTime.now());
    final existing =
        await AppDb.instance.getDailyActivities(_userId, activityDate);
    if (existing.any((item) => item.templateId == template.id)) return null;
    final now = _nowIso();
    final activity = DailyActivity(
      id: _uuid.v4(),
      templateId: template.id,
      title: template.title,
      notes: template.notes,
      category: template.category,
      activityDate: activityDate,
      doneAt: now,
    );
    await AppDb.instance.putDailyActivity(activity, _userId);
    return activity;
  }

  Future<void> removeDailyActivity(DailyActivity activity) async {
    await AppDb.instance.deleteDailyActivity(activity.id, _userId);
  }

  Future<void> syncPendingOptions() async {
    final cfg = _cfg;

    for (final source in await AppDb.instance.getPendingSources(cfg.userId)) {
      try {
        final m = await _withTokenRefresh(
            () => RemoteApi(_cfg).createSource(source.name));
        final synced = Source(
          id: m['source_id'] as String,
          name: m['source'] as String,
          kind: source.kind,
          syncState: 'synced',
          updatedAt: _nowIso(),
        );
        await AppDb.instance.deleteSource(source.id, cfg.userId);
        await AppDb.instance.putSource(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } on ApiException catch (e) {
        if (!await _resolveDuplicatePendingSource(source, e, cfg.userId)) {
          // Keep the pending row for a later retry.
        }
      }
    }

    for (final category
        in await AppDb.instance.getPendingCategories(cfg.userId)) {
      try {
        final m = await _createRemoteCategory(category);
        final synced = Category(
          id: (m['earning_category_id'] ??
              m['spending_category_id'] ??
              m['planned_expense_category_id']) as String,
          name: (m['earning_category'] ??
              m['spending_category'] ??
              m['planned_expense_category']) as String,
          kind: category.kind,
          syncState: 'synced',
          updatedAt: _nowIso(),
        );
        await AppDb.instance.deleteCategory(category.id, cfg.userId);
        await AppDb.instance.putCategory(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } on ApiException catch (e) {
        if (!await _resolveDuplicatePendingCategory(category, e, cfg.userId)) {
          // Keep the pending row for a later retry.
        }
      }
    }

    for (final category
        in await AppDb.instance.getPendingActivityCategories(cfg.userId)) {
      try {
        final m = await _withTokenRefresh(
            () => RemoteApi(_cfg).createActivityCategory(category.name));
        final synced = ActivityCategory.fromMap(m).copyWith(
          name: (m['activity_category'] ?? category.name).toString(),
          syncState: 'synced',
          updatedAt: _nowIso(),
        );
        await AppDb.instance.deleteActivityCategory(category.name, cfg.userId);
        await AppDb.instance.putActivityCategory(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } on ApiException catch (e) {
        if (!await _resolveDuplicatePendingActivityCategory(
            category, e, cfg.userId)) {
          // Keep the pending row for a later retry.
        }
      }
    }

    SyncService.instance.updatePendingCount(
        await AppDb.instance.getPendingWriteCount(cfg.userId));
  }

  Future<Map<String, dynamic>> _createRemoteCategory(Category category) {
    return _withTokenRefresh(() {
      final remote = RemoteApi(_cfg);
      if (category.kind == 'earning') {
        return remote.createEarningCategory(category.name);
      }
      if (category.kind == 'planned_expense') {
        return remote.createPlannedExpenseCategory(category.name);
      }
      return remote.createSpendingCategory(category.name);
    });
  }

  bool _isDuplicateWrite(ApiException e) {
    final message = e.toString().toLowerCase();
    return message.contains('already exists') || message.contains('duplicate');
  }

  bool _sameName(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  Future<bool> _resolveDuplicatePendingSource(
      Source source, ApiException error, String userId) async {
    if (!_isDuplicateWrite(error)) return false;
    try {
      final rows = await _withTokenRefresh(() => RemoteApi(_cfg).getSources());
      for (final row in rows) {
        final name = (row['source'] ?? '').toString();
        if (!_sameName(name, source.name)) continue;
        final synced = Source(
          id: row['source_id'] as String,
          name: name,
          kind: source.kind,
          syncState: 'synced',
          updatedAt: (row['created_date'] ?? _nowIso()).toString(),
        );
        await AppDb.instance.deleteSource(source.id, userId);
        await AppDb.instance.putSource(synced, userId);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<bool> _resolveDuplicatePendingCategory(
      Category category, ApiException error, String userId) async {
    if (!_isDuplicateWrite(error)) return false;
    try {
      final rows = await _withTokenRefresh(() {
        final remote = RemoteApi(_cfg);
        if (category.kind == 'earning') return remote.getEarningCategories();
        if (category.kind == 'planned_expense') {
          return remote.getPlannedExpenseCategories();
        }
        return remote.getSpendingCategories();
      });
      for (final row in rows) {
        final id = (row['earning_category_id'] ??
            row['spending_category_id'] ??
            row['planned_expense_category_id']) as String?;
        final name = (row['earning_category'] ??
                row['spending_category'] ??
                row['planned_expense_category'] ??
                '')
            .toString();
        if (id == null || !_sameName(name, category.name)) continue;
        final synced = Category(
          id: id,
          name: name,
          kind: category.kind,
          syncState: 'synced',
          updatedAt: (row['created_date'] ?? _nowIso()).toString(),
        );
        await AppDb.instance.deleteCategory(category.id, userId);
        await AppDb.instance.putCategory(synced, userId);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<bool> _resolveDuplicatePendingActivityCategory(
      ActivityCategory category, ApiException error, String userId) async {
    if (!_isDuplicateWrite(error)) return false;
    try {
      final rows = await _withTokenRefresh(
          () => RemoteApi(_cfg).getActivityCategories());
      for (final row in rows) {
        final synced = ActivityCategory.fromMap(row);
        if (!_sameName(synced.name, category.name)) continue;
        await AppDb.instance.deleteActivityCategory(category.name, userId);
        await AppDb.instance.putActivityCategory(synced, userId);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Retries transactions queued while in "local mode". Stops at the first
  /// [ApiUnavailableException] (the API is still unreachable) and leaves the
  /// rest queued for the next sync; other errors (e.g. a category/source
  /// that no longer exists) are skipped so one bad entry can't block the
  /// rest. Successfully-sent entries are removed from the local queue - the
  /// follow-up `onRefresh` (triggered by [SyncService]) re-fetches them from
  /// the server with their real ids.
  Future<void> syncPendingTransactions() async {
    final cfg = _cfg;
    final pending = await AppDb.instance.getPendingTransactions(cfg.userId);
    if (pending.isEmpty) {
      SyncService.instance.updatePendingCount(
          await AppDb.instance.getPendingWriteCount(cfg.userId));
      return;
    }

    final remote = RemoteApi(cfg);
    final sources = await AppDb.instance.getSources(cfg.userId);
    final categories = await AppDb.instance.getCategories(cfg.userId);

    // Every push carries `t.date` - the moment the transaction was entered on
    // the device - so the server stores that instead of stamping the row with
    // the time sync happened to run.
    for (final t in pending) {
      try {
        switch (t.type) {
          case 'earning':
            final cat = categories
                .firstWhere((c) => c.kind == 'earning' && c.name == t.category);
            final src = sources.firstWhere((s) => s.name == t.source);
            await remote.createEarning(
              totalAmount: t.amount,
              description: t.description,
              earningCategoryId: cat.id,
              earningCategory: cat.name,
              sourceId: src.id,
              source: src.name,
              createdDate: t.date,
            );
            break;
          case 'spending':
            final cat = categories.firstWhere(
                (c) => c.kind == 'spending' && c.name == t.category);
            final src = sources.firstWhere((s) => s.name == t.source);
            // Ship the queued line items along with their parent spending so
            // the server rebuilds the same breakdown under its own ids.
            final queuedDetails =
                await AppDb.instance.getTransactionDetailsFor(t.id, cfg.userId);
            await remote.createSpending(
              totalAmount: t.amount,
              description: t.description,
              spendingCategoryId: cat.id,
              spendingCategory: cat.name,
              sourceId: src.id,
              source: src.name,
              details: queuedDetails.map((d) => d.toApiPayload()).toList(),
              createdDate: t.date,
            );
            break;
          case 'transfer':
            final from = sources.firstWhere((s) => s.name == t.fromSource);
            final to = sources.firstWhere((s) => s.name == t.toSource);
            final settings = await remote.getSettings();
            String catId = '';
            String catName = 'Transfer';
            for (final s in settings) {
              if (s['app_setting_key'] == 'TRANSFER_CATEGORY_ID') {
                catId = s['app_setting_value'] as String? ?? '';
              }
              if (s['app_setting_key'] == 'TRANSFER_CATEGORY_NAME') {
                catName = s['app_setting_value'] as String? ?? catName;
              }
            }
            if (catId.isEmpty) {
              throw const ApiException(
                  'Transfer category is not configured on the server.');
            }
            await remote.createSpending(
              totalAmount: t.amount,
              description: t.description,
              spendingCategoryId: catId,
              spendingCategory: catName,
              sourceId: from.id,
              source: from.name,
              createdDate: t.date,
            );
            await remote.createEarning(
              totalAmount: t.amount,
              description: t.description,
              earningCategoryId: catId,
              earningCategory: catName,
              sourceId: to.id,
              source: to.name,
              createdDate: t.date,
            );
            break;
        }
        await AppDb.instance.deleteTransaction(t.id, cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Leave this entry queued and move on to the next.
      }
    }

    SyncService.instance.updatePendingCount(
        await AppDb.instance.getPendingWriteCount(cfg.userId));
  }

  // ── Insulin ──────────────────────────────────────────────────────────
  Future<void> syncPendingDeletes() async {
    final cfg = _cfg;
    final pending = await AppDb.instance.getPendingDeletes(cfg.userId);
    if (pending.isEmpty) {
      SyncService.instance.updatePendingCount(
          await AppDb.instance.getPendingWriteCount(cfg.userId));
      return;
    }

    final remote = RemoteApi(cfg);
    for (final item in pending) {
      try {
        switch (item.resource) {
          case 'transaction':
            await _deleteRemoteTransactionById(
              remote,
              item.id,
              item.resourceType ?? '',
              item.secondaryId,
            );
            break;
          case 'insulin_usage':
            await remote.deleteInsulinUsage(item.id);
            break;
          case 'consumable':
            await remote.deleteConsumable(item.id);
            break;
          case 'investment':
            await remote.deleteInvestment(item.id);
            break;
          default:
            await AppDb.instance.deletePendingDelete(item, cfg.userId);
            continue;
        }
        await AppDb.instance.deletePendingDelete(item, cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        await AppDb.instance.deletePendingDelete(item, cfg.userId);
      }
    }

    SyncService.instance.updatePendingCount(
        await AppDb.instance.getPendingWriteCount(cfg.userId));
  }

  Future<void> syncPendingPlanningWrites() async {
    final cfg = _cfg;
    final remote = RemoteApi(cfg);

    for (final item
        in await AppDb.instance.getPendingWishlistItems(cfg.userId)) {
      try {
        await remote.createWishlist(
          id: item.id,
          itemName: item.itemName,
          price: item.price,
          transactionType: item.transactionType,
          categoryId: item.categoryId,
          categoryName: item.categoryName,
          notes: item.notes,
          priority: item.priority,
          // Queued rows carry the moment they were entered / flipped on the
          // device, so a late push does not restamp them with the sync time.
          createdDate: item.createdDate,
        );
        if (item.status != 'active') {
          await remote.updateWishlistStatus(
            id: item.id,
            status: item.status,
            fulfilledPrice: item.fulfilledPrice,
            changedAt:
                item.status == 'fulfilled' ? item.fulfilledAt : item.canceledAt,
          );
        }
        await AppDb.instance
            .putWishlistItem(item.copyWith(syncState: 'synced'), cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    for (final item
        in await AppDb.instance.getPendingRoutineTransactions(cfg.userId)) {
      try {
        await remote.createRoutine(
          id: item.id,
          itemName: item.itemName,
          price: item.price,
          reminder: item.reminder,
          spendingCategoryId: item.categoryId,
          spendingCategory: item.categoryName,
          createdDate: item.createdDate,
        );
        await AppDb.instance.putRoutineTransaction(
            item.copyWith(syncState: 'synced'), cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    for (final payment
        in await AppDb.instance.getPendingRoutinePayments(cfg.userId)) {
      try {
        await remote.createRoutinePayment(
          routineId: payment.routineId,
          id: payment.id,
          price: payment.price,
          sourceId: payment.sourceId,
          source: payment.sourceName,
          boughtAt: payment.boughtAt,
        );
        await AppDb.instance.putRoutinePayment(
            payment.copyWith(syncState: 'synced'), cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    // Consumables are upserted on their client-generated id, so one call
    // covers both a unit created offline and one whose out date changed there.
    for (final unit in await AppDb.instance.getPendingConsumables(cfg.userId)) {
      try {
        await remote.createConsumable(unit.toApiPayload());
        await AppDb.instance
            .putConsumable(unit.copyWith(syncState: 'synced'), cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    // Investments upsert on their client-generated id too, so one call covers
    // a holding created offline and one whose price was refreshed there.
    for (final item in await AppDb.instance.getPendingInvestments(cfg.userId)) {
      try {
        await remote.createInvestment(item.toApiPayload());
        await AppDb.instance
            .putInvestment(item.copyWith(syncState: 'synced'), cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    SyncService.instance.updatePendingCount(
        await AppDb.instance.getPendingWriteCount(cfg.userId));
  }

  Future<InsulinItem> createInsulinItem({
    required String name,
    required double units,
    required String uom,
    String? notes,
  }) async {
    final enteredAt = _nowGmtPlus7Iso();
    try {
      final m = await _withTokenRefresh(() => RemoteApi(_cfg).createInsulinItem(
          name: name,
          units: units,
          uom: uom,
          notes: notes,
          createdAt: enteredAt));
      final item = InsulinItem.fromMap(m);
      await AppDb.instance.putInsulinItem(item, _userId);
      return item;
    } on ApiUnavailableException {
      final item = InsulinItem(
        id: _uuid.v4(),
        name: name,
        units: units,
        uom: uom,
        date: enteredAt,
        notes: notes,
        syncState: 'pending',
      );
      await AppDb.instance.putInsulinItem(item, _userId);
      await _refreshPendingCount();
      return item;
    }
  }

  Future<InsulinAssign> createInsulinAssign({
    required String itemId,
    required String batchNo,
    String? notes,
  }) async {
    final enteredAt = _nowGmtPlus7Iso();
    try {
      final m = await _withTokenRefresh(() => RemoteApi(_cfg)
          .createInsulinAssign(
              insulinItemId: itemId,
              batchNo: batchNo,
              notes: notes,
              addedAt: enteredAt));
      final assign = InsulinAssign.fromMap(m);
      await AppDb.instance.putInsulinAssign(assign, _userId);
      return assign;
    } on ApiUnavailableException {
      final item = await _cachedInsulinItem(itemId);
      final assign = InsulinAssign(
        id: _uuid.v4(),
        itemId: itemId,
        batchNo: batchNo,
        date: enteredAt,
        itemName: item?.name ?? '',
        totalUnits: item?.units ?? 0,
        notes: notes,
        syncState: 'pending',
      );
      await AppDb.instance.putInsulinAssign(assign, _userId);
      await _refreshPendingCount();
      return assign;
    }
  }

  Future<void> deleteInsulinAssign(String id) =>
      _withTokenRefresh(() => RemoteApi(_cfg).deleteInsulinAssign(id));

  Future<InsulinUsage> logInsulinUsage({
    required String assignId,
    required double units,
    String? notes,
  }) async {
    final enteredAt = _nowGmtPlus7Iso();
    try {
      final m = await _withTokenRefresh(() => RemoteApi(_cfg)
          .createInsulinUsage(
              insulinAssignId: assignId,
              units: units,
              notes: notes,
              administeredAt: enteredAt));
      final usage = InsulinUsage.fromMap(m);
      await AppDb.instance.putInsulinUsage(usage, _userId);
      return usage;
    } on ApiUnavailableException {
      final usage = InsulinUsage(
        id: _uuid.v4(),
        assignId: assignId,
        units: units,
        date: enteredAt,
        notes: notes,
        syncState: 'pending',
      );
      await AppDb.instance.putInsulinUsage(usage, _userId);
      await _refreshPendingCount();
      return usage;
    }
  }

  Future<void> deleteInsulinUsage(InsulinUsage usage) async {
    await AppDb.instance.deleteInsulinUsage(usage.id, _userId);

    if (usage.syncState == 'pending' || !_cfg.isLoggedIn) {
      await _refreshPendingCount();
      return;
    }

    Future<void> queueDelete() async {
      await AppDb.instance.putPendingDelete(
        PendingDelete(
          id: usage.id,
          resource: 'insulin_usage',
          updatedAt: _nowIso(),
        ),
        _userId,
      );
      await _refreshPendingCount();
    }

    if (!SyncService.instance.isOnline) {
      await queueDelete();
      return;
    }

    try {
      await _withTokenRefresh(
          () => RemoteApi(_cfg).deleteInsulinUsage(usage.id));
    } on ApiUnavailableException {
      await queueDelete();
    } catch (_) {
      await AppDb.instance.putInsulinUsage(usage, _userId);
      rethrow;
    }
  }

  Future<BloodSugarLog> logBloodSugar({
    required double level,
    String unit = 'mg/dL',
    String? mealContext,
    String? notes,
  }) async {
    final measuredAt = _nowGmtPlus7Iso();
    try {
      final m =
          await _withTokenRefresh(() => RemoteApi(_cfg).createBloodSugarLog(
                level: level,
                unit: unit,
                mealContext: mealContext,
                notes: notes,
                measuredAt: measuredAt,
              ));
      final log = BloodSugarLog.fromMap(m);
      await AppDb.instance.putBloodSugarLog(log, _userId);
      return log;
    } on ApiUnavailableException {
      final log = BloodSugarLog(
        id: _uuid.v4(),
        level: level,
        unit: unit,
        measuredAt: measuredAt,
        mealContext: mealContext,
        notes: notes,
        syncState: 'pending',
      );
      await AppDb.instance.putBloodSugarLog(log, _userId);
      await _refreshPendingCount();
      return log;
    }
  }

  Future<void> syncPendingHealthWrites() async {
    final cfg = _cfg;
    final remote = RemoteApi(cfg);
    final itemIdMap = <String, String>{};
    final assignIdMap = <String, String>{};

    for (final item
        in await AppDb.instance.getPendingInsulinItems(cfg.userId)) {
      try {
        // Every push carries the stamp the record was queued with, so a health
        // record entered offline is not restamped with the time sync ran.
        final m = await remote.createInsulinItem(
          name: item.name,
          units: item.units,
          uom: item.uom,
          notes: item.notes,
          createdAt: item.date,
        );
        final synced = InsulinItem.fromMap(m);
        itemIdMap[item.id] = synced.id;
        await AppDb.instance.deleteInsulinItem(item.id, cfg.userId);
        await AppDb.instance.putInsulinItem(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    final unresolvedItems = {
      for (final item
          in await AppDb.instance.getPendingInsulinItems(cfg.userId))
        item.id
    };
    for (final assign
        in await AppDb.instance.getPendingInsulinAssigns(cfg.userId)) {
      final itemId = itemIdMap[assign.itemId] ?? assign.itemId;
      if (unresolvedItems.contains(itemId)) continue;
      try {
        final m = await remote.createInsulinAssign(
          insulinItemId: itemId,
          batchNo: assign.batchNo,
          notes: assign.notes,
          addedAt: assign.date,
        );
        final synced = InsulinAssign.fromMap(m);
        assignIdMap[assign.id] = synced.id;
        await AppDb.instance.deleteInsulinAssign(assign.id, cfg.userId);
        await AppDb.instance.putInsulinAssign(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    final unresolvedAssigns = {
      for (final assign
          in await AppDb.instance.getPendingInsulinAssigns(cfg.userId))
        assign.id
    };
    for (final usage
        in await AppDb.instance.getPendingInsulinUsages(cfg.userId)) {
      final assignId = assignIdMap[usage.assignId] ?? usage.assignId;
      if (unresolvedAssigns.contains(assignId)) continue;
      try {
        final m = await remote.createInsulinUsage(
          insulinAssignId: assignId,
          units: usage.units,
          notes: usage.notes,
          administeredAt: usage.date,
        );
        final synced = InsulinUsage.fromMap(m);
        await AppDb.instance.deleteInsulinUsage(usage.id, cfg.userId);
        await AppDb.instance.putInsulinUsage(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    for (final log
        in await AppDb.instance.getPendingBloodSugarLogs(cfg.userId)) {
      try {
        final m = await remote.createBloodSugarLog(
          level: log.level,
          unit: log.unit,
          mealContext: log.mealContext,
          notes: log.notes,
          measuredAt: log.measuredAt,
        );
        final synced = BloodSugarLog.fromMap(m);
        await AppDb.instance.deleteBloodSugarLog(log.id, cfg.userId);
        await AppDb.instance.putBloodSugarLog(synced, cfg.userId);
      } on ApiUnavailableException {
        break;
      } catch (_) {
        // Keep the pending row for a later retry.
      }
    }

    SyncService.instance.updatePendingCount(
        await AppDb.instance.getPendingWriteCount(cfg.userId));
  }

  Future<InsulinItem?> _cachedInsulinItem(String id) async {
    final items = await AppDb.instance.getInsulinItems(_userId);
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
