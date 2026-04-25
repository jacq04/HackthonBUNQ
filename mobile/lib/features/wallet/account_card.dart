import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/pod_colors.dart';

/// Hero account card — bold duotone gradient, huge tabular-figure balance,
/// IBAN in monospace. Mimics the bunq app's account-card slab.
class AccountCard extends StatelessWidget {
  final String description;
  final String? iban;
  final int balanceCents;
  final String currency;
  final int paletteIndex;
  final double width;
  final double height;

  const AccountCard({
    super.key,
    required this.description,
    required this.iban,
    required this.balanceCents,
    required this.currency,
    required this.paletteIndex,
    this.width = 320,
    this.height = 200,
  });

  @override
  Widget build(BuildContext context) {
    final palette = paletteFor(paletteIndex);
    final fmt = NumberFormat.currency(
      locale: 'en_EU',
      symbol: currency == 'EUR' ? '€' : '$currency ',
      decimalDigits: 2,
    );
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: palette.gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.all(KittyRadius.xl),
        boxShadow: KittyShadows.lift,
      ),
      child: Stack(
        children: [
          // subtle radial sheen
          Positioned(
            right: -40,
            top: -40,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    description.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.8),
                          letterSpacing: 1.4,
                        ),
                  ),
                  Icon(
                    Icons.contactless_rounded,
                    size: 20,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                fmt.format(balanceCents / 100),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      letterSpacing: -1.2,
                    ),
              ),
              const SizedBox(height: 10),
              if (iban != null)
                Text(
                  _formatIban(iban!),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontFamilyFallback: const ['Menlo', 'Courier New'],
                        letterSpacing: 1.6,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatIban(String iban) {
    final s = iban.replaceAll(' ', '');
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
