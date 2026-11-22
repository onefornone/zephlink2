/// "1.4 MB", "820 KB" ...
String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatSpeed(double bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// "45 s", "3 min 20 s", "1 h 05 min" ...
String formatDuration(Duration time) {
  final seconds = time.inSeconds;
  if (seconds < 60) return '${seconds < 1 ? 1 : seconds} s';
  final minutes = time.inMinutes;
  if (minutes < 60) {
    final rest = seconds % 60;
    return rest == 0 ? '$minutes min' : '$minutes min $rest s';
  }
  final hours = time.inHours;
  return '$hours h ${(minutes % 60).toString().padLeft(2, '0')} min';
}

/// "12.3 MB of 450 MB · 8.2 MB/s · 54 s left" for a running transfer.
String transferProgressText(int bytes, int size, double speed, Duration? left) {
  final parts = <String>['${formatBytes(bytes)} of ${formatBytes(size)}'];
  if (speed >= 1) parts.add(formatSpeed(speed));
  if (left != null) parts.add('${formatDuration(left)} left');
  return parts.join(' · ');
}

/// "just now", "5 min ago" ...
String timeAgo(DateTime time) {
  final d = DateTime.now().difference(time);
  if (d.inSeconds < 10) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds} s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
