import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';
import '../link/link_controller.dart';
import '../link/models.dart';
import '../theme/zeph_colors.dart';
import '../widgets/widgets.dart';

/// Opens the Devices page (pairing and paired devices).
void openDevices(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
  );
}

IconData _platformIcon(String platform) {
  switch (platform) {
    case 'android':
      return Icons.smartphone_rounded;
    case 'windows':
      return Icons.desktop_windows_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

String _platformLabel(String platform) {
  switch (platform) {
    case 'android':
      return 'Android';
    case 'windows':
      return 'Windows';
    default:
      return 'Device';
  }
}

void _toast(ScaffoldMessengerState messenger, String text) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Devices: this device and its address, connect to another one, and the
/// devices already paired.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Timer? _clock;
  LinkController? _link;

  @override
  void initState() {
    super.initState();
    // Keeps the "expires in" countdown moving.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_link == null) {
      final link = AppScope.linkOf(context);
      _link = link;
      link.addListener(_onLink);
      // Look for devices more often while this page is open. Done after the
      // first frame so the rebuild does not happen in the middle of building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) link.setFastScan(true);
      });
    }
  }

  void _onLink() {
    final link = _link;
    if (link == null || !mounted) return;
    final message = link.takeEvent();
    if (message != null) _toast(ScaffoldMessenger.of(context), message);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _link?.removeListener(_onLink);
    _link?.setFastScan(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = AppScope.linkOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListenableBuilder(
              listenable: link,
              builder: (context, _) {
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: gapped([
                    _ThisDeviceCard(link: link),
                    _ConnectCard(link: link),
                    _PairedCard(link: link),
                  ]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// This device and its address
// ---------------------------------------------------------------------------

class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.link});

  final LinkController link;

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: link.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name this device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'For example Studio-PC'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null) await link.rename(name);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final address = link.primaryAddress;
    final others = link.localAddresses.skip(1).toList();

    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                isPhonePlatform
                    ? Icons.smartphone_rounded
                    : Icons.desktop_windows_rounded,
                color: cs.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(link.deviceName, style: tt.titleMedium),
                    Text(
                      'This device',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _rename(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: address == null
                ? Text(
                    'No Wi-Fi found. Connect this device to Wi-Fi, or turn on a hotspot.',
                    style:
                        tt.bodyMedium?.copyWith(color: cs.onPrimaryContainer),
                  )
                : Row(
                    children: [
                      Icon(Icons.wifi_rounded, color: cs.onPrimaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Your address on this Wi-Fi',
                              style: tt.labelMedium?.copyWith(
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                            SelectableText(
                              address,
                              style: tt.headlineSmall?.copyWith(
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                            if (others.isNotEmpty)
                              Text(
                                'Also: ${others.join(', ')}',
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy address',
                        icon: Icon(Icons.copy_rounded,
                            color: cs.onPrimaryContainer),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await Clipboard.setData(ClipboardData(text: address));
                          _toast(messenger, 'Address copied');
                        },
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connect: show a code, or enter a code
// ---------------------------------------------------------------------------

class _ConnectCard extends StatefulWidget {
  const _ConnectCard({required this.link});

  final LinkController link;

  @override
  State<_ConnectCard> createState() => _ConnectCardState();
}

class _ConnectCardState extends State<_ConnectCard> {
  final TextEditingController _ip = TextEditingController();
  final TextEditingController _code = TextEditingController();
  int _mode = 1; // 0 = show my code, 1 = enter a code
  bool _busy = false;

  @override
  void dispose() {
    _ip.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await widget.link.pairWithAddress(_ip.text, _code.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error == null) {
      _code.clear();
      _toast(messenger, widget.link.takeEvent() ?? 'Paired');
    } else {
      _toast(messenger, error);
    }
  }

  Future<void> _connectNearby(NearbyDevice device) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await widget.link.pairNearby(device);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(messenger, error ?? widget.link.takeEvent() ?? 'Paired');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardHeader('Connect to another device'),
          Text(
            'Open Zephlink on both devices on the same Wi-Fi. On one, show a code. '
            'On the other, enter its address and that code. '
            'Both devices approve this first pairing. Trusted reconnects do not ask again.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment<int>(
                value: 0,
                icon: Icon(Icons.pin_outlined),
                label: Text('Show my code'),
              ),
              ButtonSegment<int>(
                value: 1,
                icon: Icon(Icons.keyboard_outlined),
                label: Text('Enter a code'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) =>
                setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 16),
          if (_mode == 0) _showCode(context) else _enterCode(context),
        ],
      ),
    );
  }

  Widget _showCode(BuildContext context) {
    final link = widget.link;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final window = link.pairing;

    if (window == null) {
      return FilledButton.icon(
        onPressed: link.startPairing,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Create a code'),
      );
    }
    final address = link.primaryAddress;
    final left = window.remaining;
    final qrPayload = link.pairingQrPayload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              Text(
                '${window.pin.substring(0, 3)} ${window.pin.substring(3)}',
                style: tt.displaySmall?.copyWith(
                  color: cs.onSecondaryContainer,
                  letterSpacing: 4,
                ),
              ),
              if (address != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Address: $address',
                  style:
                      tt.titleMedium?.copyWith(color: cs.onSecondaryContainer),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                'Expires in ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                style: tt.bodySmall?.copyWith(color: cs.onSecondaryContainer),
              ),
            ],
          ),
        ),
        if (qrPayload != null) ...[
          const SizedBox(height: 12),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: qrPayload,
                version: QrVersions.auto,
                size: 190,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan this QR code from Zephlink on the other phone. '
            'Compare the verification codes and approve the first pairing on both devices.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'On the other device choose "Enter a code", type this address and code, '
          'then tap Connect. Both devices will ask you to approve the first pairing.',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
                onPressed: link.startPairing, child: const Text('New code')),
            TextButton(
                onPressed: link.cancelPairing, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }

  Widget _enterCode(BuildContext context) {
    final link = widget.link;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final unpaired = link.nearby
        .where((device) => !link.pairedPeers.any((p) => p.id == device.id))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (Platform.isAndroid) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _scanQr,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan Zephlink QR code'),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _ip,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Address of the other device',
            hintText: '192.168.1.5',
            helperText: 'Shown on the other device under "Your address".',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          maxLength: 6,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '6-digit code',
            border: OutlineInputBorder(),
          ),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link_rounded),
          label: Text(_busy ? 'Waiting for approval…' : 'Connect'),
        ),
        if (_busy) ...[
          const SizedBox(height: 8),
          Text(
            'Approve this first pairing on both devices. Reconnects to this trusted device are automatic.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Text('Found on this Wi-Fi', style: tt.titleSmall)),
            TextButton.icon(
              onPressed: link.scanning ? null : link.scanNow,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Scan again'),
            ),
          ],
        ),
        if (link.scanning) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            'Scanning your Wi-Fi…',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        if (unpaired.isEmpty && !link.scanning)
          Text(
            'No devices found yet. Check that Zephlink is open on the other device '
            'and that both are on the same Wi-Fi. Guest networks and some routers '
            'hide devices from each other; a phone hotspot always works. '
            'On Windows, allow Zephlink through the firewall when asked '
            '(Private networks). You can also just type its address above.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        for (final device in unpaired)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_platformIcon(device.platform), color: cs.primary),
            title: Text(device.name),
            subtitle: Text(
              '${_platformLabel(device.platform)} · ${device.address.address}',
            ),
            trailing: FilledButton.tonal(
              onPressed: _busy ? null : () => _connectNearby(device),
              child: Text(_busy ? 'Connecting…' : 'Connect'),
            ),
          ),
      ],
    );
  }

  Future<void> _scanQr() async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const _PairQrScannerScreen(),
      ),
    );
    if (!mounted || payload == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await widget.link.pairFromQr(payload);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(messenger, error ?? 'Pairing approved and device remembered.');
  }
}

class _PairQrScannerScreen extends StatefulWidget {
  const _PairQrScannerScreen();

  @override
  State<_PairQrScannerScreen> createState() => _PairQrScannerScreenState();
}

class _PairQrScannerScreenState extends State<_PairQrScannerScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan pairing QR code')),
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Scan a QR code shown by the device you want to pair.',
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: MobileScanner(
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Camera unavailable: ${error.errorCode.name}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Paired devices
// ---------------------------------------------------------------------------

class _PairedCard extends StatelessWidget {
  const _PairedCard({required this.link});

  final LinkController link;

  Future<void> _connect(BuildContext context, PairedPeer peer) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await link.connectPeer(peer);
    if (error != null) _toast(messenger, error);
  }

  Future<void> _forget(BuildContext context, PairedPeer peer) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Forget ${peer.name}?'),
        content: const Text(
          'You will need to pair again to link these devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (sure == true) await link.forget(peer.id);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final peers = link.pairedPeers;

    return ZCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardHeader('Trusted devices'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Their identity is pinned. After both devices approve the first pairing, '
              'future connections verify automatically without another prompt.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          if (peers.isEmpty)
            Text(
              'Nothing paired yet.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            )
          else
            for (final peer in peers)
              _PairedRow(
                peer: peer,
                link: link,
                onConnect: () => _connect(context, peer),
                onForget: () => _forget(context, peer),
              ),
        ],
      ),
    );
  }
}

class _PairedRow extends StatelessWidget {
  const _PairedRow({
    required this.peer,
    required this.link,
    required this.onConnect,
    required this.onForget,
  });

  final PairedPeer peer;
  final LinkController link;
  final VoidCallback onConnect;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = link.activePeer?.id == peer.id;
    final nearby = link.isNearby(peer.id);
    final status = connected
        ? 'Connected · ${link.latencyText}'
        : (nearby ? 'On this Wi-Fi' : 'Not found on this Wi-Fi');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        _platformIcon(peer.platform),
        color: connected ? cs.success : cs.onSurfaceVariant,
      ),
      title: Text(peer.name),
      subtitle: Text('${_platformLabel(peer.platform)} · $status'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (connected)
            TextButton(
              onPressed: link.disconnect,
              child: const Text('Disconnect'),
            )
          else
            TextButton(
              onPressed: nearby ? onConnect : null,
              child: const Text('Connect'),
            ),
          IconButton(
            tooltip: 'Forget',
            icon: const Icon(Icons.delete_outline),
            onPressed: onForget,
          ),
        ],
      ),
    );
  }
}
