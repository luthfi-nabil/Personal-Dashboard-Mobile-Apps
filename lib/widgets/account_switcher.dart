import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/config.dart';
import '../theme/app_theme.dart';

/// Bottom sheet listing every account signed in on this device. Tapping one
/// makes it active; each account only ever sees its own local data. Also
/// offers to add another account.
Future<void> showAccountSwitcher(BuildContext context) {
  final router = GoRouter.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final c = AppTheme.colorsOf(sheetContext);
      final active = ConfigService.instance.current.userId;
      final accounts = ConfigService.instance.accounts;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Accounts',
                  style: TextStyle(
                      color: c.ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
            ),
            for (final account in accounts)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: account.userId == active ? c.ink : c.line2,
                  foregroundColor: account.userId == active ? c.bg : c.ink,
                  child: Text(account.displayName.isEmpty
                      ? '?'
                      : account.displayName[0].toUpperCase()),
                ),
                title: Text(account.displayName,
                    style: TextStyle(color: c.ink)),
                subtitle: Text(
                    account.fullName.trim().isEmpty
                        ? (account.email.isEmpty ? ' ' : account.email)
                        : '@${account.username}',
                    style: TextStyle(color: c.muted, fontSize: 12)),
                trailing: account.userId == active
                    ? Icon(Icons.check_circle, color: c.accent)
                    : null,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  if (account.userId == active) return;
                  await ConfigService.instance.switchAccount(account.userId);
                  router.go('/');
                },
              ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.person_add_alt_1_outlined, color: c.accent),
              title: Text('Add another account',
                  style: TextStyle(color: c.accent)),
              onTap: () {
                Navigator.pop(sheetContext);
                router.push('/login?add=1');
              },
            ),
          ],
        ),
      );
    },
  );
}
