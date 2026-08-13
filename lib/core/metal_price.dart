import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'api_log.dart';
import 'models.dart';

/// Live gold and silver prices in rupiah per gram, for the Investment page.
///
/// Two different sources, because no single free one covers both:
///
///  * **Gold** comes from `logam-mulia-api`, a public scraper of Indonesian
///    retailers (Antam, Pegadaian, Aneka Logam). It quotes IDR per gram
///    directly, including the *buyback* price - what a dealer would actually
///    pay you - which is the honest number to value a holding at.
///  * **Silver** is not carried by that API by any of its sources, so it is
///    derived from the global spot price (`gold-api.com`, USD per troy ounce)
///    converted with a USD-IDR rate. That is a market reference, not a dealer
///    quote, so real silver sells for somewhat less.
///
/// Every host here is a free public endpoint with no key and no account. They
/// can go down or change shape without notice, so a failure is always soft:
/// [fetchAll] returns whatever it managed to get and the page keeps showing
/// the last price stored on each holding.
class MetalPriceService {
  MetalPriceService._();
  static final MetalPriceService instance = MetalPriceService._();

  static const _timeout = Duration(seconds: 12);

  /// Gold retailers, in the order they are tried. `anekalogam` leads because
  /// it is the only one that publishes both a sell and a buyback price at 1
  /// gram; the rest are fallbacks for when it stops responding.
  static const _goldSources = ['anekalogam', 'pegadaian', 'logammulia'];

  static const _logamMuliaBase = 'https://logam-mulia-api.iamutaki.workers.dev';
  static const _spotBase = 'https://api.gold-api.com';

  /// One troy ounce in grams - the unit the spot price is quoted in.
  static const _gramsPerTroyOunce = 31.1034768;

  /// Prices move slowly (retail gold updates once a day, spot within the day)
  /// and these are courtesy endpoints, so repeated visits to the page reuse a
  /// recent answer instead of hammering them.
  static const _cacheTtl = Duration(minutes: 30);

  final Map<InvestmentKind, MetalQuote> _cache = {};
  DateTime? _cachedAt;

  /// Last successfully fetched quotes, even if now stale. Lets the page show
  /// something immediately while a refresh is in flight.
  Map<InvestmentKind, MetalQuote> get cached => Map.unmodifiable(_cache);

  bool get isCacheFresh =>
      _cachedAt != null && DateTime.now().difference(_cachedAt!) < _cacheTtl;

  /// Fetches gold and silver together, returning only what succeeded — an
  /// empty map means every source failed, which callers should treat as
  /// "leave the stored prices alone" rather than "the metals are worthless".
  ///
  /// Set [force] to bypass the cache for a pull-to-refresh.
  Future<Map<InvestmentKind, MetalQuote>> fetchAll({bool force = false}) async {
    if (!force && isCacheFresh && _cache.isNotEmpty) return cached;

    // Neither leg throws - both swallow their own failures and answer null -
    // so one dead source never takes the other down with it.
    final results = await Future.wait([_fetchGold(), _fetchSilver()]);

    final quotes = <InvestmentKind, MetalQuote>{
      for (final quote in results)
        if (quote != null) quote.kind: quote,
    };
    if (quotes.isNotEmpty) {
      _cache.addAll(quotes);
      _cachedAt = DateTime.now();
    }
    return quotes;
  }

  // ── Gold ───────────────────────────────────────────────────────────────
  /// Walks [_goldSources] until one answers with a usable price. Each entry is
  /// normalised to per-gram, since retailers quote 0.5 gr, 1 gr, 100 gr and
  /// (for Pegadaian) 0.01 gr bars.
  Future<MetalQuote?> _fetchGold() async {
    for (final source in _goldSources) {
      try {
        final uri = Uri.parse('$_logamMuliaBase/api/prices/$source?length=50');
        final body = await _getJson(uri);
        final rows = (body?['data'] as List?) ?? const [];

        final candidates = <_GoldRow>[];
        for (final raw in rows) {
          if (raw is! Map) continue;
          if ((raw['material'] ?? 'gold').toString() != 'gold') continue;
          final weight = _toDouble(raw['weight']);
          if (weight == null || weight <= 0) continue;
          // Buyback is what a dealer pays; the sell price is what you would
          // pay them, and overstates a holding by the dealer's margin.
          final buyback = _toDouble(raw['buybackPrice']);
          final sell = _toDouble(raw['sellPrice']);
          final total = (buyback != null && buyback > 0) ? buyback : sell;
          if (total == null || total <= 0) continue;
          candidates.add(_GoldRow(
            pricePerGram: total / weight,
            weight: weight,
            isBuyback: buyback != null && buyback > 0,
            recordedDate: (raw['recordedDate'] ?? '').toString(),
            displayName: (raw['displayName'] ?? source).toString(),
          ));
        }
        if (candidates.isEmpty) continue;

        // Per-gram price varies with bar size (small bars carry a bigger
        // fabrication margin), so prefer the row closest to 1 gram as the
        // fairest single number to value a holding with.
        candidates.sort((a, b) =>
            (a.weight - 1).abs().compareTo((b.weight - 1).abs()));
        final best = candidates.first;

        return MetalQuote(
          kind: InvestmentKind.gold,
          pricePerGram: best.pricePerGram,
          source: source,
          label: best.isBuyback
              ? '${best.displayName} buyback'
              : '${best.displayName} sell',
          quotedAt: DateTime.tryParse(best.recordedDate) ?? DateTime.now(),
        );
      } catch (_) {
        // Try the next retailer.
      }
    }
    return null;
  }

  // ── Silver ─────────────────────────────────────────────────────────────
  /// Global spot XAG (USD per troy ounce) converted to IDR per gram. Both legs
  /// have to succeed; there is no partial answer worth showing.
  Future<MetalQuote?> _fetchSilver() async {
    final spot = await _fetchSpotUsdPerOunce('XAG');
    if (spot == null) return null;
    final usdIdr = await _fetchUsdIdr();
    if (usdIdr == null) return null;

    return MetalQuote(
      kind: InvestmentKind.silver,
      pricePerGram: spot / _gramsPerTroyOunce * usdIdr,
      source: 'spot',
      label: 'Global spot × USD-IDR',
      quotedAt: DateTime.now(),
    );
  }

  Future<double?> _fetchSpotUsdPerOunce(String symbol) async {
    try {
      final body = await _getJson(Uri.parse('$_spotBase/price/$symbol'));
      final price = _toDouble(body?['price']);
      return (price != null && price > 0) ? price : null;
    } catch (_) {
      return null;
    }
  }

  /// USD-IDR from exchangerate-api's open endpoint, falling back to
  /// Frankfurter (ECB data). Both are keyless and update daily.
  Future<double?> _fetchUsdIdr() async {
    try {
      final body = await _getJson(
          Uri.parse('https://open.er-api.com/v6/latest/USD'));
      final rate = _toDouble((body?['rates'] as Map?)?['IDR']);
      if (rate != null && rate > 0) return rate;
    } catch (_) {
      // Fall through to the backup source.
    }
    try {
      final body = await _getJson(Uri.parse(
          'https://api.frankfurter.dev/v1/latest?base=USD&symbols=IDR'));
      final rate = _toDouble((body?['rates'] as Map?)?['IDR']);
      if (rate != null && rate > 0) return rate;
    } catch (_) {
      // Give up; the caller leaves the stored price alone.
    }
    return null;
  }

  // ── Plumbing ───────────────────────────────────────────────────────────
  /// GETs JSON and records the call in the API Watcher, so a price source
  /// that has gone away is as diagnosable on-device as a failing own-API call.
  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    developer.log('→ GET $uri', name: 'MetalPrice');
    final sw = Stopwatch()..start();
    try {
      final res = await http.get(uri).timeout(_timeout);
      ApiCallLog.instance.add(ApiCallEntry(
        time: DateTime.now(),
        method: 'GET',
        uri: uri,
        duration: sw.elapsed,
        statusCode: res.statusCode,
        responseBody: res.body,
      ));
      if (res.statusCode >= 400) return null;
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      ApiCallLog.instance.add(ApiCallEntry(
        time: DateTime.now(),
        method: 'GET',
        uri: uri,
        duration: sw.elapsed,
        error: e.toString(),
      ));
      developer.log('✗ GET $uri failed: $e', name: 'MetalPrice', level: 1000);
      return null;
    }
  }
}

/// A price for one metal, in rupiah per gram, with enough provenance for the
/// page to say where it came from and how fresh it is.
class MetalQuote {
  final InvestmentKind kind;
  final double pricePerGram;

  /// Short id stored on the holding, e.g. `anekalogam` or `spot`.
  final String source;

  /// Human-readable provenance, e.g. "Aneka Logam buyback".
  final String label;

  /// When the price itself was quoted — the retailer's recorded date for gold,
  /// the fetch time for spot silver. Not the same as when it was fetched.
  final DateTime quotedAt;

  const MetalQuote({
    required this.kind,
    required this.pricePerGram,
    required this.source,
    required this.label,
    required this.quotedAt,
  });
}

class _GoldRow {
  final double pricePerGram;
  final double weight;
  final bool isBuyback;
  final String recordedDate;
  final String displayName;

  const _GoldRow({
    required this.pricePerGram,
    required this.weight,
    required this.isBuyback,
    required this.recordedDate,
    required this.displayName,
  });
}

double? _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
