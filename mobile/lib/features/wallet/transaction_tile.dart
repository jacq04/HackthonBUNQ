import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/tokens.dart';

class TransactionTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  const TransactionTile({super.key, required this.tx});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final amt = (tx['amount_cents'] ?? 0) as int;
    final isCredit = amt >= 0;
    final currency = tx['currency'] ?? 'EUR';
    final name = (tx['counterparty_name'] ?? '').toString().trim();
    final desc = (tx['description'] ?? '').toString().trim();
    final subtitle = desc.isEmpty
        ? (name.isEmpty ? 'unknown' : name)
        : desc;
    final created = tx['created'] as String?;
    final when = _prettyTime(created);

    final fmt = NumberFormat.currency(
      locale: 'en_EU',
      symbol: currency == 'EUR' ? '€' : '$currency ',
      decimalDigits: 2,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Row(
        children: [
          _Glyph(name: name.isEmpty ? desc : name, isCredit: isCredit),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'bunq' : name,
                  style: t.titleSmall?.copyWith(
                    color: KittyColors.dusk,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$subtitle  ·  $when',
                  style: t.bodySmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.5),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${isCredit ? '+' : '−'}${fmt.format(amt.abs() / 100)}',
            style: t.titleMedium?.copyWith(
              color: isCredit ? KittyColors.moss : KittyColors.dusk,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _prettyTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso.replaceAll(' ', 'T'));
      final now = DateTime.now();
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        return DateFormat.Hm().format(dt);
      }
      return DateFormat.MMMd().format(dt);
    } catch (_) {
      return '';
    }
  }
}

class _Glyph extends StatelessWidget {
  final String name;
  final bool isCredit;
  const _Glyph({required this.name, required this.isCredit});

  @override
  Widget build(BuildContext context) {
    final seed = name.isEmpty ? 0 : name.codeUnitAt(0) + name.length * 7;
    final hue = (seed * 37) % 360;
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(0.14, hue.toDouble(), 0.5, 0.4).toColor(),
        shape: BoxShape.circle,
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.32).toColor(),
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
