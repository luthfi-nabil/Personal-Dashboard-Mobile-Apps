import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../theme/app_theme.dart';

final _updates = AppUpdateService.instance;

Future<void> _install(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final opened = await _updates.install();
  if (!opened) {
    messenger.showSnackBar(const SnackBar(
        content: Text('Allow "Install unknown apps" for Personal Dashboard, '
            'then come back and tap Install again.')));
  }
}

/// Strip under the top bar while an update is downloading or waiting to be
/// installed. Hidden otherwise.
class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) {
        final s = _updates.state;
        if (s != AppUpdateState.downloading && s != AppUpdateState.ready) {
          return const SizedBox.shrink();
        }
        final ready = s == AppUpdateState.ready;
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.system_update_outlined, size: 18, color: c.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ready
                          ? 'Version ${_updates.latest?.version} is ready'
                          : 'Downloading version ${_updates.latest?.version}…',
                      style: TextStyle(
                          color: c.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                    if (!ready) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: _updates.progress,
                        color: c.accent,
                        backgroundColor: c.line2,
                      ),
                    ],
                  ],
                ),
              ),
              if (ready)
                TextButton(
                  onPressed: () => _install(context),
                  child: Text('Install',
                      style: TextStyle(
                          color: c.accent, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Settings card: installed version, status, update server, Check now.
class AppUpdateCard extends StatefulWidget {
  const AppUpdateCard({super.key});

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends State<AppUpdateCard> {
  late final _base = TextEditingController(text: _updates.customBase);

  @override
  void dispose() {
    _base.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) {
        final s = _updates.state;
        final supported = AppUpdateService.isSupported;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installed version ${_updates.currentVersion.isEmpty ? '?' : _updates.currentVersion}'
              '${_updates.currentBuild > 0 ? ' (${_updates.currentBuild})' : ''}',
              style: TextStyle(
                  color: c.ink, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(_updates.statusText,
                style: TextStyle(color: c.muted, fontSize: 12, height: 1.35)),
            if (s == AppUpdateState.downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                  value: _updates.progress,
                  color: c.accent,
                  backgroundColor: c.line2),
            ],
            if (supported) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _base,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Update server',
                  hintText: _updates.baseUrl,
                  helperText: 'Empty = Transaction API host, port '
                      '${AppUpdateService.updatePort}',
                  isDense: true,
                ),
                onSubmitted: (v) => _updates.setCustomBase(v),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: s == AppUpdateState.checking ||
                            s == AppUpdateState.downloading
                        ? null
                        : () async {
                            await _updates.setCustomBase(_base.text);
                            await _updates.check(manual: true);
                          },
                    child: Text('Check now', style: TextStyle(color: c.accent)),
                  ),
                  if (s == AppUpdateState.ready)
                    FilledButton(
                      onPressed: () => _install(context),
                      child: const Text('Install'),
                    ),
                  if (s == AppUpdateState.error && _updates.latest != null)
                    TextButton(
                      onPressed: _updates.download,
                      child: Text('Retry download',
                          style: TextStyle(color: c.accent)),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
