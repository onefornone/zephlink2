import 'package:flutter/material.dart';

import '../features/transfer_hub.dart';
import '../link/link_controller.dart';

/// Sends a failed or cancelled file again and tells the person if it cannot.
Future<void> resendWithMessage(
  BuildContext context,
  LinkController link,
  TransferItem item,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final error = await link.resendTransfer(item);
  if (error == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(error)));
}
