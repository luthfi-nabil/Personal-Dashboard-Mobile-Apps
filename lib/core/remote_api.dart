import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'api_log.dart';
import 'models.dart';

/// Max time to wait for transaction-api / health-api to respond.
const _requestTimeout = Duration(seconds: 10);

/// Proof images are a few hundred kB; mobile uplinks need longer than the
/// usual timeout (which would also mark the host unreachable).
const _uploadTimeout = Duration(seconds: 60);

/// How long one API host keeps counting as unreachable after a request to it
/// failed to get any answer. See [ApiReachability].
const _unreachableCooldown = Duration(seconds: 15);

/// Thrown when transaction-api / health-api return an error response.
class ApiException implements Exception {
  final String message;

  /// HTTP status of the rejecting response, when there was one. Lets a sync
  /// loop tell a permanent rejection (404/409) from a transient failure.
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

/// Thrown when transaction-api / health-api could not be reached at all
/// (timeout, connection refused, DNS failure, etc.) as opposed to
/// [ApiException], which signals an HTTP-level error from a reachable
/// server. Repo treats this as "go to local mode" - the write is queued
/// locally and retried once the API is reachable again.
class ApiUnavailableException extends ApiException {
  const ApiUnavailableException(super.message);
}

/// Thrown when transaction-api / health-api reject the request with `401`
/// because the Bearer token is missing, malformed, invalid, or expired.
/// Repo keeps the saved login session and falls back to cached data instead
/// of routing the user back to `/login`.
class ApiUnauthorizedException extends ApiException {
  const ApiUnauthorizedException(super.message);
}

/// Short-lived memory of "this API host just failed to answer".
///
/// Saving one transaction while the API is down fires a whole burst of calls:
/// the write itself, then every step of `SyncService.syncNow()` (options,
/// transactions, deletes, planning, health writes) and finally the refresh,
/// which fetches several endpoints in sequence. Without this, each of those
/// waits out its own [_requestTimeout], so the Save button stayed busy for
/// well over a minute. Once one call has proven a host unreachable, further
/// calls to that host fail immediately instead - the queued-locally path is
/// reached in a moment rather than after a chain of timeouts.
///
/// State is kept per host (`uri.origin`) because health-api can be down while
/// transaction-api is fine, and one should never gag the other.
class ApiReachability {
  static final ApiReachability instance = ApiReachability._();
  ApiReachability._();

  final Map<String, DateTime> _downUntil = {};

  bool isDown(Uri uri) {
    final until = _downUntil[uri.origin];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _downUntil.remove(uri.origin);
    return false;
  }

  /// `true` while any host is inside its cooldown. Used to decide whether
  /// there is any point kicking off a sync right now.
  bool get anyDown {
    _downUntil.removeWhere((_, until) => !DateTime.now().isBefore(until));
    return _downUntil.isNotEmpty;
  }

  void markDown(Uri uri) =>
      _downUntil[uri.origin] = DateTime.now().add(_unreachableCooldown);

  /// Drops the cooldown, either because a request just got through or because
  /// something wants the next call to genuinely try again - a manual sync, a
  /// login attempt, or connectivity coming back. Clears every host when [uri]
  /// is omitted.
  void clear([Uri? uri]) {
    if (uri == null) {
      _downUntil.clear();
    } else {
      _downUntil.remove(uri.origin);
    }
  }
}

/// Thin REST client for:
///  - login-api's `/api/auth/...` endpoints (register/login/validate/me)
///  - transaction-api / health-api's JWT-protected `/api/user/...` and
///    `/api/flutter/...` endpoints, which derive `created_by` from the
///    `Authorization: Bearer <token>` header rather than a path segment.
class RemoteApi {
  final AppConfig cfg;
  const RemoteApi(this.cfg);

  String _trim(String base) => base.replaceAll(RegExp(r'/+$'), '');

  Uri _txnUri(String path, [Map<String, dynamic>? query]) {
    final clean = <String, String>{
      for (final e in (query ?? const {}).entries)
        if (e.value != null) e.key: e.value.toString(),
    };
    return Uri.parse('${_trim(cfg.apiBase)}/api/user$path')
        .replace(queryParameters: clean.isNotEmpty ? clean : null);
  }

  Uri _healthUri(String path) =>
      Uri.parse('${_trim(cfg.healthBase)}/api/user$path');

  Uri _authUri(String path) =>
      Uri.parse('${_trim(cfg.loginBase)}/api/auth$path');

  /// login-api's JWT-protected `/api/user/...` scope, which owns app settings.
  Uri _loginUserUri(String path) =>
      Uri.parse('${_trim(cfg.loginBase)}/api/user$path');

  /// Headers sent with every request. Includes the login-api JWT, when
  /// present, so transaction-api / health-api can resolve `created_by`.
  Map<String, String> _headers() => {
        'content-type': 'application/json',
        if (cfg.authToken.trim().isNotEmpty)
          'Authorization': 'Bearer ${cfg.authToken.trim()}',
      };

  // ── Low-level helpers ──────────────────────────────────────────────────
  dynamic _unwrap(http.Response res) {
    Map<String, dynamic>? body;
    if (res.body.isNotEmpty) {
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        body = null;
      }
    }
    if (res.statusCode >= 400) {
      final msg = body?['description']?.toString().isNotEmpty == true
          ? body!['description'].toString()
          : (body?['message']?.toString() ?? 'HTTP ${res.statusCode}');
      if (res.statusCode == 401) throw ApiUnauthorizedException(msg);
      throw ApiException(msg, statusCode: res.statusCode);
    }
    if (body == null) return null;
    if (body['success'] == false) {
      throw ApiException(body['description']?.toString().isNotEmpty == true
          ? body['description'].toString()
          : (body['message']?.toString() ?? 'Request failed'));
    }
    return body['data'];
  }

  /// Logs every outgoing request and its outcome under the 'RemoteApi' tag
  /// (visible in the `flutter run` console / DevTools logging view) so it's
  /// easy to confirm whether the app is actually hitting the APIs.
  ///
  /// [body] is only what gets logged. [timeout] is longer for image uploads,
  /// and [logResponse] is off for responses carrying an image, so the API
  /// Watcher does not hold on to megabytes of base64.
  Future<dynamic> _send(
      String method, Uri uri, Future<http.Response> Function() request,
      [Object? body,
      Duration timeout = _requestTimeout,
      bool logResponse = true]) async {
    developer.log('→ $method $uri${body != null ? ' $body' : ''}',
        name: 'RemoteApi');
    final requestBody = body != null ? jsonEncode(body) : null;
    // A request to a host that just failed is not sent at all - it would only
    // wait out the timeout again. Still logged, so the API Watcher screen
    // shows why nothing went out.
    if (ApiReachability.instance.isDown(uri)) {
      developer.log('✗ $method $uri skipped - host marked unreachable',
          name: 'RemoteApi', level: 900);
      ApiCallLog.instance.add(ApiCallEntry(
        time: DateTime.now(),
        method: method,
        uri: uri,
        duration: Duration.zero,
        error: 'Skipped - API unreachable (retrying in a moment)',
        requestBody: requestBody,
      ));
      throw ApiUnavailableException('API unreachable: $method $uri');
    }
    final sw = Stopwatch()..start();
    http.Response res;
    try {
      res = await request().timeout(timeout);
    } on TimeoutException {
      developer.log('✗ $method $uri timed out after $timeout',
          name: 'RemoteApi', level: 1000);
      ApiCallLog.instance.add(ApiCallEntry(
        time: DateTime.now(),
        method: method,
        uri: uri,
        duration: sw.elapsed,
        error: 'Timed out after ${timeout.inSeconds}s',
        requestBody: requestBody,
      ));
      ApiReachability.instance.markDown(uri);
      throw ApiUnavailableException('Request timed out: $method $uri');
    } catch (e) {
      developer.log('✗ $method $uri failed: $e',
          name: 'RemoteApi', level: 1000);
      ApiCallLog.instance.add(ApiCallEntry(
        time: DateTime.now(),
        method: method,
        uri: uri,
        duration: sw.elapsed,
        error: e.toString(),
        requestBody: requestBody,
      ));
      // Connection refused / DNS failure / etc. - the API is unreachable,
      // not just returning an error, so treat the same as a timeout.
      ApiReachability.instance.markDown(uri);
      throw ApiUnavailableException('Could not reach $method $uri: $e');
    }
    // Any answer - even a 4xx/5xx - proves the host is up again.
    ApiReachability.instance.clear(uri);
    developer.log('← $method $uri (${res.statusCode})', name: 'RemoteApi');
    ApiCallLog.instance.add(ApiCallEntry(
      time: DateTime.now(),
      method: method,
      uri: uri,
      duration: sw.elapsed,
      statusCode: res.statusCode,
      requestBody: requestBody,
      responseBody: res.body.isEmpty
          ? null
          : logResponse
              ? res.body
              : '(${res.body.length} characters, not logged)',
    ));
    return _unwrap(res);
  }

  Future<dynamic> _get(Uri uri) =>
      _send('GET', uri, () => http.get(uri, headers: _headers()));

  Future<dynamic> _post(Uri uri, Map<String, dynamic> body) => _send(
        'POST',
        uri,
        () => http.post(uri, headers: _headers(), body: jsonEncode(body)),
        body,
      );

  Future<dynamic> _put(Uri uri, Map<String, dynamic> body) => _send(
        'PUT',
        uri,
        () => http.put(uri, headers: _headers(), body: jsonEncode(body)),
        body,
      );

  Future<void> _delete(Uri uri) =>
      _send('DELETE', uri, () => http.delete(uri, headers: _headers()));

  List<Map<String, dynamic>> _list(dynamic data) => (data as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  // ── login-api: auth ─────────────────────────────────────────────────────
  /// `POST /api/auth/register`. Returns the created user's profile (no
  /// token - call [login] afterwards to obtain one).
  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    String? email,
    String? phoneNumber,
    String? telegramUsername,
    String? fullName,
  }) async {
    // Tapping Register is the user retrying by hand, so never short-circuit
    // it on a stale unreachable flag.
    ApiReachability.instance.clear(_authUri('/register'));
    return Map<String, dynamic>.from(await _post(_authUri('/register'), {
      'username': username,
      'password': password,
      'email': email,
      'phone_number': phoneNumber,
      'telegram_username': telegramUsername,
      'full_name': fullName,
    }) as Map);
  }

  /// `POST /api/auth/login`. Returns an [AuthResponse]-shaped map containing
  /// `token`, `token_type`, `expires_in`, `username`, `user_id`, `email`,
  /// `phone_number`, `telegram_username` and `full_name`.
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    // See [register]: a hand-typed sign-in always gets a real attempt.
    ApiReachability.instance.clear(_authUri('/login'));
    return Map<String, dynamic>.from(await _post(_authUri('/login'), {
      'username': username,
      'password': password,
    }) as Map);
  }

  /// `GET /api/auth/me`. Requires [cfg.authToken] to be set. Useful to
  /// confirm a stored token is still valid and refresh the cached profile.
  Future<Map<String, dynamic>> me() async =>
      Map<String, dynamic>.from(await _get(_authUri('/me')) as Map);

  // ── login-api: profile ─────────────────────────────────────────────────
  /// `PUT /api/user/profile` on login-api. Sets the signed-in account's
  /// display name (full name or alias); blank clears it.
  Future<void> updateProfile({required String fullName}) => _put(
        _loginUserUri('/profile'),
        {'full_name': fullName.trim().isEmpty ? null : fullName.trim()},
      );

  /// `POST /api/user/users/display-names` on login-api. Maps each known
  /// username to its display name; accounts without one are left out.
  Future<Map<String, String>> getDisplayNames(List<String> usernames) async {
    if (usernames.isEmpty) return const {};
    final rows = _list(await _post(
        _loginUserUri('/users/display-names'), {'usernames': usernames}));
    return {
      for (final row in rows)
        if ((row['full_name'] as String? ?? '').trim().isNotEmpty)
          (row['username'] as String? ?? '').toLowerCase():
              (row['full_name'] as String).trim(),
    };
  }

  // ── login-api: app settings ────────────────────────────────────────────
  // `app_settings` moved out of transaction-api and is now owned by login-api,
  // so both calls below go to `cfg.loginBase`.
  Future<List<Map<String, dynamic>>> getSettings() async =>
      _list(await _get(_loginUserUri('/settings')));

  /// `POST /api/user/settings` on login-api. Stores one preference against the
  /// signed-in account. Only `FEATURE_*` / `PREF_*` keys are accepted.
  Future<void> putSetting(String key, String value) => _post(
        _loginUserUri('/settings'),
        {'app_setting_key': key, 'app_setting_value': value},
      );

  // ── transaction-api: sources ───────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getSources() async =>
      _list(await _get(_txnUri('/source')));

  Future<List<Map<String, dynamic>>> getSourceBalances() async =>
      _list(await _get(_txnUri('/source-balance')));

  Future<Map<String, dynamic>> createSource(String name) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/source'), {'source': name}) as Map);

  Future<void> deleteSource(String sourceId) async =>
      _delete(_txnUri('/source/$sourceId'));

  // ── transaction-api: earning categories ────────────────────────────────
  Future<List<Map<String, dynamic>>> getEarningCategories() async =>
      _list(await _get(_txnUri('/earning-categories')));

  Future<Map<String, dynamic>> createEarningCategory(String name) async =>
      Map<String, dynamic>.from(await _post(
          _txnUri('/earning-categories'), {'earning_category': name}) as Map);

  Future<void> deleteEarningCategory(String id) async =>
      _delete(_txnUri('/earning-categories/$id'));

  // ── transaction-api: spending categories ───────────────────────────────
  Future<List<Map<String, dynamic>>> getSpendingCategories() async =>
      _list(await _get(_txnUri('/spending-categories')));

  Future<Map<String, dynamic>> createSpendingCategory(String name) async =>
      Map<String, dynamic>.from(await _post(
          _txnUri('/spending-categories'), {'spending_category': name}) as Map);

  Future<void> deleteSpendingCategory(String id) async =>
      _delete(_txnUri('/spending-categories/$id'));

  Future<List<Map<String, dynamic>>> getPlannedExpenseCategories() async =>
      _list(await _get(_txnUri('/planned-expense-categories')));

  Future<Map<String, dynamic>> createPlannedExpenseCategory(
          String name) async =>
      Map<String, dynamic>.from(await _post(
          _txnUri('/planned-expense-categories'),
          {'planned_expense_category': name}) as Map);

  Future<void> deletePlannedExpenseCategory(String id) async =>
      _delete(_txnUri('/planned-expense-categories/$id'));

  Future<List<Map<String, dynamic>>> getActivityCategories() async =>
      _list(await _get(_txnUri('/activity-categories')));

  Future<Map<String, dynamic>> createActivityCategory(String name) async =>
      Map<String, dynamic>.from(await _post(
          _txnUri('/activity-categories'), {'activity_category': name}) as Map);

  Future<void> deleteActivityCategory(String id) async =>
      _delete(_txnUri('/activity-categories/$id'));

  // ── transaction-api: earnings ──────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getEarnings() async =>
      _list(await _get(_txnUri('/earnings')));

  /// [createdDate] is when the earning was entered on the device. It is sent so
  /// an earning queued in local mode keeps that moment instead of being stamped
  /// with the time sync finally pushed it; servers that predate the field
  /// ignore it and stamp "now" as before.
  Future<Map<String, dynamic>> createEarning({
    required double totalAmount,
    required String description,
    required String earningCategoryId,
    required String earningCategory,
    required String sourceId,
    required String source,
    String? createdDate,
    String? groupId,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/earnings'), {
        'total_amount': totalAmount,
        'description': description,
        'earning_category_id': earningCategoryId,
        'earning_category': earningCategory,
        'source_id': sourceId,
        'source': source,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
        if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
      }) as Map);

  // ── transaction-api: spendings ─────────────────────────────────────────
  Future<void> deleteEarning(String id) async =>
      _delete(_txnUri('/earnings/$id'));

  Future<List<Map<String, dynamic>>> getSpendings() async =>
      _list(await _get(_txnUri('/spendings')));

  /// Line items ("transaction detail") for every spending the user owns, or
  /// only those of [spendingId] when it is supplied.
  Future<List<Map<String, dynamic>>> getSpendingDetails(
          {String? spendingId}) async =>
      _list(await _get(_txnUri(
        '/spending-details',
        spendingId == null ? null : {'spending_id': spendingId},
      )));

  /// Ticks or unticks one stored line item. The spending header itself is
  /// immutable, so this is the only edit a saved breakdown accepts.
  Future<void> setSpendingDetailChecked({
    required String id,
    required bool checked,
  }) async {
    final uri = _txnUri('/spending-details/$id/checked');
    await _send(
      'PUT',
      uri,
      () => http.put(
        uri,
        headers: _headers(),
        body: jsonEncode({'checked': checked}),
      ),
      {'checked': checked},
    );
  }

  /// Creates a spending. When [details] is non-empty the server also stores
  /// them as `spending_detail` rows and, if [totalAmount] is 0, derives the
  /// total from the items.
  /// See [createEarning] for what [createdDate] is for.
  Future<Map<String, dynamic>> createSpending({
    required double totalAmount,
    required String description,
    required String spendingCategoryId,
    required String spendingCategory,
    required String sourceId,
    required String source,
    List<Map<String, dynamic>> details = const [],
    String? createdDate,
    String? groupId,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/spendings'), {
        'total_amount': totalAmount,
        'description': description,
        'spending_category_id': spendingCategoryId,
        'spending_category': spendingCategory,
        'source_id': sourceId,
        'source': source,
        if (details.isNotEmpty) 'details': details,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
        if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
      }) as Map);

  // ── health-api: insulin items ──────────────────────────────────────────
  // Planned expenses
  Future<void> deleteSpending(String id) async =>
      _delete(_txnUri('/spendings/$id'));

  Future<List<Map<String, dynamic>>> getPlannedExpenses() async =>
      _list(await _get(_txnUri('/planned-expenses')));

  /// See [createEarning] for what [createdDate] is for.
  Future<Map<String, dynamic>> createPlannedExpense({
    required String id,
    required String itemName,
    required double price,
    required String transactionType,
    String? categoryId,
    String? categoryName,
    String? notes,
    required String priority,
    String? createdDate,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/planned-expenses'), {
        'planned_expense_id': id,
        'item_name': itemName,
        'price': price,
        'transaction_type': transactionType,
        'category_id': categoryId,
        'category': categoryName,
        'notes': notes,
        'priority': priority,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
      }) as Map);

  /// [changedAt] is when the item was fulfilled or canceled on the device, so
  /// a status flipped in local mode keeps that moment.
  Future<void> updatePlannedExpenseStatus({
    required String id,
    required String status,
    double? fulfilledPrice,
    String? changedAt,
  }) async {
    final uri = _txnUri('/planned-expenses/$id/status');
    final body = {
      'status': status,
      'fulfilled_price': fulfilledPrice,
      if (changedAt != null && changedAt.isNotEmpty) 'changed_at': changedAt,
    };
    await _send(
      'PUT',
      uri,
      () => http.put(uri, headers: _headers(), body: jsonEncode(body)),
      body,
    );
  }

  Future<void> deletePlannedExpense(String id) async =>
      _delete(_txnUri('/planned-expenses/$id'));

  // ── transaction-api: consumables ───────────────────────────────────────
  Future<List<Map<String, dynamic>>> getConsumables() async =>
      _list(await _get(_txnUri('/consumables')));

  /// Saves one unit. Posting an id that already exists updates it, so a write
  /// queued offline can be retried safely.
  Future<Map<String, dynamic>> createConsumable(
          Map<String, dynamic> payload) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/consumables'), payload) as Map);

  /// Records the date a unit ran out, or puts it back in use with a null
  /// [outDate].
  Future<void> setConsumableOutDate({
    required String id,
    required String? outDate,
  }) async {
    final uri = _txnUri('/consumables/$id/out');
    await _send(
      'PUT',
      uri,
      () => http.put(
        uri,
        headers: _headers(),
        body: jsonEncode({'out_date': outDate}),
      ),
      {'out_date': outDate},
    );
  }

  Future<void> deleteConsumable(String id) async =>
      _delete(_txnUri('/consumables/$id'));

  // ── transaction-api: planned transactions ──────────────────────────────
  Future<List<Map<String, dynamic>>> getPlannedTransactions() async =>
      _list(await _get(_txnUri('/planned-transactions')));

  /// Saves one bundle header. Posting an id that already exists updates its
  /// name, so a write queued offline can be retried safely.
  Future<Map<String, dynamic>> createPlannedTransaction({
    required String id,
    required String name,
    String? createdDate,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/planned-transactions'), {
        'planned_transaction_id': id,
        'name': name,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
      }) as Map);

  Future<List<Map<String, dynamic>>> getPlannedTransactionDetails(
          {String? plannedTransactionId}) async =>
      _list(await _get(_txnUri('/planned-transaction-details', {
        if (plannedTransactionId != null && plannedTransactionId.isNotEmpty)
          'planned_transaction_id': plannedTransactionId,
      })));

  /// Tags one item into an existing bundle. Posting an id that already exists
  /// updates it, so a write queued offline can be retried safely.
  Future<Map<String, dynamic>> createPlannedTransactionDetail(
    String plannedTransactionId,
    Map<String, dynamic> payload,
  ) async =>
      Map<String, dynamic>.from(await _post(
          _txnUri('/planned-transactions/$plannedTransactionId/details'),
          payload) as Map);

  // ── transaction-api: spending groups ───────────────────────────────────
  /// Every group the user belongs to, each with its `members` and
  /// `status_log` embedded.
  Future<List<Map<String, dynamic>>> getSpendingGroups() async =>
      _list(await _get(_txnUri('/groups')));

  /// Every member's tagged spendings/earnings across the user's groups.
  Future<List<Map<String, dynamic>>> getGroupTransactions() async =>
      _list(await _get(_txnUri('/group-transactions')));

  /// Categories of every group the user belongs to.
  Future<List<Map<String, dynamic>>> getGroupCategories() async =>
      _list(await _get(_txnUri('/group-categories')));

  /// Adds (or renames, for an existing [categoryId]) a group category.
  /// Group admin only.
  Future<Map<String, dynamic>> saveGroupCategory({
    required String groupId,
    required String categoryId,
    required String name,
    required String kind,
  }) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/groups/$groupId/categories'), {
        'category_id': categoryId,
        'category_name': name,
        'kind': kind,
      }) as Map);

  /// Removes a group category. Group admin only.
  Future<void> deleteGroupCategory(String groupId, String categoryId) =>
      _delete(_txnUri('/groups/$groupId/categories/$categoryId'));

  /// Creates a group led by the user. Posting an id that already exists
  /// renames it, so a write queued offline can be retried safely.
  Future<void> createSpendingGroup({
    required String id,
    required String name,
    String? createdDate,
  }) =>
      _post(_txnUri('/groups'), {
        'group_id': id,
        'group_name': name,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
      });

  /// Adds [username] to the group and returns the name as the account is
  /// actually spelled. The server rejects an unknown account with 404 and an
  /// existing member with 409.
  Future<String> addGroupMember({
    required String groupId,
    required String username,
    String? addedDate,
  }) async {
    final data = await _post(_txnUri('/groups/$groupId/members'), {
      'username': username,
      if (addedDate != null && addedDate.isNotEmpty) 'added_date': addedDate,
    });
    return (data is Map ? data['username'] as String? : null) ?? username;
  }

  /// Leader-only on/off switch. [statusId] is client-generated so a retry
  /// records the switch once, and [changedAt] is when it was flipped on the
  /// device.
  Future<void> setGroupStatus({
    required String groupId,
    required String statusId,
    required bool isActive,
    required String changedAt,
  }) async {
    final uri = _txnUri('/groups/$groupId/status');
    final body = {
      'status_id': statusId,
      'is_active': isActive,
      'changed_at': changedAt,
    };
    await _send(
      'PUT',
      uri,
      () => http.put(uri, headers: _headers(), body: jsonEncode(body)),
      body,
    );
  }

  // ── transaction-api: group routines & planned expenses ─────────────────
  Future<List<Map<String, dynamic>>> getGroupRoutines() async =>
      _list(await _get(_txnUri('/group-routines')));

  Future<List<Map<String, dynamic>>> getGroupRoutinePayments() async =>
      _list(await _get(_txnUri('/group-routine-payments')));

  Future<List<Map<String, dynamic>>> getGroupPlannedExpenses() async =>
      _list(await _get(_txnUri('/group-planned-expenses')));

  /// Leader-only. Posting an existing [routineId] edits that routine.
  Future<void> saveGroupRoutine({
    required String groupId,
    required String routineId,
    required String itemName,
    required double price,
    required String reminder,
    required String categoryId,
    required String category,
  }) =>
      _post(_txnUri('/groups/$groupId/routines'), {
        'routine_id': routineId,
        'item_name': itemName,
        'price': price,
        'reminder': reminder,
        'spending_category_id': categoryId,
        'spending_category': category,
      });

  Future<void> deleteGroupRoutine(String groupId, String routineId) =>
      _delete(_txnUri('/groups/$groupId/routines/$routineId'));

  /// Pays a group routine out of one of the caller's own sources (recorded
  /// as the caller's spending, tagged into the group).
  Future<void> payGroupRoutine({
    required String groupId,
    required String routineId,
    required String paymentId,
    required double price,
    required String sourceId,
  }) =>
      _post(_txnUri('/groups/$groupId/routines/$routineId/payments'), {
        'payment_id': paymentId,
        'price': price,
        'source_id': sourceId,
        'from_group_balance': false,
      });

  /// The leader's items start `planned`; anyone else's start `requested`.
  Future<Map<String, dynamic>> addGroupPlannedExpense({
    required String groupId,
    required String id,
    required String itemName,
    required double price,
    required String categoryId,
    required String category,
    String notes = '',
  }) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/groups/$groupId/planned-expenses'), {
        'planned_expense_id': id,
        'item_name': itemName,
        'price': price,
        'spending_category_id': categoryId,
        'spending_category': category,
        'notes': notes,
      }) as Map);

  /// Leader-only: approve (`planned`) or reject a member's request.
  Future<void> reviewGroupPlannedExpense(
          String groupId, String id, bool approve) =>
      _put(_txnUri('/groups/$groupId/planned-expenses/$id/review'),
          {'approve': approve});

  /// Buys a `planned` item out of one of the caller's own sources.
  Future<void> fulfillGroupPlannedExpense({
    required String groupId,
    required String id,
    required String paymentId,
    required double price,
    required String sourceId,
  }) =>
      _put(_txnUri('/groups/$groupId/planned-expenses/$id/fulfill'), {
        'payment_id': paymentId,
        'price': price,
        'source_id': sourceId,
        'from_group_balance': false,
      });

  Future<void> cancelGroupPlannedExpense(String groupId, String id) =>
      _delete(_txnUri('/groups/$groupId/planned-expenses/$id'));

  // ── transaction-api: group target spendings ────────────────────────────
  /// Every member's monthly target for the leader, only the caller's for
  /// anyone else, plus whether the leader has targets switched on.
  Future<Map<String, dynamic>> getGroupTargets(String groupId) async =>
      Map<String, dynamic>.from(
          await _get(_txnUri('/groups/$groupId/targets')) as Map);

  /// Sets the caller's own monthly target (zero clears it). Answers with the
  /// group's targets as [getGroupTargets] does.
  Future<Map<String, dynamic>> setGroupTarget(
          String groupId, double amount) async =>
      Map<String, dynamic>.from(
          await _put(_txnUri('/groups/$groupId/target'), {'amount': amount})
              as Map);

  /// Leader-only switch for the whole group's target spendings.
  Future<Map<String, dynamic>> setGroupTargetsEnabled(
          String groupId, bool enabled) async =>
      Map<String, dynamic>.from(await _put(
              _txnUri('/groups/$groupId/target-setting'), {'enabled': enabled})
          as Map);

  // ── transaction-api: proof images ──────────────────────────────────────
  /// Attaches a compressed image to a `spending` / `earning` of the caller
  /// or to a `reimbursement` / `split_payment` they take part in.
  /// [proofId] is client-generated so a retry stores it once.
  Future<Map<String, dynamic>> uploadProof({
    required String proofId,
    required String refType,
    required String refId,
    required String imageBase64,
    String mimeType = 'image/jpeg',
  }) async {
    final uri = _txnUri('/proofs');
    final body = {
      'proof_id': proofId,
      'ref_type': refType,
      'ref_id': refId,
      'mime_type': mimeType,
      'image_base64': imageBase64,
    };
    return Map<String, dynamic>.from(await _send(
      'POST',
      uri,
      () => http.post(uri, headers: _headers(), body: jsonEncode(body)),
      {...body, 'image_base64': '(${imageBase64.length} characters)'},
      _uploadTimeout,
    ) as Map);
  }

  /// The proofs of one record the caller may see, without their images.
  Future<List<Map<String, dynamic>>> getProofs(
          String refType, String refId) async =>
      _list(await _get(
          _txnUri('/proofs', {'ref_type': refType, 'ref_id': refId})));

  /// One proof with its `image_base64`.
  Future<Map<String, dynamic>> getProof(String proofId) async {
    final uri = _txnUri('/proofs/$proofId');
    return Map<String, dynamic>.from(await _send(
      'GET',
      uri,
      () => http.get(uri, headers: _headers()),
      null,
      _uploadTimeout,
      false,
    ) as Map);
  }

  Future<void> deleteProof(String proofId) =>
      _delete(_txnUri('/proofs/$proofId'));

  // ── transaction-api: reimbursements & split bills ──────────────────────
  /// Every reimbursement, split share and split payment of the group, plus
  /// its saved names of people outside the app.
  Future<Map<String, dynamic>> getGroupSettlements(String groupId) async =>
      Map<String, dynamic>.from(
          await _get(_txnUri('/groups/$groupId/settlements')) as Map);

  /// Pays the owner of a group spending back [amount], from one of the
  /// caller's sources into the owner's [toSourceId].
  Future<void> reimburseGroupTransaction({
    required String groupId,
    required String reimbursementId,
    required String transactionId,
    required String fromSourceId,
    required double amount,
    required String toSourceId,
    String description = '',
  }) =>
      _post(_txnUri('/groups/$groupId/reimbursements'), {
        'reimbursement_id': reimbursementId,
        'transaction_id': transactionId,
        'from_source_id': fromSourceId,
        'from_group_balance': false,
        'personal_amount': amount,
        'to_source_id': toSourceId,
        'return_balance': false,
        'description': description,
      });

  /// A share of the caller's group spending for a group member ([username])
  /// or for anyone by [name].
  Future<void> addGroupSplitShare({
    required String groupId,
    required String shareId,
    required String transactionId,
    String? username,
    String? name,
    required double amount,
  }) =>
      _post(_txnUri('/groups/$groupId/split-shares'), {
        'share_id': shareId,
        'transaction_id': transactionId,
        if (username != null) 'username': username,
        if (name != null) 'name': name,
        'amount': amount,
      });

  Future<void> removeGroupSplitShare(String groupId, String shareId) =>
      _delete(_txnUri('/groups/$groupId/split-shares/$shareId'));

  /// The caller pays part of their share from [fromSourceId]. It waits for
  /// the owner's approval.
  Future<void> payGroupSplitShare({
    required String groupId,
    required String shareId,
    required String paymentId,
    required double amount,
    required String fromSourceId,
    String note = '',
  }) =>
      _post(_txnUri('/groups/$groupId/split-shares/$shareId/payments'), {
        'payment_id': paymentId,
        'amount': amount,
        'from_source_id': fromSourceId,
        'from_group_balance': false,
        'note': note,
      });

  /// The owner records money received from a name-only person, into
  /// [toSourceId].
  Future<void> recordGroupSplitPayment({
    required String groupId,
    required String shareId,
    required String paymentId,
    required double amount,
    required String toSourceId,
    String note = '',
  }) =>
      _post(_txnUri('/groups/$groupId/split-shares/$shareId/manual-payments'), {
        'payment_id': paymentId,
        'amount': amount,
        'to_source_id': toSourceId,
        'to_group_balance': false,
        'note': note,
      });

  /// The owner approves (money lands in [toSourceId]) or rejects a pending
  /// split payment.
  Future<void> reviewGroupSplitPayment({
    required String groupId,
    required String paymentId,
    required bool approve,
    String? toSourceId,
  }) =>
      _put(_txnUri('/groups/$groupId/split-payments/$paymentId/review'), {
        'approve': approve,
        if (toSourceId != null) 'to_source_id': toSourceId,
        'to_group_balance': false,
      });

  Future<void> withdrawGroupSplitPayment(String groupId, String paymentId) =>
      _delete(_txnUri('/groups/$groupId/split-payments/$paymentId'));

  Future<void> forgetGroupName(String groupId, String name) =>
      _delete(_txnUri('/groups/$groupId/names/${Uri.encodeComponent(name)}'));

  // ── transaction-api: transfers to group members ─────────────────────────
  /// Source names of a group mate, to pick where a transfer lands.
  Future<List<Map<String, dynamic>>> getMemberSources(String username) async =>
      _list(await _get(
          _txnUri('/member-sources/${Uri.encodeComponent(username)}')));

  /// Sends [amount] from one of the caller's sources to one of
  /// [toUsername]'s. [transferId] is client-generated so a retry sends once.
  Future<void> sendMemberTransfer({
    required String transferId,
    required String toUsername,
    required String fromSourceId,
    required String toSourceId,
    required double amount,
    String description = '',
    String? createdDate,
  }) =>
      _post(_txnUri('/member-transfers'), {
        'transfer_id': transferId,
        'to_username': toUsername,
        'from_source_id': fromSourceId,
        'to_source_id': toSourceId,
        'amount': amount,
        'description': description,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
      });

  // ── transaction-api: fund requests ─────────────────────────────────────
  /// `{requests: [...], balances: [...]}` across all the caller's groups.
  Future<Map<String, dynamic>> getFundRequests() async {
    final data = await _get(_txnUri('/fund-requests'));
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// `kind` `request` asks [username] for money; `send` sends it now.
  Future<void> createFundRequest({
    required String groupId,
    required String requestId,
    required String kind,
    required String username,
    required double amount,
    required String tag,
    String note = '',
    bool tracked = false,
    String? toSourceId,
    String? fromSourceId,
  }) =>
      _post(_txnUri('/groups/$groupId/fund-requests'), {
        'request_id': requestId,
        'kind': kind,
        'username': username,
        'amount': amount,
        'tag': tag,
        'note': note,
        'tracked': tracked,
        if (toSourceId != null) 'to_source_id': toSourceId,
        if (fromSourceId != null) 'from_source_id': fromSourceId,
      });

  Future<void> fulfillFundRequest({
    required String groupId,
    required String requestId,
    required String fromSourceId,
    String? toSourceId,
  }) =>
      _put(_txnUri('/groups/$groupId/fund-requests/$requestId/fulfill'), {
        'from_source_id': fromSourceId,
        if (toSourceId != null) 'to_source_id': toSourceId,
      });

  Future<void> rejectFundRequest(String groupId, String requestId) =>
      _put(_txnUri('/groups/$groupId/fund-requests/$requestId/reject'), {});

  Future<void> cancelFundRequest(String groupId, String requestId) =>
      _delete(_txnUri('/groups/$groupId/fund-requests/$requestId'));

  Future<void> waiveFundRequest(String groupId, String requestId,
          {String note = ''}) =>
      _put(_txnUri('/groups/$groupId/fund-requests/$requestId/waive'),
          {'note': note});

  // ── transaction-api: investments ───────────────────────────────────────
  Future<List<Map<String, dynamic>>> getInvestments() async =>
      _list(await _get(_txnUri('/investments')));

  /// Saves one holding. Posting an id that already exists updates it, so a
  /// write queued offline can be retried safely.
  Future<Map<String, dynamic>> createInvestment(
          Map<String, dynamic> payload) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/investments'), payload) as Map);

  /// Records a fresh valuation only. Units and cost basis are not editable
  /// through this route, so a price refresh can never rewrite the purchase.
  Future<void> updateInvestmentPrice({
    required String id,
    required double lastUnitPrice,
    required String priceSource,
    required String priceUpdatedAt,
  }) async {
    final uri = _txnUri('/investments/$id/price');
    final body = {
      'last_unit_price': lastUnitPrice,
      'price_source': priceSource,
      'price_updated_date': priceUpdatedAt,
    };
    await _send(
      'PUT',
      uri,
      () => http.put(uri, headers: _headers(), body: jsonEncode(body)),
      body,
    );
  }

  Future<void> deleteInvestment(String id) async =>
      _delete(_txnUri('/investments/$id'));

  // Routine transactions
  Future<List<Map<String, dynamic>>> getRoutines() async =>
      _list(await _get(_txnUri('/routines')));

  Future<List<Map<String, dynamic>>> getRoutinePayments() async =>
      _list(await _get(_txnUri('/routines/payments')));

  /// See [createEarning] for what [createdDate] is for.
  Future<Map<String, dynamic>> createRoutine({
    required String id,
    required String itemName,
    required double price,
    required String reminder,
    required String spendingCategoryId,
    required String spendingCategory,
    String? createdDate,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/routines'), {
        'routine_id': id,
        'item_name': itemName,
        'price': price,
        'reminder': reminder,
        'spending_category_id': spendingCategoryId,
        'spending_category': spendingCategory,
        if (createdDate != null && createdDate.isNotEmpty)
          'created_date': createdDate,
      }) as Map);

  /// [boughtAt] is when the payment was confirmed on the device. The server
  /// also copies it into the routine's "last bought" stamp, so a payment
  /// confirmed in local mode does not jump forward to the time it was pushed.
  Future<Map<String, dynamic>> createRoutinePayment({
    required String routineId,
    required String id,
    required double price,
    required String sourceId,
    required String source,
    String? boughtAt,
  }) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/routines/$routineId/payments'), {
        'routine_payment_id': id,
        'price': price,
        'source_id': sourceId,
        'source': source,
        if (boughtAt != null && boughtAt.isNotEmpty) 'bought_at': boughtAt,
      }) as Map);

  Future<void> deleteRoutine(String id) async =>
      _delete(_txnUri('/routines/$id'));

  Future<List<Map<String, dynamic>>> getInsulinItems() async =>
      _list(await _get(_healthUri('/insulin-item')));

  /// See [createEarning] for what [createdAt] is for.
  Future<Map<String, dynamic>> createInsulinItem({
    required String name,
    required double units,
    required String uom,
    String? notes,
    String? createdAt,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/insulin-item'), {
        'insulin_item_name': name,
        'units': units,
        'uom': uom,
        'notes': notes,
        if (createdAt != null && createdAt.isNotEmpty) 'created_at': createdAt,
      }) as Map);

  // ── health-api: insulin assigns (batches) ──────────────────────────────
  Future<List<Map<String, dynamic>>> getInsulinAssignUsage() async =>
      _list(await _get(_healthUri('/insulin-assign-usage')));

  Future<Map<String, dynamic>> createInsulinAssign({
    required String insulinItemId,
    required String batchNo,
    String? notes,
    String? addedAt,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/insulin-assign'), {
        'insulin_item_id': insulinItemId,
        'batch_no': batchNo,
        'notes': notes,
        if (addedAt != null && addedAt.isNotEmpty) 'added_at': addedAt,
      }) as Map);

  Future<void> deleteInsulinAssign(String id) async =>
      _delete(_healthUri('/insulin-assign/$id'));

  // ── health-api: insulin usage ──────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getInsulinUsages() async =>
      _list(await _get(_healthUri('/insulin-usage')));

  /// [administeredAt] is when the shot was logged on the device, so one queued
  /// in local mode keeps that moment instead of the time it was pushed.
  Future<Map<String, dynamic>> createInsulinUsage({
    required String insulinAssignId,
    required double units,
    String? notes,
    String? administeredAt,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/insulin-usage'), {
        'insulin_assign_id': insulinAssignId,
        'units': units,
        'notes': notes,
        if (administeredAt != null && administeredAt.isNotEmpty)
          'administered_at': administeredAt,
      }) as Map);

  // ── health-api: blood sugar ───────────────────────────────────────────
  Future<void> deleteInsulinUsage(String id) async =>
      _delete(_healthUri('/insulin-usage/$id'));

  Future<List<Map<String, dynamic>>> getBloodSugarLogs() async =>
      _list(await _get(_healthUri('/blood-sugar')));

  /// [measuredAt] is when the reading was taken on the device; see
  /// [createInsulinUsage].
  Future<Map<String, dynamic>> createBloodSugarLog({
    required double level,
    String unit = 'mg/dL',
    String? mealContext,
    String? notes,
    String? measuredAt,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/blood-sugar'), {
        'level': level,
        'unit': unit,
        'meal_context': mealContext,
        'notes': notes,
        if (measuredAt != null && measuredAt.isNotEmpty)
          'measured_at': measuredAt,
      }) as Map);
}
