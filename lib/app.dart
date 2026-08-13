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
import 'screens/wishlist_screen.dart';
import 'screens/routine_transaction_screen.dart';
import 'screens/insulin_shell.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/api_log_screen.dart';
import 'screens/pending_sync_screen.dart';
import 'theme/app_theme.dart';
import 'providers/providers.dart';
import 'core/config.dart';

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
            builder: (c, s) => const WishlistScreen()),
        GoRoute(path: '/wishlist', builder: (c, s) => const WishlistScreen()),
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

class PersonalDashboardApp extends ConsumerWidget {
  const PersonalDashboardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(configProvider);
    return MaterialApp.router(
      routerConfig: _router,
      title: 'Personal Dashboard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.get(cfg.theme),
    );
  }
}
