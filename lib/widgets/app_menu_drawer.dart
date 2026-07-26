import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/providers.dart';
import '../theme/app_theme.dart';

class AppMenuDrawer extends ConsumerWidget {
  final String currentPath;

  const AppMenuDrawer({super.key, required this.currentPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final username = ref.watch(configProvider.select((cfg) => cfg.username));
    final pendingCount = ref.watch(pendingSyncCountProvider);
    final title =
        username.trim().isEmpty ? 'Personal Dashboard' : username.trim();
    return Drawer(
      backgroundColor: c.bg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.ink,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Center(
                      child: Text(
                        'PD',
                        style: TextStyle(
                          color: c.bg,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: c.line2, height: 1),
            _MenuTile(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: 'Home',
              route: '/',
              selected: currentPath == '/',
              c: c,
            ),
            _MenuTile(
              icon: Icons.dashboard_outlined,
              selectedIcon: Icons.dashboard_rounded,
              label: 'Finance',
              route: '/dashboard',
              selected: currentPath == '/dashboard',
              c: c,
            ),
            _MenuTile(
              icon: Icons.vaccines_outlined,
              selectedIcon: Icons.vaccines_rounded,
              label: 'Diabetic',
              route: '/insulin',
              selected: currentPath.startsWith('/insulin'),
              c: c,
            ),
            _MenuTile(
              icon: Icons.checklist_rounded,
              selectedIcon: Icons.fact_check_rounded,
              label: 'Activities',
              route: '/activities',
              selected: currentPath.startsWith('/activities'),
              c: c,
            ),
            _MenuTile(
              icon: Icons.bookmark_border_rounded,
              selectedIcon: Icons.bookmark_rounded,
              label: 'Planned Expenses',
              route: '/planned-expenses',
              selected: currentPath.startsWith('/planned-expenses') ||
                  currentPath.startsWith('/wishlist'),
              c: c,
            ),
            _MenuTile(
              icon: Icons.repeat_rounded,
              selectedIcon: Icons.repeat_on_rounded,
              label: 'Routine Transaction',
              route: '/routine-transactions',
              selected: currentPath.startsWith('/routine-transactions'),
              c: c,
            ),
            _MenuTile(
              icon: Icons.sync_outlined,
              selectedIcon: Icons.sync_rounded,
              label: 'Pending Sync',
              route: '/pending-sync',
              selected: currentPath.startsWith('/pending-sync'),
              c: c,
              trailing: pendingCount > 0
                  ? _CountBadge(count: pendingCount, c: c)
                  : null,
            ),
            _MenuTile(
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings_rounded,
              label: 'Settings',
              route: '/settings',
              selected: currentPath == '/settings',
              c: c,
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String route;
  final bool selected;
  final AppColors c;
  final Widget? trailing;

  const _MenuTile({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
    required this.selected,
    required this.c,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? c.ink : c.muted;
    return ListTile(
      leading: Icon(selected ? selectedIcon : icon, color: color),
      trailing: trailing,
      title: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      selected: selected,
      selectedTileColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18),
      onTap: () {
        Navigator.pop(context);
        if (!selected) context.go(route);
      },
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final AppColors c;

  const _CountBadge({required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.neg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: c.neg,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
