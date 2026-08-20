import 'dart:convert';

import 'features.dart';

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

/// A single line item of a spending transaction - the "transaction detail".
///
/// Rows are created either by hand on the Add-transaction screen or by the
/// receipt scanner, which OCRs a printed price list and lets the user confirm
/// each recognised item before saving. They map 1:1 onto the transaction-api's
/// `spending_detail` table.
class TransactionDetail {
  final String id;

  /// The owning transaction's id. For a spending queued offline this is the
  /// locally generated uuid, which is replaced by the server id on the next
  /// full refresh.
  final String transactionId;
  final String itemName;
  final double quantity;
  final double unitPrice;
  final double amount;
  final String note;

  /// Whether the item is ticked on the checklist. Items start ticked; unticking
  /// one records that it was not actually bought while keeping it in the
  /// breakdown, and leaves it out of the checked total.
  final bool checked;

  /// `'pending'` (queued with a not-yet-pushed transaction), `'checkDirty'`
  /// (synced item whose tick was changed offline) or `'synced'`.
  final String syncState;
  final String updatedAt;

  const TransactionDetail({
    required this.id,
    required this.transactionId,
    required this.itemName,
    this.quantity = 1,
    this.unitPrice = 0,
    this.amount = 0,
    this.note = '',
    this.checked = true,
    this.syncState = 'pending',
    required this.updatedAt,
  });

  /// Line total, falling back to `quantity * unitPrice` when the OCR only
  /// picked up a unit price.
  double get lineTotal => amount != 0 ? amount : quantity * unitPrice;

  /// What this row contributes to the amount actually paid.
  double get checkedTotal => checked ? lineTotal : 0;

  factory TransactionDetail.fromMap(Map<String, dynamic> m) =>
      TransactionDetail(
        id: m['id'] as String,
        transactionId: m['transactionId'] as String,
        itemName: m['itemName'] as String? ?? '',
        quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
        unitPrice: (m['unitPrice'] as num?)?.toDouble() ?? 0,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String? ?? '',
        checked: (m['checked'] as int? ?? 1) != 0,
        syncState: m['syncState'] as String? ?? 'pending',
        updatedAt: m['updatedAt'] as String,
      );

  /// Builds a detail from a `spending_detail` row returned by transaction-api.
  factory TransactionDetail.fromApi(Map<String, dynamic> m) =>
      TransactionDetail(
        id: m['spending_detail_id'] as String,
        transactionId: m['spending_id'] as String,
        itemName: m['item_name'] as String? ?? '',
        quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String? ?? '',
        // Servers that predate the checklist omit the field; those rows were
        // all bought, so they read as ticked.
        checked: m['is_checked'] as bool? ?? true,
        syncState: 'synced',
        updatedAt: (m['created_date'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'transactionId': transactionId,
        'itemName': itemName,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'amount': amount,
        'note': note,
        'checked': checked ? 1 : 0,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  /// Request shape expected by `POST /api/user/spendings` -> `details[]`.
  Map<String, dynamic> toApiPayload() => {
        'item_name': itemName,
        'quantity': quantity,
        'unit_price': unitPrice,
        'amount': lineTotal,
        'note': note,
        'checked': checked,
      };

  TransactionDetail copyWith({
    String? id,
    String? transactionId,
    String? itemName,
    double? quantity,
    double? unitPrice,
    double? amount,
    String? note,
    bool? checked,
    String? syncState,
    String? updatedAt,
  }) =>
      TransactionDetail(
        id: id ?? this.id,
        transactionId: transactionId ?? this.transactionId,
        itemName: itemName ?? this.itemName,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
        amount: amount ?? this.amount,
        note: note ?? this.note,
        checked: checked ?? this.checked,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// One physical unit of something that gets used up - a bottle of shampoo, a
/// tube of toothpaste.
///
/// Units are tracked one by one rather than as a stock count: buying a
/// three-pack creates three of these, so each can run out on its own date and
/// "how long does one last" is just [daysInUse]. Maps onto transaction-api's
/// `consumable` table.
class Consumable {
  final String id;
  final String itemName;
  final String notes;

  /// Position within the batch it was bought in, and that batch's size. Both
  /// are 1 for a single unit added by hand; a 3-pack yields 1/3, 2/3, 3/3.
  final int unitIndex;
  final int unitTotal;
  final double price;

  /// When the unit came in.
  final String inDate;

  /// When it ran out; empty while it is still in use.
  final String outDate;

  /// Set when the unit came from a transaction's line item, so the page can
  /// point back at the purchase.
  final String transactionId;
  final String transactionDetailId;
  final String syncState;
  final String updatedAt;

  const Consumable({
    required this.id,
    required this.itemName,
    this.notes = '',
    this.unitIndex = 1,
    this.unitTotal = 1,
    this.price = 0,
    required this.inDate,
    this.outDate = '',
    this.transactionId = '',
    this.transactionDetailId = '',
    this.syncState = 'synced',
    required this.updatedAt,
  });

  bool get isInUse => outDate.isEmpty;

  /// Whether this unit is one of several bought together, which is the only
  /// case where the "2/3" label is worth showing.
  bool get isPartOfBatch => unitTotal > 1;

  /// Days between the in date and either the out date or today - how long the
  /// unit lasted, or has lasted so far. Null when the in date is unreadable.
  int? get daysInUse {
    final start = DateTime.tryParse(inDate);
    if (start == null) return null;
    final end = outDate.isEmpty ? DateTime.now() : DateTime.tryParse(outDate);
    if (end == null) return null;
    final days = end.difference(start).inDays;
    return days < 0 ? 0 : days;
  }

  factory Consumable.fromMap(Map<String, dynamic> m) => Consumable(
        id: m['id'] as String,
        itemName: m['itemName'] as String? ?? '',
        notes: m['notes'] as String? ?? '',
        unitIndex: (m['unitIndex'] as num?)?.toInt() ?? 1,
        unitTotal: (m['unitTotal'] as num?)?.toInt() ?? 1,
        price: (m['price'] as num?)?.toDouble() ?? 0,
        inDate: m['inDate'] as String? ?? '',
        outDate: m['outDate'] as String? ?? '',
        transactionId: m['transactionId'] as String? ?? '',
        transactionDetailId: m['transactionDetailId'] as String? ?? '',
        syncState: m['syncState'] as String? ?? 'synced',
        updatedAt: m['updatedAt'] as String? ?? '',
      );

  /// Builds a unit from a `consumable` row returned by transaction-api.
  factory Consumable.fromApi(Map<String, dynamic> m) => Consumable(
        id: m['consumable_id'] as String,
        itemName: m['item_name'] as String? ?? '',
        notes: m['notes'] as String? ?? '',
        unitIndex: (m['unit_index'] as num?)?.toInt() ?? 1,
        unitTotal: (m['unit_total'] as num?)?.toInt() ?? 1,
        price: (m['price'] as num?)?.toDouble() ?? 0,
        inDate: (m['in_date'] ?? '').toString(),
        outDate: (m['out_date'] ?? '').toString(),
        transactionId: (m['spending_id'] ?? '').toString(),
        transactionDetailId: (m['spending_detail_id'] ?? '').toString(),
        syncState: 'synced',
        updatedAt: (m['updated_date'] ?? m['created_date'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemName': itemName,
        'notes': notes,
        'unitIndex': unitIndex,
        'unitTotal': unitTotal,
        'price': price,
        'inDate': inDate,
        'outDate': outDate,
        'transactionId': transactionId,
        'transactionDetailId': transactionDetailId,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  /// Request shape expected by `POST /api/user/consumables`.
  Map<String, dynamic> toApiPayload() => {
        'consumable_id': id,
        'item_name': itemName,
        'notes': notes,
        'unit_index': unitIndex,
        'unit_total': unitTotal,
        'price': price,
        'in_date': inDate,
        'out_date': outDate.isEmpty ? null : outDate,
        if (transactionId.isNotEmpty) 'spending_id': transactionId,
        if (transactionDetailId.isNotEmpty)
          'spending_detail_id': transactionDetailId,
      };

  Consumable copyWith({
    String? id,
    String? itemName,
    String? notes,
    int? unitIndex,
    int? unitTotal,
    double? price,
    String? inDate,
    String? outDate,
    String? transactionId,
    String? transactionDetailId,
    String? syncState,
    String? updatedAt,
  }) =>
      Consumable(
        id: id ?? this.id,
        itemName: itemName ?? this.itemName,
        notes: notes ?? this.notes,
        unitIndex: unitIndex ?? this.unitIndex,
        unitTotal: unitTotal ?? this.unitTotal,
        price: price ?? this.price,
        inDate: inDate ?? this.inDate,
        outDate: outDate ?? this.outDate,
        transactionId: transactionId ?? this.transactionId,
        transactionDetailId: transactionDetailId ?? this.transactionDetailId,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// A named bundle built up from real purchases - e.g. "Camping trip" - so
/// items tagged from several transactions over time can be seen and totaled
/// together. Unlike [PlannedExpenseItem] this has no status/fulfillment: just
/// a name and a running list. Maps onto transaction-api's `planned_transaction`
/// table.
class PlannedTransaction {
  final String id;
  final String name;
  final String createdDate;
  final String updatedAt;
  final String syncState;

  const PlannedTransaction({
    required this.id,
    required this.name,
    required this.createdDate,
    required this.updatedAt,
    this.syncState = 'synced',
  });

  factory PlannedTransaction.fromMap(Map<String, dynamic> m) => PlannedTransaction(
        id: m['id'] as String,
        name: m['name'] as String,
        createdDate: m['createdDate'] as String,
        updatedAt: m['updatedAt'] as String,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  /// Builds a header from a `planned_transaction` row returned by transaction-api.
  factory PlannedTransaction.fromApi(Map<String, dynamic> m) => PlannedTransaction(
        id: m['planned_transaction_id'] as String,
        name: m['name'] as String? ?? '',
        createdDate: (m['created_date'] ?? '').toString(),
        updatedAt: (m['updated_date'] ?? m['created_date'] ?? '').toString(),
        syncState: 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'createdDate': createdDate,
        'updatedAt': updatedAt,
        'syncState': syncState,
      };

  /// Request shape expected by `POST /api/user/planned-transactions`.
  Map<String, dynamic> toApiPayload() => {
        'planned_transaction_id': id,
        'name': name,
        'created_date': createdDate,
      };

  PlannedTransaction copyWith({
    String? id,
    String? name,
    String? createdDate,
    String? updatedAt,
    String? syncState,
  }) =>
      PlannedTransaction(
        id: id ?? this.id,
        name: name ?? this.name,
        createdDate: createdDate ?? this.createdDate,
        updatedAt: updatedAt ?? this.updatedAt,
        syncState: syncState ?? this.syncState,
      );
}

/// One item tagged into a [PlannedTransaction]. [transactionId] /
/// [transactionDetailId] point back at the real transaction line item it came
/// from. Maps onto transaction-api's `planned_transaction_detail` table.
class PlannedTransactionDetail {
  final String id;
  final String plannedTransactionId;
  final String itemName;
  final double quantity;
  final double unitPrice;
  final double amount;
  final String note;
  final String transactionId;
  final String transactionDetailId;
  final String createdDate;
  final String syncState;

  const PlannedTransactionDetail({
    required this.id,
    required this.plannedTransactionId,
    required this.itemName,
    this.quantity = 1,
    this.unitPrice = 0,
    this.amount = 0,
    this.note = '',
    this.transactionId = '',
    this.transactionDetailId = '',
    required this.createdDate,
    this.syncState = 'synced',
  });

  double get lineTotal => amount != 0 ? amount : quantity * unitPrice;

  factory PlannedTransactionDetail.fromMap(Map<String, dynamic> m) =>
      PlannedTransactionDetail(
        id: m['id'] as String,
        plannedTransactionId: m['plannedTransactionId'] as String,
        itemName: m['itemName'] as String? ?? '',
        quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
        unitPrice: (m['unitPrice'] as num?)?.toDouble() ?? 0,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String? ?? '',
        transactionId: m['transactionId'] as String? ?? '',
        transactionDetailId: m['transactionDetailId'] as String? ?? '',
        createdDate: m['createdDate'] as String,
        syncState: m['syncState'] as String? ?? 'synced',
      );

  /// Builds a row from a `planned_transaction_detail` row returned by transaction-api.
  factory PlannedTransactionDetail.fromApi(Map<String, dynamic> m) =>
      PlannedTransactionDetail(
        id: m['planned_transaction_detail_id'] as String,
        plannedTransactionId: m['planned_transaction_id'] as String,
        itemName: m['item_name'] as String? ?? '',
        quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String? ?? '',
        transactionId: (m['spending_id'] ?? '').toString(),
        transactionDetailId: (m['spending_detail_id'] ?? '').toString(),
        createdDate: (m['created_date'] ?? '').toString(),
        syncState: 'synced',
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'plannedTransactionId': plannedTransactionId,
        'itemName': itemName,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'amount': amount,
        'note': note,
        'transactionId': transactionId,
        'transactionDetailId': transactionDetailId,
        'createdDate': createdDate,
        'syncState': syncState,
      };

  /// Request shape expected by
  /// `POST /api/user/planned-transactions/{id}/details`.
  Map<String, dynamic> toApiPayload() => {
        'planned_transaction_detail_id': id,
        'item_name': itemName,
        'quantity': quantity,
        'unit_price': unitPrice,
        'amount': lineTotal,
        'note': note,
        if (transactionId.isNotEmpty) 'spending_id': transactionId,
        if (transactionDetailId.isNotEmpty)
          'spending_detail_id': transactionDetailId,
        'created_date': createdDate,
      };

  PlannedTransactionDetail copyWith({
    String? id,
    String? plannedTransactionId,
    String? itemName,
    double? quantity,
    double? unitPrice,
    double? amount,
    String? note,
    String? transactionId,
    String? transactionDetailId,
    String? createdDate,
    String? syncState,
  }) =>
      PlannedTransactionDetail(
        id: id ?? this.id,
        plannedTransactionId: plannedTransactionId ?? this.plannedTransactionId,
        itemName: itemName ?? this.itemName,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
        amount: amount ?? this.amount,
        note: note ?? this.note,
        transactionId: transactionId ?? this.transactionId,
        transactionDetailId: transactionDetailId ?? this.transactionDetailId,
        createdDate: createdDate ?? this.createdDate,
        syncState: syncState ?? this.syncState,
      );
}

/// What a holding on the Investment page actually is. The string values are
/// the `kind` column in transaction-api's `investment` table — never rename
/// one without a migration, since rows carry it verbatim.
enum InvestmentKind {
  mutualFund('mutual_fund', 'Reksa Dana', 'unit'),
  gold('gold', 'Gold', 'gr'),
  silver('silver', 'Silver', 'gr'),

  /// Catch-all for anything the other three do not cover — crypto, bonds,
  /// stocks. Held in whatever unit makes sense to the user and always priced
  /// by hand, since there is no one API that could quote all of them.
  others('others', 'Others', 'unit');

  const InvestmentKind(this.id, this.label, this.unitLabel);

  final String id;
  final String label;

  /// What one unit of this holding is: a fund unit, or a gram of metal.
  final String unitLabel;

  /// Gold and silver are the two whose value can be refreshed automatically;
  /// the rest have no public price API and are always entered by hand.
  bool get isMetal => this == InvestmentKind.gold || this == InvestmentKind.silver;

  static InvestmentKind fromId(String? id) => values.firstWhere(
        (k) => k.id == id,
        orElse: () => InvestmentKind.mutualFund,
      );
}

/// One investment holding — a reksa dana position, a quantity of gold or
/// silver, or anything else under [InvestmentKind.others]. Kept apart from
/// [Source] balances, which are liquid cash; that split is why Home's headline
/// figure reads "Liquid".
///
/// [units] and the two unit prices mean whatever [kind] implies: units owned
/// and NAB per unit for a fund, grams and price per gram for metal, units owned
/// and price per unit for anything else.
class Investment {
  final String id;
  final InvestmentKind kind;
  final String name;

  /// Where it is held — Bibit, Bareksa, Pegadaian, a safe at home.
  final String provider;
  final double units;

  /// Cost basis per unit. Set when the holding is recorded and never touched
  /// again, so gain/loss survives every price refresh.
  final double buyUnitPrice;

  /// Latest known value per unit. Refreshed from a price API for metal, typed
  /// in by hand for everything else. Stored rather than fetched on read so the
  /// page still shows a value offline — [priceUpdatedAt] says how stale it is.
  final double lastUnitPrice;

  /// Where [lastUnitPrice] came from, e.g. `anekalogam` or `spot`. Empty for a
  /// hand-entered price.
  final String priceSource;
  final String priceUpdatedAt;
  final String notes;
  final String acquiredDate;
  final String syncState;
  final String updatedAt;

  const Investment({
    required this.id,
    required this.kind,
    required this.name,
    this.provider = '',
    this.units = 0,
    this.buyUnitPrice = 0,
    this.lastUnitPrice = 0,
    this.priceSource = '',
    this.priceUpdatedAt = '',
    this.notes = '',
    required this.acquiredDate,
    this.syncState = 'synced',
    required this.updatedAt,
  });

  /// What was put in, at the price actually paid.
  double get investedValue => units * buyUnitPrice;

  /// What it is worth at the last known price. Falls back to the cost basis
  /// while no price has been recorded, which beats showing a total loss.
  double get currentValue =>
      units * (lastUnitPrice > 0 ? lastUnitPrice : buyUnitPrice);

  double get gain => currentValue - investedValue;

  /// Gain as a fraction of what was invested. Null when nothing was invested,
  /// where a percentage would be meaningless rather than infinite.
  double? get gainRatio => investedValue == 0 ? null : gain / investedValue;

  factory Investment.fromMap(Map<String, dynamic> m) => Investment(
        id: m['id'] as String,
        kind: InvestmentKind.fromId(m['kind'] as String?),
        name: m['name'] as String? ?? '',
        provider: m['provider'] as String? ?? '',
        units: (m['units'] as num?)?.toDouble() ?? 0,
        buyUnitPrice: (m['buyUnitPrice'] as num?)?.toDouble() ?? 0,
        lastUnitPrice: (m['lastUnitPrice'] as num?)?.toDouble() ?? 0,
        priceSource: m['priceSource'] as String? ?? '',
        priceUpdatedAt: m['priceUpdatedAt'] as String? ?? '',
        notes: m['notes'] as String? ?? '',
        acquiredDate: m['acquiredDate'] as String? ?? '',
        syncState: m['syncState'] as String? ?? 'synced',
        updatedAt: m['updatedAt'] as String? ?? '',
      );

  /// Builds a holding from an `investment` row returned by transaction-api.
  factory Investment.fromApi(Map<String, dynamic> m) => Investment(
        id: m['investment_id'] as String,
        kind: InvestmentKind.fromId(m['kind'] as String?),
        name: m['name'] as String? ?? '',
        provider: m['provider'] as String? ?? '',
        units: (m['units'] as num?)?.toDouble() ?? 0,
        buyUnitPrice: (m['buy_unit_price'] as num?)?.toDouble() ?? 0,
        lastUnitPrice: (m['last_unit_price'] as num?)?.toDouble() ?? 0,
        priceSource: m['price_source'] as String? ?? '',
        priceUpdatedAt: (m['price_updated_date'] ?? '').toString(),
        notes: m['notes'] as String? ?? '',
        acquiredDate: (m['acquired_date'] ?? '').toString(),
        syncState: 'synced',
        updatedAt: (m['updated_date'] ?? m['created_date'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'kind': kind.id,
        'name': name,
        'provider': provider,
        'units': units,
        'buyUnitPrice': buyUnitPrice,
        'lastUnitPrice': lastUnitPrice,
        'priceSource': priceSource,
        'priceUpdatedAt': priceUpdatedAt,
        'notes': notes,
        'acquiredDate': acquiredDate,
        'syncState': syncState,
        'updatedAt': updatedAt,
      };

  /// Request shape expected by `POST /api/user/investments`.
  Map<String, dynamic> toApiPayload() => {
        'investment_id': id,
        'kind': kind.id,
        'name': name,
        'provider': provider,
        'units': units,
        'buy_unit_price': buyUnitPrice,
        'last_unit_price': lastUnitPrice,
        'price_source': priceSource,
        'price_updated_date': priceUpdatedAt.isEmpty ? null : priceUpdatedAt,
        'notes': notes,
        'acquired_date': acquiredDate,
      };

  Investment copyWith({
    String? id,
    InvestmentKind? kind,
    String? name,
    String? provider,
    double? units,
    double? buyUnitPrice,
    double? lastUnitPrice,
    String? priceSource,
    String? priceUpdatedAt,
    String? notes,
    String? acquiredDate,
    String? syncState,
    String? updatedAt,
  }) =>
      Investment(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        name: name ?? this.name,
        provider: provider ?? this.provider,
        units: units ?? this.units,
        buyUnitPrice: buyUnitPrice ?? this.buyUnitPrice,
        lastUnitPrice: lastUnitPrice ?? this.lastUnitPrice,
        priceSource: priceSource ?? this.priceSource,
        priceUpdatedAt: priceUpdatedAt ?? this.priceUpdatedAt,
        notes: notes ?? this.notes,
        acquiredDate: acquiredDate ?? this.acquiredDate,
        syncState: syncState ?? this.syncState,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// Reads the persisted `features` object, ignoring anything that is not a
/// plain bool so a hand-edited or older config can never crash startup.
Map<String, bool> _parseFeatures(dynamic raw) {
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      if (entry.value is bool) entry.key.toString(): entry.value as bool,
  };
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

  /// Optional features the user has switched on or off, keyed by
  /// [AppFeature.id]. Absent keys fall back to the feature's default, so a
  /// flag added in a later release turns itself on without a migration.
  final Map<String, bool> features;

  /// Whether routine transactions raise a local notification as they come
  /// due. Off by default: the OS asks for notification permission the first
  /// time this is enabled, and that prompt should follow a deliberate choice
  /// rather than ambush someone on first launch.
  final bool remindersEnabled;

  /// Time of day reminders fire, as local wall-clock.
  final int reminderHour;
  final int reminderMinute;

  /// How many days before the due date to notify. `0` means on the day.
  final int reminderLeadDays;

  /// Whether the OS is allowed to wake the app periodically to sync while it
  /// is closed. Distinct from [autoSync], which only covers the in-process
  /// timer that runs while the app is on screen.
  final bool backgroundSyncEnabled;

  /// Requested gap between background syncs. Android's WorkManager will not
  /// go below 15 minutes and treats this as a floor rather than a promise -
  /// Doze can stretch it considerably.
  final int backgroundSyncMinutes;

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
    this.features = const {},
    this.remindersEnabled = false,
    this.reminderHour = 9,
    this.reminderMinute = 0,
    this.reminderLeadDays = 1,
    this.backgroundSyncEnabled = true,
    this.backgroundSyncMinutes = 30,
  });

  /// Whether the optional feature [featureId] is switched on. Unknown or
  /// never-touched flags fall back to the registry default.
  bool isFeatureEnabled(String featureId) =>
      features[featureId] ?? AppFeatures.byId(featureId)?.defaultEnabled ?? true;

  /// Convenience for the Health/Diabetic section, which is checked in a lot
  /// of places.
  bool get healthEnabled => isFeatureEnabled(AppFeatures.health.id);

  /// Returns a copy with [featureId] set to [enabled].
  AppConfig withFeature(String featureId, bool enabled) =>
      copyWith(features: {...features, featureId: enabled});

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
      features: _parseFeatures(m['features']),
      remindersEnabled: m['remindersEnabled'] as bool? ?? false,
      reminderHour: m['reminderHour'] as int? ?? 9,
      reminderMinute: m['reminderMinute'] as int? ?? 0,
      reminderLeadDays: m['reminderLeadDays'] as int? ?? 1,
      backgroundSyncEnabled: m['backgroundSyncEnabled'] as bool? ?? true,
      backgroundSyncMinutes: m['backgroundSyncMinutes'] as int? ?? 30,
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
        'features': features,
        'remindersEnabled': remindersEnabled,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
        'reminderLeadDays': reminderLeadDays,
        'backgroundSyncEnabled': backgroundSyncEnabled,
        'backgroundSyncMinutes': backgroundSyncMinutes,
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
    Map<String, bool>? features,
    bool? remindersEnabled,
    int? reminderHour,
    int? reminderMinute,
    int? reminderLeadDays,
    bool? backgroundSyncEnabled,
    int? backgroundSyncMinutes,
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
        features: features ?? this.features,
        remindersEnabled: remindersEnabled ?? this.remindersEnabled,
        reminderHour: reminderHour ?? this.reminderHour,
        reminderMinute: reminderMinute ?? this.reminderMinute,
        reminderLeadDays: reminderLeadDays ?? this.reminderLeadDays,
        backgroundSyncEnabled:
            backgroundSyncEnabled ?? this.backgroundSyncEnabled,
        backgroundSyncMinutes:
            backgroundSyncMinutes ?? this.backgroundSyncMinutes,
      );
}

class AppData {
  final List<Source> sources;
  final List<Category> categories;
  final List<Transaction> transactions;

  /// Line items for spending transactions, keyed by [TransactionDetail.transactionId].
  final List<TransactionDetail> transactionDetails;
  final List<PlannedExpenseItem> plannedExpenseItems;
  final List<RoutineTransaction> routineTransactions;
  final List<RoutinePayment> routinePayments;

  /// Units of things that run out, newest first. See [Consumable].
  final List<Consumable> consumables;

  /// Reksa dana, gold and silver holdings. See [Investment].
  final List<Investment> investments;

  /// Named bundles built up from real purchases. See [PlannedTransaction].
  final List<PlannedTransaction> plannedTransactions;

  /// Items tagged into a [PlannedTransaction]. See [PlannedTransactionDetail].
  final List<PlannedTransactionDetail> plannedTransactionDetails;
  final List<InsulinItem> insulinItems;
  final List<InsulinAssign> insulinAssigns;
  final List<InsulinUsage> insulinUsages;
  final List<BloodSugarLog> bloodSugarLogs;

  const AppData({
    required this.sources,
    required this.categories,
    required this.transactions,
    this.transactionDetails = const [],
    this.plannedExpenseItems = const [],
    this.routineTransactions = const [],
    this.routinePayments = const [],
    this.consumables = const [],
    this.investments = const [],
    this.plannedTransactions = const [],
    this.plannedTransactionDetails = const [],
    this.insulinItems = const [],
    this.insulinAssigns = const [],
    this.insulinUsages = const [],
    this.bloodSugarLogs = const [],
  });

  /// The line items belonging to [transactionId], or an empty list when the
  /// transaction was saved without a breakdown.
  List<TransactionDetail> detailsFor(String transactionId) => transactionDetails
      .where((d) => d.transactionId == transactionId)
      .toList();

  /// The items tagged into [plannedTransactionId].
  List<PlannedTransactionDetail> plannedTransactionDetailsFor(
          String plannedTransactionId) =>
      plannedTransactionDetails
          .where((d) => d.plannedTransactionId == plannedTransactionId)
          .toList();
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

class PlannedExpenseItem {
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

  const PlannedExpenseItem({
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

  factory PlannedExpenseItem.fromMap(Map<String, dynamic> m) => PlannedExpenseItem(
        id: m['planned_expense_id'] as String? ?? m['id'] as String,
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

  PlannedExpenseItem copyWith({
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
      PlannedExpenseItem(
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
