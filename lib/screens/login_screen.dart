import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/remote_api.dart';
import '../core/config.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';

/// Login / register screen for login-api. On success the issued JWT is
/// stored in [AppConfig] and sent as a Bearer token to transaction-api /
/// health-api's `/api/user/...` routes.
///
/// With [addAccount] it signs in one more account next to the ones already
/// on the device (see [ConfigService.accounts]); the new one becomes active.
class LoginScreen extends ConsumerStatefulWidget {
  final bool addAccount;

  const LoginScreen({super.key, this.addAccount = false});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _fullNameCtl = TextEditingController();
  final _emailCtl = TextEditingController();
  final _phoneCtl = TextEditingController();
  final _telegramCtl = TextEditingController();

  bool _registerMode = false;
  bool _loading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _usernameCtl.dispose();
    _passwordCtl.dispose();
    _fullNameCtl.dispose();
    _emailCtl.dispose();
    _phoneCtl.dispose();
    _telegramCtl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameCtl.text.trim();
    final password = _passwordCtl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter a username and password.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });

    final cfg = ref.read(configProvider);
    final api = RemoteApi(cfg);
    try {
      if (_registerMode) {
        await api.register(
          username: username,
          password: password,
          email: _emailCtl.text.trim().isEmpty ? null : _emailCtl.text.trim(),
          phoneNumber:
              _phoneCtl.text.trim().isEmpty ? null : _phoneCtl.text.trim(),
          telegramUsername: _telegramCtl.text.trim().isEmpty
              ? null
              : _telegramCtl.text.trim(),
          fullName: _fullNameCtl.text.trim().isEmpty
              ? null
              : _fullNameCtl.text.trim(),
        );
      }

      final auth = await api.login(username: username, password: password);
      // ConfigService notifies configProvider, which rebuilds every screen
      // for the new account's own local data.
      await ConfigService.instance
          .signIn(auth, username: username, password: password);

      if (mounted) context.go('/');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _switchTo(SavedAccount account) async {
    await ConfigService.instance.switchAccount(account.userId);
    if (mounted) context.go('/');
  }

  void _toggleMode() {
    setState(() {
      _registerMode = !_registerMode;
      _error = null;
      _info = _registerMode ? null : _info;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final signedIn = widget.addAccount
        ? ConfigService.instance.accounts
        : const <SavedAccount>[];
    return Scaffold(
      backgroundColor: c.bg,
      appBar: widget.addAccount
          ? AppBar(
              backgroundColor: c.bg,
              elevation: 0,
              leading: IconButton(
                icon: Icon(Icons.close, color: c.ink),
                tooltip: 'Cancel',
                onPressed: () =>
                    context.canPop() ? context.pop() : context.go('/'),
              ),
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: c.ink, borderRadius: BorderRadius.circular(16)),
                    child: Text('PD',
                        style: TextStyle(
                            color: c.bg,
                            fontWeight: FontWeight.w700,
                            fontSize: 18)),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _registerMode
                        ? 'Create an account'
                        : (widget.addAccount
                            ? 'Add another account'
                            : 'Welcome back'),
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: c.ink,
                        letterSpacing: -0.02),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _registerMode
                        ? 'Register with login-api to sync your data.'
                        : (widget.addAccount
                            ? 'Each account keeps its own data on this device.'
                            : 'Sign in with login-api to sync your data.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.muted, fontSize: 13),
                  ),
                  if (signedIn.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('SIGNED IN ON THIS DEVICE',
                        style: TextStyle(
                            color: c.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6)),
                    const SizedBox(height: 6),
                    for (final account in signedIn)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: c.ink,
                          foregroundColor: c.bg,
                          child: Text(account.displayName.isEmpty
                              ? '?'
                              : account.displayName[0].toUpperCase()),
                        ),
                        title: Text(account.displayName,
                            style: TextStyle(color: c.ink)),
                        subtitle: account.fullName.trim().isEmpty
                            ? null
                            : Text('@${account.username}',
                                style: TextStyle(color: c.muted)),
                        trailing: account.userId ==
                                ConfigService.instance.current.userId
                            ? Text('Active',
                                style: TextStyle(color: c.muted, fontSize: 12))
                            : Icon(Icons.chevron_right, color: c.muted),
                        onTap: _loading ? null : () => _switchTo(account),
                      ),
                  ],
                  const SizedBox(height: 24),
                  TextField(
                    controller: _usernameCtl,
                    style: TextStyle(color: c.ink),
                    decoration: const InputDecoration(labelText: 'Username'),
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordCtl,
                    style: TextStyle(color: c.ink),
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    textInputAction: _registerMode
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onSubmitted: (_) => _registerMode ? null : _submit(),
                  ),
                  if (_registerMode) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _fullNameCtl,
                      style: TextStyle(color: c.ink),
                      decoration: const InputDecoration(
                          labelText: 'Full name or alias (optional)',
                          helperText: 'Shown to your group members'),
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _emailCtl,
                      style: TextStyle(color: c.ink),
                      decoration:
                          const InputDecoration(labelText: 'Email (optional)'),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phoneCtl,
                      style: TextStyle(color: c.ink),
                      decoration: const InputDecoration(
                          labelText: 'Phone number (optional)'),
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _telegramCtl,
                      style: TextStyle(color: c.ink),
                      decoration: const InputDecoration(
                          labelText: 'Telegram username (optional)'),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!,
                          style: TextStyle(color: c.neg),
                          textAlign: TextAlign.center),
                    ),
                  if (_info != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_info!,
                          style: TextStyle(color: c.pos),
                          textAlign: TextAlign.center),
                    ),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.ink,
                      foregroundColor: c.bg,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(_loading
                        ? 'Please wait…'
                        : (_registerMode ? 'Register & sign in' : 'Sign in')),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _loading ? null : _toggleMode,
                    child: Text(
                      _registerMode
                          ? 'Already have an account? Sign in'
                          : "Don't have an account? Register",
                      style: TextStyle(color: c.accent),
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => context.push('/server-settings'),
                    child: Text('Server settings',
                        style: TextStyle(color: c.muted)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
