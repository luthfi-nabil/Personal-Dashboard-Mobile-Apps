import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'screens/main_shell.dart';
import 'screens/home_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/transactions_screen.dart';
import 'screens/add_transaction_screen.dart';
import 'screens/scan_receipt_screen.dart';
import 'screens/source_detail_screen.dart';
import 'screens/category_detail_screen.dart';
import 'screens/investment_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/export_screen.dart';
import 'screens/options_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/activities_screen.dart';
import 'screens/consumables_screen.dart';
import 'screens/planned_expense_screen.dart';
import 'screens/routine_transaction_screen.dart';
import 'screens/insulin_shell.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/api_log_screen.dart';
import 'screens/pending_sync_screen.dart';
import 'theme/app_theme.dart';
import 'providers/providers.dart';
import 'core/background_sync.dart';
import 'core/config.dart';
import 'core/notifications.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

final _configListenable = ConfigListenable();

final _router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/',
  refreshListenable: _configListenable,
  redirect: (context, state) {
    final cfg = ConfigService.instance.current;
    final loc = state.matchedLocation;
    final isAuthRoute = loc == '/login' || loc == '/server-settings';
    if (!cfg.isLoggedIn && !isAuthRoute) {
      return '/login';
    }
    if (cfg.isLoggedIn && loc == '/login') {
      return '/';
    }
    // Diabetic screens stay routable only while the Health extra feature is
    // on. This also covers deep links and a screen left open when the switch
    // is flipped, since ConfigService drives `refreshListenable`.
    if (loc.startsWith('/insulin') && !cfg.healthEnabled) {
      return '/';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/login',
      builder: (c, s) => const LoginScreen(),
    ),
    GoRoute(
      path: '/server-settings',
      builder: (c, s) => const OnboardingScreen(),
    ),
    ShellRoute(
      navigatorKey: _shellKey,
      builder: (context, state, child) => MainShell(child: child),
      routes: [
        GoRoute(path: '/', builder: (c, s) => const HomeScreen()),
        GoRoute(path: '/dashboard', builder: (c, s) => const DashboardScreen()),
        GoRoute(
            path: '/transactions',
            builder: (c, s) => const TransactionsScreen()),
        GoRoute(
            path: '/investments', builder: (c, s) => const InvestmentScreen()),
        GoRoute(path: '/reports', builder: (c, s) => const ReportsScreen()),
        GoRoute(path: '/export', builder: (c, s) => const ExportScreen()),
        GoRoute(path: '/options', builder: (c, s) => const OptionsScreen()),
        GoRoute(
            path: '/activities', builder: (c, s) => const ActivitiesScreen()),
        GoRoute(
            path: '/consumables', builder: (c, s) => const ConsumablesScreen()),
        GoRoute(
            path: '/planned-expenses',
            builder: (c, s) => const PlannedExpenseScreen()),
        GoRoute(
            path: '/routine-transactions',
            builder: (c, s) => const RoutineTransactionScreen()),
        GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen()),
        GoRoute(path: '/api-log', builder: (c, s) => const ApiLogScreen()),
        GoRoute(
            path: '/pending-sync',
            builder: (c, s) => const PendingSyncScreen()),
      ],
    ),
    GoRoute(
      path: '/insulin',
      builder: (c, s) => const InsulinPage(view: InsulinPageView.home),
    ),
    GoRoute(
      path: '/insulin/activity',
      builder: (c, s) => const InsulinPage(view: InsulinPageView.activity),
    ),
    GoRoute(
      path: '/insulin/reports',
      builder: (c, s) => const InsulinPage(view: InsulinPageView.reports),
    ),
    GoRoute(
      path: '/insulin/add-usage',
      builder: (c, s) => InsulinAddPage(
        kind: InsulinAddKind.usage,
        returnPath: s.uri.queryParameters['returnTo'],
      ),
    ),
    GoRoute(
      path: '/insulin/add-type',
      builder: (c, s) => InsulinAddPage(
        kind: InsulinAddKind.type,
        returnPath: s.uri.queryParameters['returnTo'],
      ),
    ),
    GoRoute(
      path: '/insulin/add-batch',
      builder: (c, s) => InsulinAddPage(
        kind: InsulinAddKind.assign,
        returnPath: s.uri.queryParameters['returnTo'],
      ),
    ),
    GoRoute(
      path: '/insulin/add-blood-sugar',
      builder: (c, s) => InsulinAddPage(
        kind: InsulinAddKind.bloodSugar,
        returnPath: s.uri.queryParameters['returnTo'],
      ),
    ),
    GoRoute(
      parentNavigatorKey: _rootKey,
      path: '/add',
      builder: (c, s) => AddTransactionScreen(
        returnPath: s.uri.queryParameters['returnTo'],
        // Set when arriving from the receipt scanner: pre-fills the amount,
        // description and the confirmed line items.
        draft: s.extra is AddTransactionDraft
            ? s.extra as AddTransactionDraft
            : null,
      ),
    ),
    GoRoute(
      parentNavigatorKey: _rootKey,
      path: '/scan-receipt',
      builder: (c, s) => ScanReceiptScreen(
        returnPath: s.uri.queryParameters['returnTo'],
      ),
    ),
    GoRoute(
      parentNavigatorKey: _rootKey,
      path: '/add/:id',
      builder: (c, s) => AddTransactionScreen(editId: s.pathParameters['id']),
    ),
    GoRoute(
      parentNavigatorKey: _rootKey,
      path: '/source/:name',
      builder: (c, s) => SourceDetailScreen(
          name: Uri.decodeComponent(s.pathParameters['name']!)),
    ),
    GoRoute(
      parentNavigatorKey: _rootKey,
      path: '/category/:name',
      builder: (c, s) => CategoryDetailScreen(
          name: Uri.decodeComponent(s.pathParameters['name']!)),
    ),
  ],
);

class PersonalDashboardApp extends ConsumerStatefulWidget {
  const PersonalDashboardApp({super.key});

  @override
  ConsumerState<PersonalDashboardApp> createState() =>
      _PersonalDashboardAppState();
}

class _PersonalDashboardAppState extends ConsumerState<PersonalDashboardApp>
    with WidgetsBindingObserver {
  /// Keeps [AppForegroundFlag]'s timestamp fresh so a long foreground session
  /// never looks stale to the background worker. Well under the five minutes
  /// after which the flag is ignored.
  static const _heartbeat = Duration(minutes: 2);

  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterForeground();

    NotificationService.instance.onSelect = _openRoutines;
    // A tap that launched the app from cold is not delivered to onSelect -
    // the plugin was not listening yet - so it has to be collected by hand.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final payload = await NotificationService.instance.takeLaunchPayload();
      if (payload != null) _openRoutines(payload);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    NotificationService.instance.onSelect = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _enterForeground();
        // The background worker may have pulled new data into SQLite while
        // the app was away, so show what is actually cached now.
        unawaited(ref.read(appDataProvider.notifier).refreshCached());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _leaveForeground();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Transient - a permission dialog or the app switcher. Treating these
        // as "closed" would let a background sync fight the UI for the
        // database over something as ordinary as pulling down the shade.
        break;
    }
  }

  void _enterForeground() {
    unawaited(AppForegroundFlag.set(true));
    _heartbeatTimer?.cancel();
    _heartbeatTimer =
        Timer.periodic(_heartbeat, (_) => unawaited(AppForegroundFlag.beat()));
  }

  void _leaveForeground() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    unawaited(AppForegroundFlag.set(false));
  }

  void _openRoutines(String? payload) {
    if (payload == null || !payload.startsWith('routine')) return;
    _router.go('/routine-transactions');
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(configProvider);
    return MaterialApp.router(
      routerConfig: _router,
      title: 'Personal Dashboard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.get(cfg.theme),
    );
  }
}
