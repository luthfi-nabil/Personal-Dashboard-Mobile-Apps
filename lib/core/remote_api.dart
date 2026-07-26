import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'api_log.dart';
import 'models.dart';

/// Max time to wait for transaction-api / health-api to respond.
const _requestTimeout = Duration(seconds: 10);

/// Thrown when transaction-api / health-api return an error response.
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
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
      throw ApiException(msg);
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
  Future<dynamic> _send(
      String method, Uri uri, Future<http.Response> Function() request,
      [Object? body]) async {
    developer.log('→ $method $uri${body != null ? ' $body' : ''}',
        name: 'RemoteApi');
    final requestBody = body != null ? jsonEncode(body) : null;
    final sw = Stopwatch()..start();
    http.Response res;
    try {
      res = await request().timeout(_requestTimeout);
    } on TimeoutException {
      developer.log('✗ $method $uri timed out after $_requestTimeout',
          name: 'RemoteApi', level: 1000);
      ApiCallLog.instance.add(ApiCallEntry(
        time: DateTime.now(),
        method: method,
        uri: uri,
        duration: sw.elapsed,
        error: 'Timed out after ${_requestTimeout.inSeconds}s',
        requestBody: requestBody,
      ));
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
      throw ApiUnavailableException('Could not reach $method $uri: $e');
    }
    developer.log('← $method $uri (${res.statusCode})', name: 'RemoteApi');
    ApiCallLog.instance.add(ApiCallEntry(
      time: DateTime.now(),
      method: method,
      uri: uri,
      duration: sw.elapsed,
      statusCode: res.statusCode,
      requestBody: requestBody,
      responseBody: res.body.isEmpty ? null : res.body,
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
  }) async =>
      Map<String, dynamic>.from(await _post(_authUri('/register'), {
        'username': username,
        'password': password,
        'email': email,
        'phone_number': phoneNumber,
        'telegram_username': telegramUsername,
      }) as Map);

  /// `POST /api/auth/login`. Returns an [AuthResponse]-shaped map containing
  /// `token`, `token_type`, `expires_in`, `username`, `user_id`, `email`,
  /// `phone_number`, and `telegram_username`.
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async =>
      Map<String, dynamic>.from(await _post(_authUri('/login'), {
        'username': username,
        'password': password,
      }) as Map);

  /// `GET /api/auth/me`. Requires [cfg.authToken] to be set. Useful to
  /// confirm a stored token is still valid and refresh the cached profile.
  Future<Map<String, dynamic>> me() async =>
      Map<String, dynamic>.from(await _get(_authUri('/me')) as Map);

  // ── transaction-api: settings ──────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getSettings() async =>
      _list(await _get(_txnUri('/settings')));

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

  Future<Map<String, dynamic>> createEarning({
    required double totalAmount,
    required String description,
    required String earningCategoryId,
    required String earningCategory,
    required String sourceId,
    required String source,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/earnings'), {
        'total_amount': totalAmount,
        'description': description,
        'earning_category_id': earningCategoryId,
        'earning_category': earningCategory,
        'source_id': sourceId,
        'source': source,
      }) as Map);

  // ── transaction-api: spendings ─────────────────────────────────────────
  Future<void> deleteEarning(String id) async =>
      _delete(_txnUri('/earnings/$id'));

  Future<List<Map<String, dynamic>>> getSpendings() async =>
      _list(await _get(_txnUri('/spendings')));

  Future<Map<String, dynamic>> createSpending({
    required double totalAmount,
    required String description,
    required String spendingCategoryId,
    required String spendingCategory,
    required String sourceId,
    required String source,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/spendings'), {
        'total_amount': totalAmount,
        'description': description,
        'spending_category_id': spendingCategoryId,
        'spending_category': spendingCategory,
        'source_id': sourceId,
        'source': source,
      }) as Map);

  // ── health-api: insulin items ──────────────────────────────────────────
  // Planned expenses
  Future<void> deleteSpending(String id) async =>
      _delete(_txnUri('/spendings/$id'));

  Future<List<Map<String, dynamic>>> getPlannedExpenses() async =>
      _list(await _get(_txnUri('/planned-expenses')));

  Future<Map<String, dynamic>> createPlannedExpense({
    required String id,
    required String itemName,
    required double price,
    required String transactionType,
    String? categoryId,
    String? categoryName,
    String? notes,
    required String priority,
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
      }) as Map);

  Future<void> updatePlannedExpenseStatus({
    required String id,
    required String status,
    double? fulfilledPrice,
  }) async {
    final uri = _txnUri('/planned-expenses/$id/status');
    await _send(
      'PUT',
      uri,
      () => http.put(
        uri,
        headers: _headers(),
        body: jsonEncode({
          'status': status,
          'fulfilled_price': fulfilledPrice,
        }),
      ),
      {'status': status, 'fulfilled_price': fulfilledPrice},
    );
  }

  Future<void> deletePlannedExpense(String id) async =>
      _delete(_txnUri('/planned-expenses/$id'));

  Future<List<Map<String, dynamic>>> getWishlist() => getPlannedExpenses();

  Future<Map<String, dynamic>> createWishlist({
    required String id,
    required String itemName,
    required double price,
    String? notes,
    required String priority,
    String transactionType = 'spending',
    String? categoryId,
    String? categoryName,
  }) =>
      createPlannedExpense(
        id: id,
        itemName: itemName,
        price: price,
        transactionType: transactionType,
        categoryId: categoryId,
        categoryName: categoryName,
        notes: notes,
        priority: priority,
      );

  Future<void> updateWishlistStatus({
    required String id,
    required String status,
    double? fulfilledPrice,
  }) =>
      updatePlannedExpenseStatus(
        id: id,
        status: status,
        fulfilledPrice: fulfilledPrice,
      );

  Future<void> deleteWishlist(String id) => deletePlannedExpense(id);

  // Routine transactions
  Future<List<Map<String, dynamic>>> getRoutines() async =>
      _list(await _get(_txnUri('/routines')));

  Future<List<Map<String, dynamic>>> getRoutinePayments() async =>
      _list(await _get(_txnUri('/routines/payments')));

  Future<Map<String, dynamic>> createRoutine({
    required String id,
    required String itemName,
    required double price,
    required String reminder,
    required String spendingCategoryId,
    required String spendingCategory,
  }) async =>
      Map<String, dynamic>.from(await _post(_txnUri('/routines'), {
        'routine_id': id,
        'item_name': itemName,
        'price': price,
        'reminder': reminder,
        'spending_category_id': spendingCategoryId,
        'spending_category': spendingCategory,
      }) as Map);

  Future<Map<String, dynamic>> createRoutinePayment({
    required String routineId,
    required String id,
    required double price,
    required String sourceId,
    required String source,
  }) async =>
      Map<String, dynamic>.from(
          await _post(_txnUri('/routines/$routineId/payments'), {
        'routine_payment_id': id,
        'price': price,
        'source_id': sourceId,
        'source': source,
      }) as Map);

  Future<void> deleteRoutine(String id) async =>
      _delete(_txnUri('/routines/$id'));

  Future<List<Map<String, dynamic>>> getInsulinItems() async =>
      _list(await _get(_healthUri('/insulin-item')));

  Future<Map<String, dynamic>> createInsulinItem({
    required String name,
    required double units,
    required String uom,
    String? notes,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/insulin-item'), {
        'insulin_item_name': name,
        'units': units,
        'uom': uom,
        'notes': notes,
      }) as Map);

  // ── health-api: insulin assigns (batches) ──────────────────────────────
  Future<List<Map<String, dynamic>>> getInsulinAssignUsage() async =>
      _list(await _get(_healthUri('/insulin-assign-usage')));

  Future<Map<String, dynamic>> createInsulinAssign({
    required String insulinItemId,
    required String batchNo,
    String? notes,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/insulin-assign'), {
        'insulin_item_id': insulinItemId,
        'batch_no': batchNo,
        'notes': notes,
      }) as Map);

  Future<void> deleteInsulinAssign(String id) async =>
      _delete(_healthUri('/insulin-assign/$id'));

  // ── health-api: insulin usage ──────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getInsulinUsages() async =>
      _list(await _get(_healthUri('/insulin-usage')));

  Future<Map<String, dynamic>> createInsulinUsage({
    required String insulinAssignId,
    required double units,
    String? notes,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/insulin-usage'), {
        'insulin_assign_id': insulinAssignId,
        'units': units,
        'notes': notes,
      }) as Map);

  // ── health-api: blood sugar ───────────────────────────────────────────
  Future<void> deleteInsulinUsage(String id) async =>
      _delete(_healthUri('/insulin-usage/$id'));

  Future<List<Map<String, dynamic>>> getBloodSugarLogs() async =>
      _list(await _get(_healthUri('/blood-sugar')));

  Future<Map<String, dynamic>> createBloodSugarLog({
    required double level,
    String unit = 'mg/dL',
    String? mealContext,
    String? notes,
  }) async =>
      Map<String, dynamic>.from(await _post(_healthUri('/blood-sugar'), {
        'level': level,
        'unit': unit,
        'meal_context': mealContext,
        'notes': notes,
      }) as Map);
}
