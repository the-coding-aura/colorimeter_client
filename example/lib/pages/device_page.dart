import 'package:colorimeter_client/colorimeter_client.dart';
import 'package:flutter/material.dart';

import '../main.dart';

class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.connection.isConnected;
    final status = state.connection.status;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Demo mode'),
          subtitle: const Text('Use a simulated LS170 instead of Bluetooth'),
          value: state.demoMode,
          onChanged: state.setDemoMode,
        ),
        const Divider(),
        if (!connected) ...[
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: state.scanning ? state.stopScan : state.scan,
                  icon: Icon(state.scanning ? Icons.stop : Icons.search),
                  label: Text(state.scanning ? 'Stop scan' : 'Scan for LS170 / LS171'),
                ),
              ),
            ],
          ),
          if (state.scanning) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          for (final d in state.devices)
            Card(
              child: ListTile(
                leading: _SignalIcon(d.signalQuality),
                title: Text(d.name),
                subtitle: Text(
                  '${d.id}  •  ${d.smoothedRssi?.round() ?? '–'} dBm (${d.signalQuality.name})',
                ),
                trailing: status == ColorimeterConnectionStatus.connecting
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () => state.connect(d),
              ),
            ),
          if (status == ColorimeterConnectionStatus.reconnecting)
            ListTile(
              leading: const CircularProgressIndicator(),
              title: Text('Reconnecting (attempt ${state.connection.attempt})…'),
              trailing: TextButton(onPressed: state.disconnect, child: const Text('Cancel')),
            ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Only one app can connect at a time. Close LScolor before scanning.'),
          ),
        ] else ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.bluetooth_connected),
              title: Text(state.client.connectedDevice?.name ?? state.connection.deviceId ?? ''),
              subtitle: Text('MTU ${state.connection.mtu ?? '?'}'),
              trailing: OutlinedButton(
                onPressed: state.disconnect,
                child: const Text('Disconnect'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: state.busy ? null : () => _confirmCalibrate(context),
                icon: const Icon(Icons.tune),
                label: const Text('Calibrate'),
              ),
              FilledButton.tonalIcon(
                onPressed: state.busy ? null : state.readBattery,
                icon: const Icon(Icons.battery_std),
                label: const Text('Battery'),
              ),
              FilledButton.tonalIcon(
                onPressed: state.busy ? null : state.readDeviceInfo,
                icon: const Icon(Icons.info),
                label: const Text('Device info'),
              ),
            ],
          ),
          if (state.calibration != null)
            ListTile(
              leading: Icon(
                state.calibration!.isSuccess ? Icons.check_circle : Icons.error,
                color: state.calibration!.isSuccess ? Colors.green : Colors.red,
              ),
              title: Text('Calibration ${state.calibration!.status.name}'),
            ),
          if (state.battery != null)
            ListTile(
              leading: const Icon(Icons.battery_std),
              title: Text(
                state.battery!.percent != null
                    ? 'Battery ${state.battery!.percent}%'
                    : 'Battery raw value ${state.battery!.rawValue}',
              ),
              subtitle: const Text('Battery scale is not verified on hardware yet'),
            ),
          if (state.deviceInfo != null) _DeviceInfoCard(state.deviceInfo!),
        ],
      ],
    );
  }

  Future<void> _confirmCalibrate(BuildContext context) async {
    final state = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calibrate'),
        content: const Text('Close the bottom cap (white tile) of the colorimeter, then continue.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Calibrate'),
          ),
        ],
      ),
    );
    if (ok ?? false) await state.calibrate();
  }
}

class _SignalIcon extends StatelessWidget {
  const _SignalIcon(this.quality);

  final SignalQuality quality;

  @override
  Widget build(BuildContext context) => Icon(switch (quality) {
    SignalQuality.excellent => Icons.signal_cellular_alt,
    SignalQuality.good => Icons.signal_cellular_alt_2_bar,
    SignalQuality.fair => Icons.signal_cellular_alt_1_bar,
    SignalQuality.weak => Icons.signal_cellular_0_bar,
    SignalQuality.unknown => Icons.signal_cellular_null,
  });
}

class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard(this.info);

  final DeviceInfo info;

  @override
  Widget build(BuildContext context) {
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device info', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Model: ${info.model?.namePrefix ?? '–'}'),
            Text('Serial number: ${info.serialNumber ?? '–'}'),
            Text('Address: ${info.deviceId}'),
            Text('Firmware: ${info.firmwareVersion ?? 'not decoded yet'}'),
            if (info.printableStrings.isNotEmpty)
              Text('Text in frame: ${info.printableStrings.join(' | ')}'),
            const SizedBox(height: 8),
            SelectableText(
              hex(info.rawFrame),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
