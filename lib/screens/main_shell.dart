import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';
import '../core/sync.dart';
import '../widgets/app_menu_drawer.dart';

class MainShell extends ConsumerWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final location = GoRouterState.of(context).uri.path;
    final syncStatus = ref.watch(syncStatusProvider);
    final pendingCount = ref.watch(pendingSyncCountProvider);
    final username = ref.watch(configProvider.select((cfg) => cfg.username));

    int currentIndex = -1;
    if (location == '/' || location == '/dashboard') {
      currentIndex = 0;
    } else if (location.startsWith('/transactions')) {
      currentIndex = 1;
    } else if (location.startsWith('/reports')) {
      currentIndex = 2;
    } else if (location.startsWith('/options')) {
      currentIndex = 3;
    } else if (location.startsWith('/activities') ||
        location.startsWith('/pending-sync')) {
      currentIndex = -1;
    }

    return Scaffold(
      backgroundColor: c.bg,
      drawer: AppMenuDrawer(currentPath: location),
      body: Column(
        children: [
          _TopBar(
            username: username,
            syncStatus: syncStatus,
            pendingCount: pendingCount,
            c: c,
          ),
          Expanded(child: child),
        ],
      ),
      floatingActionButton: currentIndex >= 0 &&
              location != '/' &&
              !location.startsWith('/options')
          ? FloatingActionButton(
              onPressed: () => context.push('/add'),
              backgroundColor: c.ink,
              foregroundColor: c.bg,
              elevation: 8,
              child: const Icon(Icons.add, size: 26),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: currentIndex >= 0
          ? _BottomBar(currentIndex: currentIndex, c: c)
          : null,
    );
  }
}

class _TopBar extends StatelessWidget {
  final String username;
  final SyncStatus syncStatus;
  final int pendingCount;
  final AppColors c;
  const _TopBar({
    required this.username,
    required this.syncStatus,
    required this.pendingCount,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final (dot, label) = pendingCount > 0
        ? (c.neg, '$pendingCount pending sync')
        : switch (syncStatus) {
            SyncStatus.syncing => (c.pos.withOpacity(0.6), 'Syncing…'),
            SyncStatus.done => (c.pos, 'Synced'),
            SyncStatus.error => (c.neg, 'Sync error'),
            _ => (c.muted, 'Local only'),
          };

    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: MediaQuery.of(context).padding.top + 8,
        bottom: 10,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.line2, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            margin: const EdgeInsets.only(right: 4),
            child: Builder(
              builder: (context) => IconButton(
                tooltip: 'Menu',
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: Icon(Icons.menu_rounded, color: c.ink),
              ),
            ),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
                color: c.ink, borderRadius: BorderRadius.circular(9)),
            child: Center(
              child: Text('PD',
                  style: TextStyle(
                    color: c.bg,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.04,
                  )),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              username.trim().isEmpty ? 'Personal Dashboard' : username.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 15, color: c.ink),
            ),
          ),
          GestureDetector(
            onTap: () => context.go(
              pendingCount > 0 ? '/pending-sync' : '/settings',
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: c.line, width: 0.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration:
                        BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(color: c.muted, fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int currentIndex;
  final AppColors c;
  const _BottomBar({required this.currentIndex, required this.c});

  @override
  Widget build(BuildContext context) {
    final tabs = [
      (Icons.home_outlined, Icons.home_rounded, 'Home', '/'),
      (Icons.list_outlined, Icons.list_rounded, 'Activity', '/transactions'),
      (
        Icons.bar_chart_outlined,
        Icons.bar_chart_rounded,
        'Reports',
        '/reports'
      ),
      (Icons.tune_outlined, Icons.tune_rounded, 'Options', '/options'),
    ];

    return BottomAppBar(
      color: c.surface.withOpacity(0.95),
      elevation: 0,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            for (int i = 0; i < tabs.length; i++)
              Expanded(
                child: _TabItem(
                  icon: currentIndex == i ? tabs[i].$2 : tabs[i].$1,
                  label: tabs[i].$3,
                  active: currentIndex == i,
                  c: c,
                  onTap: () => context.go(tabs[i].$4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final AppColors c;
  final VoidCallback onTap;
  const _TabItem(
      {required this.icon,
      required this.label,
      required this.active,
      required this.c,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = active ? c.ink : c.muted;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
