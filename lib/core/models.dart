import 'dart:convert';

class Source {
  final String id;
  final String name;
  final String kind;
  final String syncState;
  final String updatedAt;

  const Source({
    required this.id,
    required this.name,
    required this.kind,
    this.syncState = 'pending',
    required this.updatedAt,
  });

  factory Source.fromMap(Map<String, dynamic> m) => Source(
        id: m['id'] as String,
        name: m['name'] as String,
        kind: m['kind'] as String,
        syncState: m['syncState'] as String? ?? 'pending',
        updatedAt: m['updatedAt'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'kind': kind,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  Source copyWith(
          {String? id,
          String? name,
          String? kind,
          String? syncState,
          String? updatedAt}) =>
      Source(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class Category {
  final String id;
  final String name;
  final String kind;
  final String syncState;
  final String updatedAt;

  const Category({
    required this.id,
    required this.name,
    required this.kind,
    this.syncState = 'pending',
    required this.updatedAt,
  });

  factory Category.fromMap(Map<String, dynamic> m) => Category(
        id: m['id'] as String,
        name: m['name'] as String,
        kind: m['kind'] as String,
        syncState: m['syncState'] as String? ?? 'pending',
        updatedAt: m['updatedAt'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'kind': kind,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  Category copyWith(
          {String? id,
          String? name,
          String? kind,
          String? syncState,
          String? updatedAt}) =>
      Category(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class ActivityCategory {
  final String id;
  final String name;
  final String syncState;
  final String updatedAt;

  const ActivityCategory({
    required this.id,
    required this.name,
    this.syncState = 'pending',
    required this.updatedAt,
  });

  factory ActivityCategory.fromMap(Map<String, dynamic> m) {
    final name = (m['activity_category'] ?? m['name'] ?? '').toString();
    return ActivityCategory(
      id: (m['activity_category_id'] ?? m['id'] ?? name).toString(),
      name: name,
      syncState: m['syncState'] as String? ?? 'synced',
      updatedAt: (m['created_date'] ?? m['updatedAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  ActivityCategory copyWith({
    String? id,
    String? name,
    String? syncState,
    String? updatedAt,
  }) =>
      ActivityCategory(
        id: id ?? this.id,
        name: name ?? this.name,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class Transaction {
  final String id;
  final String type;
  final double amount;
  final String description;
  final String? category;
  final String? source;
  final String? fromSource;
  final String? toSource;
  final String date;
  final String syncState;
  final String updatedAt;

  const Transaction({
    required this.id,
    required this.type,
    required this.amount,
    this.description = '',
    this.category,
    this.source,
    this.fromSource,
    this.toSource,
    required this.date,
    this.syncState = 'pending',
    required this.updatedAt,
  });

  factory Transaction.fromMap(Map<String, dynamic> m) => Transaction(
        id: m['id'] as String,
        type: m['type'] as String,
        amount: (m['amount'] as num).toDouble(),
        description: m['description'] as String? ?? '',
        category: m['category'] as String?,
        source: m['source'] as String?,
        fromSource: m['fromSource'] as String?,
        toSource: m['toSource'] as String?,
        date: m['date'] as String,
        syncState: m['syncState'] as String? ?? 'pending',
        updatedAt: m['updatedAt'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type,
        'amount': amount,
        'description': description,
        'category': category,
        'source': source,
        'fromSource': fromSource,
        'toSource': toSource,
        'date': date,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  Transaction copyWith({
    String? id,
    String? type,
    double? amount,
    String? description,
    String? category,
    String? source,
    String? fromSource,
    String? toSource,
    String? date,
    String? syncState,
    String? updatedAt,
  }) =>
      Transaction(
        id: id ?? this.id,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        description: description ?? this.description,
        category: category ?? this.category,
        source: source ?? this.source,
        fromSource: fromSource ?? this.fromSource,
        toSource: toSource ?? this.toSource,
        date: date ?? this.date,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class AppConfig {
  final String apiBase;
  final String healthBase;
  final String loginBase;
  final bool autoSync;
  final int syncIntervalSec;
  final String theme;
  final String density;
  final String currency;
  final String username;
  final String email;
  final String phoneNumber;
  final String telegramUsername;
  final String authToken;
  final String tokenExpiresAt;
  final String userId;

  const AppConfig({
    this.apiBase = 'http://127.0.0.1:8080',
    this.healthBase = 'http://127.0.0.1:8082',
    this.loginBase = 'http://127.0.0.1:3002',
    this.autoSync = true,
    this.syncIntervalSec = 30,
    this.theme = 'ink',
    this.density = 'regular',
    this.currency = 'full',
    this.username = '',
    this.email = '',
    this.phoneNumber = '',
    this.telegramUsername = '',
    this.authToken = '',
    this.tokenExpiresAt = '',
    this.userId = '',
  });

  /// Whether [tokenExpiresAt] is set and in the past.
  bool get isTokenExpired {
    if (tokenExpiresAt.isEmpty) return false;
    final exp = DateTime.tryParse(tokenExpiresAt);
    if (exp == null) return false;
    return DateTime.now().isAfter(exp);
  }

  /// The app is "logged in" once login-api has issued a JWT. Expiry is left
  /// to the API so the mobile app does not proactively discard saved sessions.
  bool get isLoggedIn => authToken.trim().isNotEmpty;

  /// Kept as an alias of [isLoggedIn] for call sites that historically
  /// checked whether the app was "configured".
  bool get isConfigured => isLoggedIn;

  factory AppConfig.fromJson(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return AppConfig(
      apiBase: m['apiBase'] as String? ?? 'http://127.0.0.1:8080',
      healthBase: m['healthBase'] as String? ?? 'http://127.0.0.1:8082',
      loginBase: m['loginBase'] as String? ?? 'http://127.0.0.1:3002',
      autoSync: m['autoSync'] as bool? ?? true,
      syncIntervalSec: m['syncIntervalSec'] as int? ?? 30,
      theme: m['theme'] as String? ?? 'ink',
      density: m['density'] as String? ?? 'regular',
      currency: m['currency'] as String? ?? 'full',
      username: m['username'] as String? ?? '',
      email: m['email'] as String? ?? '',
      phoneNumber: m['phoneNumber'] as String? ?? '',
      telegramUsername: m['telegramUsername'] as String? ?? '',
      authToken: m['authToken'] as String? ?? '',
      tokenExpiresAt: m['tokenExpiresAt'] as String? ?? '',
      userId: m['userId'] as String? ?? '',
    );
  }

  String toJson() => jsonEncode({
        'apiBase': apiBase,
        'healthBase': healthBase,
        'loginBase': loginBase,
        'autoSync': autoSync,
        'syncIntervalSec': syncIntervalSec,
        'theme': theme,
        'density': density,
        'currency': currency,
        'username': username,
        'email': email,
        'phoneNumber': phoneNumber,
        'telegramUsername': telegramUsername,
        'authToken': authToken,
        'tokenExpiresAt': tokenExpiresAt,
        'userId': userId,
      });

  AppConfig copyWith({
    String? apiBase,
    String? healthBase,
    String? loginBase,
    bool? autoSync,
    int? syncIntervalSec,
    String? theme,
    String? density,
    String? currency,
    String? username,
    String? email,
    String? phoneNumber,
    String? telegramUsername,
    String? authToken,
    String? tokenExpiresAt,
    String? userId,
  }) =>
      AppConfig(
        apiBase: apiBase ?? this.apiBase,
        healthBase: healthBase ?? this.healthBase,
        loginBase: loginBase ?? this.loginBase,
        autoSync: autoSync ?? this.autoSync,
        syncIntervalSec: syncIntervalSec ?? this.syncIntervalSec,
        theme: theme ?? this.theme,
        density: density ?? this.density,
        currency: currency ?? this.currency,
        username: username ?? this.username,
        email: email ?? this.email,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        telegramUsername: telegramUsername ?? this.telegramUsername,
        authToken: authToken ?? this.authToken,
        tokenExpiresAt: tokenExpiresAt ?? this.tokenExpiresAt,
        userId: userId ?? this.userId,
      );
}

class AppData {
  final List<Source> sources;
  final List<Category> categories;
  final List<Transaction> transactions;
  final List<WishlistItem> wishlistItems;
  final List<RoutineTransaction> routineTransactions;
  final List<RoutinePayment> routinePayments;
  final List<InsulinItem> insulinItems;
  final List<InsulinAssign> insulinAssigns;
  final List<InsulinUsage> insulinUsages;
  final List<BloodSugarLog> bloodSugarLogs;

  const AppData({
    required this.sources,
    required this.categories,
    required this.transactions,
    this.wishlistItems = const [],
    this.routineTransactions = const [],
    this.routinePayments = const [],
    this.insulinItems = const [],
    this.insulinAssigns = const [],
    this.insulinUsages = const [],
    this.bloodSugarLogs = const [],
  });
}

class PendingDelete {
  final String id;
  final String resource;
  final String? resourceType;
  final String? secondaryId;
  final String updatedAt;

  const PendingDelete({
    required this.id,
    required this.resource,
    this.resourceType,
    this.secondaryId,
    required this.updatedAt,
  });

  factory PendingDelete.fromMap(Map<String, dynamic> m) => PendingDelete(
        id: m['id'] as String,
        resource: m['resource'] as String,
        resourceType: m['resourceType'] as String?,
        secondaryId: m['secondaryId'] as String?,
        updatedAt: m['updatedAt'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'resource': resource,
        'resourceType': resourceType,
        'secondaryId': secondaryId,
        'updatedAt': updatedAt,
      };
}

class ActivityTemplate {
  final String id;
  final String title;
  final String notes;
  final String category;
  final int sortOrder;
  final String createdAt;
  final String updatedAt;

  const ActivityTemplate({
    required this.id,
    required this.title,
    this.notes = '',
    this.category = '',
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ActivityTemplate.fromMap(Map<String, dynamic> m) => ActivityTemplate(
        id: m['id'] as String,
        title: m['title'] as String,
        notes: m['notes'] as String? ?? '',
        category: m['category'] as String? ?? '',
        sortOrder: (m['sortOrder'] as num?)?.toInt() ?? 0,
        createdAt: m['createdAt'] as String,
        updatedAt: m['updatedAt'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'notes': notes,
        'category': category,
        'sortOrder': sortOrder,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class DailyActivity {
  final String id;
  final String templateId;
  final String title;
  final String notes;
  final String category;
  final String activityDate;
  final String doneAt;

  const DailyActivity({
    required this.id,
    required this.templateId,
    required this.title,
    this.notes = '',
    this.category = '',
    required this.activityDate,
    required this.doneAt,
  });

  factory DailyActivity.fromMap(Map<String, dynamic> m) => DailyActivity(
        id: m['id'] as String,
        templateId: m['templateId'] as String? ?? '',
        title: m['title'] as String,
        notes: m['notes'] as String? ?? '',
        category: m['category'] as String? ?? '',
        activityDate: m['activityDate'] as String,
        doneAt: m['doneAt'] as String,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'templateId': templateId,
        'title': title,
        'notes': notes,
        'category': category,
        'activityDate': activityDate,
        'doneAt': doneAt,
      };
}

class WishlistItem {
  final String id;
  final String itemName;
  final double price;
  final String transactionType;
  final String? categoryId;
  final String? categoryName;
  final String? notes;
  final String priority;
  final String status;
  final double? fulfilledPrice;
  final String? fulfilledAt;
  final String? canceledAt;
  final String createdDate;
  final String updatedAt;
  final String syncState;

  const WishlistItem({
    required this.id,
    required this.itemName,
    required this.price,
    this.transactionType = 'spending',
    this.categoryId,
    this.categoryName,
    this.notes,
    required this.priority,
    this.status = 'active',
    this.fulfilledPrice,
    this.fulfilledAt,
    this.canceledAt,
    required this.createdDate,
    required this.updatedAt,
    this.syncState = 'synced',
  });

  factory WishlistItem.fromMap(Map<String, dynamic> m) => WishlistItem(
        id: m['planned_expense_id'] as String? ??
            m['wishlist_id'] as String? ??
            m['id'] as String,
        itemName: m['item_name'] as String? ?? m['itemName'] as String,
        price: (m['price'] as num).toDouble(),
        transactionType: m['transaction_type'] as String? ??
            m['transactionType'] as String? ??
            'spending',
        categoryId: m['category_id'] as String? ?? m['categoryId'] as String?,
        categoryName: m['category'] as String? ??
            m['category_name'] as String? ??
            m['categoryName'] as String?,
        notes: m['notes'] as String?,
        priority: m['priority'] as String? ?? 'medium',
        status: m['status'] as String? ?? 'active',
        fulfilledPrice:
            ((m['fulfilled_price'] ?? m['fulfilledPrice']) as num?)?.toDouble(),
        fulfilledAt:
            m['fulfilled_at'] as String? ?? m['fulfilledAt'] as String?,
        canceledAt: m['canceled_at'] as String? ?? m['canceledAt'] as String?,
        createdDate: m['created_date'] as String? ?? m['createdDate'] as String,
        updatedAt: m['updated_date'] as String? ??
            m['updatedAt'] as String? ??
            m['created_date'] as String? ??
            m['createdDate'] as String,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemName': itemName,
        'price': price,
        'transactionType': transactionType,
        'categoryId': categoryId,
        'categoryName': categoryName,
        'notes': notes,
        'priority': priority,
        'status': status,
        'fulfilledPrice': fulfilledPrice,
        'fulfilledAt': fulfilledAt,
        'canceledAt': canceledAt,
        'createdDate': createdDate,
        'updatedAt': updatedAt,
        'syncState': syncState,
      };

  WishlistItem copyWith({
    String? id,
    String? itemName,
    double? price,
    String? transactionType,
    String? categoryId,
    String? categoryName,
    String? notes,
    String? priority,
    String? status,
    double? fulfilledPrice,
    String? fulfilledAt,
    String? canceledAt,
    String? createdDate,
    String? updatedAt,
    String? syncState,
  }) =>
      WishlistItem(
        id: id ?? this.id,
        itemName: itemName ?? this.itemName,
        price: price ?? this.price,
        transactionType: transactionType ?? this.transactionType,
        categoryId: categoryId ?? this.categoryId,
        categoryName: categoryName ?? this.categoryName,
        notes: notes ?? this.notes,
        priority: priority ?? this.priority,
        status: status ?? this.status,
        fulfilledPrice: fulfilledPrice ?? this.fulfilledPrice,
        fulfilledAt: fulfilledAt ?? this.fulfilledAt,
        canceledAt: canceledAt ?? this.canceledAt,
        createdDate: createdDate ?? this.createdDate,
        updatedAt: updatedAt ?? this.updatedAt,
        syncState: syncState ?? this.syncState,
      );
}

class RoutineTransaction {
  final String id;
  final String itemName;
  final double price;
  final String reminder;
  final String categoryId;
  final String categoryName;
  final String status;
  final String? lastBoughtAt;
  final String createdDate;
  final String updatedAt;
  final String syncState;

  const RoutineTransaction({
    required this.id,
    required this.itemName,
    required this.price,
    required this.reminder,
    required this.categoryId,
    required this.categoryName,
    this.status = 'active',
    this.lastBoughtAt,
    required this.createdDate,
    required this.updatedAt,
    this.syncState = 'synced',
  });

  factory RoutineTransaction.fromMap(Map<String, dynamic> m) =>
      RoutineTransaction(
        id: m['routine_id'] as String? ?? m['id'] as String,
        itemName: m['item_name'] as String? ?? m['itemName'] as String,
        price: (m['price'] as num).toDouble(),
        reminder: m['reminder'] as String? ?? 'monthly',
        categoryId:
            m['spending_category_id'] as String? ?? m['categoryId'] as String,
        categoryName:
            m['spending_category'] as String? ?? m['categoryName'] as String,
        status: m['status'] as String? ?? 'active',
        lastBoughtAt:
            m['last_bought_at'] as String? ?? m['lastBoughtAt'] as String?,
        createdDate: m['created_date'] as String? ?? m['createdDate'] as String,
        updatedAt: m['updated_date'] as String? ??
            m['updatedAt'] as String? ??
            m['created_date'] as String? ??
            m['createdDate'] as String,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemName': itemName,
        'price': price,
        'reminder': reminder,
        'categoryId': categoryId,
        'categoryName': categoryName,
        'status': status,
        'lastBoughtAt': lastBoughtAt,
        'createdDate': createdDate,
        'updatedAt': updatedAt,
        'syncState': syncState,
      };

  RoutineTransaction copyWith({
    String? id,
    String? itemName,
    double? price,
    String? reminder,
    String? categoryId,
    String? categoryName,
    String? status,
    String? lastBoughtAt,
    String? createdDate,
    String? updatedAt,
    String? syncState,
  }) =>
      RoutineTransaction(
        id: id ?? this.id,
        itemName: itemName ?? this.itemName,
        price: price ?? this.price,
        reminder: reminder ?? this.reminder,
        categoryId: categoryId ?? this.categoryId,
        categoryName: categoryName ?? this.categoryName,
        status: status ?? this.status,
        lastBoughtAt: lastBoughtAt ?? this.lastBoughtAt,
        createdDate: createdDate ?? this.createdDate,
        updatedAt: updatedAt ?? this.updatedAt,
        syncState: syncState ?? this.syncState,
      );
}

class RoutinePayment {
  final String id;
  final String routineId;
  final String itemName;
  final double price;
  final String categoryId;
  final String categoryName;
  final String sourceId;
  final String sourceName;
  final String boughtAt;
  final String syncState;

  const RoutinePayment({
    required this.id,
    required this.routineId,
    required this.itemName,
    required this.price,
    required this.categoryId,
    required this.categoryName,
    required this.sourceId,
    required this.sourceName,
    required this.boughtAt,
    this.syncState = 'synced',
  });

  factory RoutinePayment.fromMap(Map<String, dynamic> m) => RoutinePayment(
        id: m['routine_payment_id'] as String? ?? m['id'] as String,
        routineId: m['routine_id'] as String? ?? m['routineId'] as String,
        itemName: m['item_name'] as String? ?? m['itemName'] as String,
        price: (m['price'] as num).toDouble(),
        categoryId:
            m['spending_category_id'] as String? ?? m['categoryId'] as String,
        categoryName:
            m['spending_category'] as String? ?? m['categoryName'] as String,
        sourceId: m['source_id'] as String? ?? m['sourceId'] as String,
        sourceName: m['source'] as String? ?? m['sourceName'] as String,
        boughtAt: m['bought_at'] as String? ?? m['boughtAt'] as String,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'routineId': routineId,
        'itemName': itemName,
        'price': price,
        'categoryId': categoryId,
        'categoryName': categoryName,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'boughtAt': boughtAt,
        'syncState': syncState,
      };

  RoutinePayment copyWith({String? syncState}) => RoutinePayment(
        id: id,
        routineId: routineId,
        itemName: itemName,
        price: price,
        categoryId: categoryId,
        categoryName: categoryName,
        sourceId: sourceId,
        sourceName: sourceName,
        boughtAt: boughtAt,
        syncState: syncState ?? this.syncState,
      );
}

class InsulinItem {
  final String id;
  final String name;
  final double units;
  final String uom;
  final String date;
  final String? notes;
  final String syncState;

  const InsulinItem({
    required this.id,
    required this.name,
    required this.units,
    required this.uom,
    required this.date,
    this.notes,
    this.syncState = 'pending',
  });

  factory InsulinItem.fromMap(Map<String, dynamic> m) => InsulinItem(
        id: m['insulin_item_id'] ?? m['id'],
        name: m['insulin_item_name'] ?? m['name'],
        units: (m['units'] as num).toDouble(),
        uom: m['uom'],
        date: m['created_at'] ?? m['date'],
        notes: m['notes'] as String?,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'units': units,
        'uom': uom,
        'date': date,
        'notes': notes,
        'syncState': syncState,
      };
}

class InsulinAssign {
  final String id;
  final String itemId;
  final String batchNo;
  final String date;
  final String itemName;
  final double totalUnits;
  final String? lastUsedAt;
  final String? notes;
  final String syncState;

  const InsulinAssign({
    required this.id,
    required this.itemId,
    required this.batchNo,
    required this.date,
    this.itemName = '',
    this.totalUnits = 0,
    this.lastUsedAt,
    this.notes,
    this.syncState = 'pending',
  });

  factory InsulinAssign.fromMap(Map<String, dynamic> m) => InsulinAssign(
        id: m['insulin_assign_id'] ?? m['id'],
        itemId: m['insulin_item_id'] ?? m['itemId'],
        batchNo: m['batch_no'] ?? m['batchNo'],
        date: m['added_at'] ?? m['date'],
        itemName:
            m['insulin_item_name'] as String? ?? m['itemName'] as String? ?? '',
        totalUnits:
            ((m['total_units'] ?? m['totalUnits']) as num?)?.toDouble() ?? 0,
        lastUsedAt: m['last_used_at'] as String? ?? m['lastUsedAt'] as String?,
        notes: m['notes'] as String?,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemId': itemId,
        'batchNo': batchNo,
        'date': date,
        'itemName': itemName,
        'totalUnits': totalUnits,
        'lastUsedAt': lastUsedAt,
        'notes': notes,
        'syncState': syncState,
      };
}

class InsulinUsage {
  final String id;
  final String assignId;
  final double units;
  final String date;
  final String? notes;
  final String syncState;

  const InsulinUsage({
    required this.id,
    required this.assignId,
    required this.units,
    required this.date,
    this.notes,
    this.syncState = 'pending',
  });

  factory InsulinUsage.fromMap(Map<String, dynamic> m) => InsulinUsage(
        id: m['insulin_usage_id'] ?? m['id'],
        assignId: m['insulin_assign_id'] ?? m['assignId'],
        units: (m['units'] as num).toDouble(),
        date: m['administered_at'] ?? m['date'],
        notes: m['notes'],
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'assignId': assignId,
        'units': units,
        'date': date,
        'notes': notes,
        'syncState': syncState,
      };
}

class BloodSugarLog {
  final String id;
  final double level;
  final String unit;
  final String measuredAt;
  final String? mealContext;
  final String? notes;
  final String syncState;

  const BloodSugarLog({
    required this.id,
    required this.level,
    required this.unit,
    required this.measuredAt,
    this.mealContext,
    this.notes,
    this.syncState = 'pending',
  });

  factory BloodSugarLog.fromMap(Map<String, dynamic> m) => BloodSugarLog(
        id: m['blood_sugar_id'] ?? m['id'],
        level: (m['level'] as num).toDouble(),
        unit: m['unit'] as String? ?? 'mg/dL',
        measuredAt: m['measured_at'] ?? m['measuredAt'],
        mealContext:
            m['meal_context'] as String? ?? m['mealContext'] as String?,
        notes: m['notes'] as String?,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'level': level,
        'unit': unit,
        'measuredAt': measuredAt,
        'mealContext': mealContext,
        'notes': notes,
        'syncState': syncState,
      };
}
