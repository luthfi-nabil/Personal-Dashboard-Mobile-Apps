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
    final healthEnabled =
        ref.watch(configProvider.select((cfg) => cfg.healthEnabled));
    final pendingCount = ref.watch(pendingSyncCountProvider);
    final title =
        username.trim().isEmpty ? 'Personal Dashboard' : username.trim();
    final plannedSelected = currentPath.startsWith('/planned-expenses') ||
        currentPath.startsWith('/wishlist');
    final routineSelected = currentPath.startsWith('/routine-transactions');
    final investmentSelected = currentPath.startsWith('/investments');
    final financeSelected = currentPath == '/dashboard' ||
        plannedSelected ||
        routineSelected ||
        investmentSelected;
    final activitiesSelected = currentPath.startsWith('/activities');
    final consumablesSelected = currentPath.startsWith('/consumables');
    final personalSelected = activitiesSelected || consumablesSelected;
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
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _MenuTile(
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home_rounded,
                    label: 'Home',
                    route: '/',
                    selected: currentPath == '/',
                    c: c,
                  ),
                  _MenuGroup(
                    icon: Icons.dashboard_outlined,
                    selectedIcon: Icons.dashboard_rounded,
                    label: 'Finance',
                    childSelected: financeSelected,
                    c: c,
                    children: [
                      _MenuTile(
                        icon: Icons.pie_chart_outline_rounded,
                        selectedIcon: Icons.pie_chart_rounded,
                        label: 'Overview',
                        route: '/dashboard',
                        selected: currentPath == '/dashboard',
                        c: c,
                        indented: true,
                      ),
                      _MenuTile(
                        icon: Icons.trending_up_outlined,
                        selectedIcon: Icons.trending_up_rounded,
                        label: 'Investment',
                        route: '/investments',
                        selected: investmentSelected,
                        c: c,
                        indented: true,
                      ),
                      _MenuTile(
                        icon: Icons.bookmark_border_rounded,
                        selectedIcon: Icons.bookmark_rounded,
                        label: 'Planned Expenses',
                        route: '/planned-expenses',
                        selected: plannedSelected,
                        c: c,
                        indented: true,
                      ),
                      _MenuTile(
                        icon: Icons.repeat_rounded,
                        selectedIcon: Icons.repeat_on_rounded,
                        label: 'Routine Transaction',
                        route: '/routine-transactions',
                        selected: routineSelected,
                        c: c,
                        indented: true,
                      ),
                    ],
                  ),
                  // Hidden while the Health/Diabetic extra feature is switched
                  // off in Settings.
                  if (healthEnabled)
                    _MenuTile(
                      icon: Icons.vaccines_outlined,
                      selectedIcon: Icons.vaccines_rounded,
                      label: 'Diabetic',
                      route: '/insulin',
                      selected: currentPath.startsWith('/insulin'),
                      c: c,
                    ),
                  // Scan Price List is reached from Home, Transactions and the
                  // Add-transaction screen; Export Data from Reports. Neither
                  // is listed here to keep the drawer to top-level
                  // destinations.
                  _MenuGroup(
                    icon: Icons.person_outline_rounded,
                    selectedIcon: Icons.person_rounded,
                    label: 'Personal Things',
                    childSelected: personalSelected,
                    c: c,
                    children: [
                      _MenuTile(
                        icon: Icons.checklist_rounded,
                        selectedIcon: Icons.fact_check_rounded,
                        label: 'Activities',
                        route: '/activities',
                        selected: activitiesSelected,
                        c: c,
                        indented: true,
                      ),
                      _MenuTile(
                        icon: Icons.inventory_2_outlined,
                        selectedIcon: Icons.inventory_2_rounded,
                        label: 'Consumables',
                        route: '/consumables',
                        selected: consumablesSelected,
                        c: c,
                        indented: true,
                      ),
                    ],
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
          ],
        ),
      ),
    );
  }
}

/// Collapsible parent entry. Starts expanded while one of its children is the
/// current destination; after that the user's own expand/collapse is kept in
/// page storage so it survives the drawer being closed and reopened.
class _MenuGroup extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool childSelected;
  final AppColors c;
  final List<Widget> children;

  const _MenuGroup({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.childSelected,
    required this.c,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final color = childSelected ? c.ink : c.muted;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey('menu-group-$label'),
        initiallyExpanded: childSelected,
        leading: Icon(childSelected ? selectedIcon : icon, color: color),
        title: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: childSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        iconColor: c.muted,
        collapsedIconColor: c.muted,
        tilePadding: const EdgeInsets.symmetric(horizontal: 18),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        children: children,
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

  /// Push instead of replacing the location. Needed for routes that live
  /// outside the shell, so the user can close them and land back here.
  final bool push;

  /// Extra leading padding, for tiles nested under a [_MenuGroup].
  final bool indented;

  const _MenuTile({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
    required this.selected,
    required this.c,
    this.trailing,
    this.push = false,
    this.indented = false,
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
      contentPadding: EdgeInsets.only(left: indented ? 34 : 18, right: 18),
      onTap: () {
        Navigator.pop(context);
        if (selected) return;
        if (push) {
          context.push(route);
        } else {
          context.go(route);
        }
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
