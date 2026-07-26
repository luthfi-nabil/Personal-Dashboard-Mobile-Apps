import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/utils.dart';
import '../theme/app_theme.dart';

class TxnTile extends StatelessWidget {
  final Transaction t;
  final String currency;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const TxnTile({
    super.key,
    required this.t,
    required this.currency,
    this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final isTransfer = t.type == 'transfer';
    final isEarn = t.type == 'earning';

    final amtColor = isEarn
        ? c.pos
        : isTransfer
            ? c.transfer
            : c.neg;
    final icoColor = amtColor;
    final icoBg = amtColor.withValues(alpha: 0.12);
    final sign = isEarn
        ? '+'
        : isTransfer
            ? ''
            : '−';

    final IconData icon = isTransfer
        ? Icons.swap_horiz_rounded
        : isEarn
            ? Icons.arrow_downward_rounded
            : Icons.arrow_upward_rounded;

    final sub = isTransfer
        ? '${t.fromSource ?? ''} → ${t.toSource ?? ''}'
        : '${t.source ?? ''} · ${t.category ?? ''}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line2, width: 0.5)),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: icoBg, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: icoColor),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.description.isEmpty
                        ? (isTransfer ? 'Transfer' : '—')
                        : t.description,
                    style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: c.ink),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$sub · ${fmtDate(t.date, 'time')}',
                    style: TextStyle(fontSize: 12, color: c.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onTap,
            child: Text(
              '$sign${fmtRp(t.amount, currency).replaceAll('Rp ', '')}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: amtColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              color: c.neg,
              tooltip: 'Delete transaction',
            ),
          ],
        ],
      ),
    );
  }
}
