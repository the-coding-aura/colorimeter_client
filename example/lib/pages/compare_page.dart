import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../main.dart';
import '../widgets.dart';

class ComparePage extends StatelessWidget {
  const ComparePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.connection.isConnected;
    final cmp = state.comparison;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SlotCard(
          title: 'Standard',
          ref: state.standard,
          armed: state.armedSlot == CompareSlot.standard,
          onScan: connected ? () => state.measure(slot: CompareSlot.standard) : null,
          onInput: () => _inputStandard(context),
          onPick: () => _pick(context, CompareSlot.standard),
        ),
        _SlotCard(
          title: 'Sample',
          ref: state.sample,
          armed: state.armedSlot == CompareSlot.sample,
          onScan: connected ? () => state.measure(slot: CompareSlot.sample) : null,
          onPick: () => _pick(context, CompareSlot.sample),
        ),
        const SizedBox(height: 8),
        _QcSettingsCard(settings: state.qc, onChanged: state.setQc),
        if (cmp != null) _ResultCard(cmp),
      ],
    );
  }

  Future<void> _inputStandard(BuildContext context) async {
    final state = AppScope.of(context);
    final result = await showDialog<ColorReference>(
      context: context,
      builder: (_) => const _InputStandardDialog(),
    );
    if (result != null) state.setCompareColor(CompareSlot.standard, result);
  }

  Future<void> _pick(BuildContext context, CompareSlot slot) async {
    final state = AppScope.of(context);
    final folders = await state.myColors.getFolders();
    final colors = [for (final f in folders) ...await state.myColors.getColors(f.id)];
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<ColorReference>(
      context: context,
      builder: (context) => ListView(
        children: [
          const ListTile(title: Text('My Colors')),
          for (final c in colors)
            ListTile(
              leading: Swatch(c.previewRgb, size: 32),
              title: Text(c.name),
              onTap: () => Navigator.pop(context, c.toReference()),
            ),
          for (final chart in state.charts) ...[
            ListTile(title: Text(chart.name)),
            for (final c in chart.colors)
              ListTile(
                leading: Swatch(ColorConversions.labToRgb(c.lab), size: 32),
                title: Text('${c.code} ${c.name ?? ''}'),
                onTap: () => Navigator.pop(context, ColorReference(lab: c.lab, name: c.code)),
              ),
          ],
        ],
      ),
    );
    if (picked != null) state.setCompareColor(slot, picked);
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.title,
    required this.ref,
    required this.armed,
    required this.onScan,
    required this.onPick,
    this.onInput,
  });

  final String title;
  final ColorReference? ref;
  final bool armed;
  final VoidCallback? onScan;
  final VoidCallback onPick;
  final VoidCallback? onInput;

  @override
  Widget build(BuildContext context) {
    final r = ref;
    return Card(
      shape: armed
          ? RoundedRectangleBorder(
              side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (r != null)
                  Swatch(r.measurement?.rgb ?? ColorConversions.labToRgb(r.lab), size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    r == null
                        ? '$title: not set'
                        : '$title${r.name == null ? '' : ' (${r.name})'}\n'
                              'L ${f2(r.lab.l)}  a ${f2(r.lab.a)}  b ${f2(r.lab.b)}',
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(onPressed: onScan, child: Text('Scan $title')),
                if (onInput != null) TextButton(onPressed: onInput, child: const Text('Input')),
                TextButton(onPressed: onPick, child: const Text('Add from list')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QcSettingsCard extends StatelessWidget {
  const _QcSettingsCard({required this.settings, required this.onChanged});

  final QcSettings settings;
  final ValueChanged<QcSettings> onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          DropdownButtonFormField<DeltaEFormula>(
            initialValue: settings.formula,
            decoration: const InputDecoration(labelText: 'ΔE formula'),
            items: [
              for (final f in DeltaEFormula.values)
                DropdownMenuItem(value: f, child: Text(f.label)),
            ],
            onChanged: (f) => onChanged(settings.copyWith(formula: f)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('QC testing'),
            value: settings.enabled,
            onChanged: (v) => onChanged(settings.copyWith(enabled: v)),
          ),
          if (settings.enabled)
            Row(
              children: [
                const Text('Threshold'),
                Expanded(
                  child: Slider(
                    min: QcSettings.minThreshold,
                    max: QcSettings.maxThreshold,
                    divisions: 499,
                    value: settings.threshold.clamp(
                      QcSettings.minThreshold,
                      QcSettings.maxThreshold,
                    ),
                    label: settings.threshold.toStringAsFixed(1),
                    onChanged: (v) => onChanged(
                      QcSettings.lenient(
                        formula: settings.formula,
                        threshold: double.parse(v.toStringAsFixed(1)),
                      ),
                    ),
                  ),
                ),
                Text(settings.threshold.toStringAsFixed(1)),
              ],
            ),
        ],
      ),
    ),
  );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard(this.cmp);

  final ColorComparison cmp;

  @override
  Widget build(BuildContext context) {
    final d = cmp.difference;
    final verdict = cmp.verdict;
    String dir(double v, String plus, String minus) =>
        v.abs() < 0.005 ? '' : (v > 0 ? plus : minus);
    return Card(
      color: switch (verdict) {
        QcVerdict.pass => Colors.green.shade50,
        QcVerdict.ng => Colors.red.shade50,
        null => null,
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${d.formula.label} = ${f2(d.deltaE)}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const Spacer(),
                if (verdict != null)
                  Text(
                    verdict == QcVerdict.pass ? 'PASS' : 'NG',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: verdict == QcVerdict.pass ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('ΔL ${f2(d.dL)} ${dir(d.dL, 'lighter', 'darker')}'),
            Text('Δa ${f2(d.da)} ${dir(d.da, 'redder', 'greener')}'),
            Text('Δb ${f2(d.db)} ${dir(d.db, 'yellower', 'bluer')}'),
            Text('ΔC ${f2(d.dC)}   ΔH ${f2(d.dH)}'),
          ],
        ),
      ),
    );
  }
}

class _InputStandardDialog extends StatefulWidget {
  const _InputStandardDialog();

  @override
  State<_InputStandardDialog> createState() => _InputStandardDialogState();
}

class _InputStandardDialogState extends State<_InputStandardDialog> {
  bool _lch = false;
  final _c = [TextEditingController(), TextEditingController(), TextEditingController()];
  final _name = TextEditingController();

  @override
  void dispose() {
    for (final c in [..._c, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = _lch ? ['L', 'C', 'h'] : ['L*', 'a*', 'b*'];
    return AlertDialog(
      title: const Text('Input standard'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Lab')),
              ButtonSegment(value: true, label: Text('LCh')),
            ],
            selected: {_lch},
            onSelectionChanged: (s) => setState(() => _lch = s.single),
          ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          for (var i = 0; i < 3; i++)
            TextField(
              controller: _c[i],
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(labelText: labels[i]),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Use')),
      ],
    );
  }

  void _submit() {
    final v = [for (final c in _c) double.tryParse(c.text.trim().replaceAll(',', '.'))];
    if (v.any((x) => x == null)) return;
    final name = _name.text.trim().isEmpty ? null : _name.text.trim();
    Navigator.pop(
      context,
      _lch
          ? ColorReference.fromLch(LCh(v[0]!, v[1]!, v[2]!), name: name)
          : ColorReference(lab: Lab(v[0]!, v[1]!, v[2]!), name: name),
    );
  }
}
