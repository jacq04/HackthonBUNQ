import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../services/api.dart';

/// Bottom-sheet form for opening a brand-new pod.
Future<bool> showCreateCircleSheet(BuildContext context) =>
    _showCircleSheet(context, existing: null);

/// Same form, prefilled, for editing an existing pod.
Future<bool> showEditCircleSheet(
  BuildContext context, {
  required Map<String, dynamic> pod,
}) =>
    _showCircleSheet(context, existing: pod);

Future<bool> _showCircleSheet(
  BuildContext context, {
  required Map<String, dynamic>? existing,
}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KittyColors.creamDark,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: KittyRadius.l),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(ctx).viewInsets.bottom,
      ),
      child: _CreateCircleForm(existing: existing),
    ),
  );
  return r == true;
}

class _CreateCircleForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _CreateCircleForm({this.existing});

  @override
  State<_CreateCircleForm> createState() => _CreateCircleFormState();
}

class _CreateCircleFormState extends State<_CreateCircleForm> {
  late final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _theme;
  late final TextEditingController _description;
  late final TextEditingController _cultural;
  late final TextEditingController _amount;
  late final TextEditingController _cycles;
  late final TextEditingController _minTrust;
  late final TextEditingController _debitDay;
  late String _strategy;
  bool _busy = false;
  bool _amountLocked = false;
  bool _cyclesLocked = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(
      text: (e?['name'] as String?) ?? 'Lagos Crew',
    );
    _theme = TextEditingController(
      text: (e?['theme'] as String?) ?? 'small business',
    );
    _description = TextEditingController(
      text: (e?['description'] as String?) ??
          'A 6-month rotation for traders saving for restock.',
    );
    _cultural = TextEditingController(
      text: (e?['cultural_hint'] as String?) ?? '',
    );
    final amt = (e?['contribution_amount_cents'] as int?);
    _amount = TextEditingController(
      text: amt != null ? (amt / 100).toStringAsFixed(0) : '250',
    );
    _cycles = TextEditingController(
      text: '${e?['cycle_count'] ?? 6}',
    );
    _minTrust = TextEditingController(
      text: '${e?['min_trust_score'] ?? 50}',
    );
    _debitDay = TextEditingController(
      text: '${e?['debit_day'] ?? 1}',
    );
    _strategy = (e?['payout_strategy'] as String?) ?? 'rotation';
    // Lock the money-shape fields once the pod has members or contributions.
    _amountLocked =
        _isEdit && ((e?['contributions_posted'] ?? 0) as int) > 0;
    _cyclesLocked =
        _isEdit && ((e?['members_total'] ?? 0) as int) > 0;
  }

  @override
  void dispose() {
    _name.dispose();
    _theme.dispose();
    _description.dispose();
    _cultural.dispose();
    _amount.dispose();
    _cycles.dispose();
    _minTrust.dispose();
    _debitDay.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'theme': _theme.text.trim().isEmpty ? null : _theme.text.trim(),
        'description': _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        'cultural_hint':
            _cultural.text.trim().isEmpty ? null : _cultural.text.trim(),
        'debit_day': int.parse(_debitDay.text.trim()),
        'min_trust_score': int.parse(_minTrust.text.trim()),
        'payout_strategy': _strategy,
      };
      if (!_amountLocked) {
        body['contribution_amount_cents'] =
            (double.parse(_amount.text.trim()) * 100).round();
      }
      if (!_cyclesLocked) {
        body['cycle_count'] = int.parse(_cycles.text.trim());
      }
      if (_isEdit) {
        await KittyApi().adminUpdateCircle(
          widget.existing!['id'] as String,
          body,
        );
      } else {
        body['currency'] = 'EUR';
        body['grace_period_days'] = 3;
        body['penalty_bps'] = 200;
        body['accept_deadline_hours'] = 48;
        await KittyApi().adminCreateCircle(body);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: KittyColors.dusk.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Center(
                child: Text(_isEdit ? 'edit pod' : 'open a pod',
                    style: t.headlineSmall?.copyWith(color: KittyColors.bowl)),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  _isEdit
                      ? 'changes apply immediately'
                      : 'Matchmaker will fill it from the waitlist',
                  style: t.bodySmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _Field(
                label: 'name',
                controller: _name,
                validator: (v) => v == null || v.trim().isEmpty ? 'required' : null,
              ),
              const SizedBox(height: 12),
              _Field(label: 'theme', controller: _theme, hint: 'tuition · wedding · small biz · emergency fund'),
              const SizedBox(height: 12),
              _Field(
                label: 'description',
                controller: _description,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              _Field(
                label: 'cultural hint (optional)',
                controller: _cultural,
                hint: 'Lagos · Lisbon · Bay-area Filipino · etc.',
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      label: _amountLocked
                          ? 'contribution € (locked — has payments)'
                          : 'contribution €',
                      controller: _amount,
                      enabled: !_amountLocked,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      validator: (v) {
                        final d = double.tryParse(v ?? '');
                        if (d == null || d < 1) return '≥ 1';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: _cyclesLocked
                          ? 'cycles (locked — has members)'
                          : 'cycles',
                      controller: _cycles,
                      enabled: !_cyclesLocked,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 2 || n > 24) return '2–24';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      label: 'min trust score',
                      controller: _minTrust,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      hint: '0–100',
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 0 || n > 100) return '0–100';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: 'debit day',
                      controller: _debitDay,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 1 || n > 28) return '1–28';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SegmentedField(
                label: 'payout strategy',
                value: _strategy,
                options: const [
                  ('rotation', 'rotation'),
                  ('bidding', 'bidding'),
                  ('hybrid', 'hybrid'),
                ],
                onChanged: (v) => setState(() => _strategy = v),
              ),
              const SizedBox(height: 22),
              CoralButton(
                label: _busy
                    ? (_isEdit ? 'saving…' : 'opening…')
                    : (_isEdit ? 'save changes' : 'open pod'),
                hero: true,
                onPressed: _busy ? () {} : _submit,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final int maxLines;
  final bool enabled;
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
    this.maxLines = 1,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              letterSpacing: 1.0,
            )),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          maxLines: maxLines,
          enabled: enabled,
          style: t.bodyMedium?.copyWith(
            color: enabled ? KittyColors.dusk : KittyColors.dusk.withValues(alpha: 0.5),
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: t.bodySmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.4),
            ),
            isDense: true,
            filled: true,
            fillColor: KittyColors.soft.withValues(alpha: 0.55),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(KittyRadius.s),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}

class _SegmentedField extends StatelessWidget {
  final String label;
  final String value;
  final List<(String, String)> options;
  final ValueChanged<String> onChanged;
  const _SegmentedField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              letterSpacing: 1.0,
            )),
        const SizedBox(height: 6),
        Row(
          children: options.map((o) {
            final selected = o.$1 == value;
            return Expanded(
              child: GestureDetector(
                onTap: () => onChanged(o.$1),
                child: AnimatedContainer(
                  duration: KittyDurations.short,
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selected
                        ? KittyColors.coral
                        : KittyColors.soft.withValues(alpha: 0.55),
                    borderRadius: const BorderRadius.all(KittyRadius.s),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    o.$2,
                    style: t.labelLarge?.copyWith(
                      color: selected ? KittyColors.cream : KittyColors.bowl,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
