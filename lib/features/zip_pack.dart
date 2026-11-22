import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// A file to put in the zip, and the name it gets inside (with "/" folders).
class ZipInput {
  const ZipInput(this.path, this.name);

  final String path;
  final String name;
}

/// Writes [inputs] into one plain zip file at [outPath] (stored, not
/// squeezed, so it is quick). Runs away from the screen so the app stays
/// smooth. Gives back false when the folder is too big or has too many files
/// for a normal zip (4 GB, or more than 65,000 files); nothing is left behind
/// then, and the caller can send the files one by one instead.
Future<bool> packZip(List<ZipInput> inputs, String outPath) {
  final paths = inputs.map((input) => input.path).toList();
  final names = inputs.map((input) => input.name).toList();
  return Isolate.run<bool>(() => _packSync(paths, names, outPath));
}

final Uint32List _crcTable = _makeTable();

Uint32List _makeTable() {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    table[n] = c;
  }
  return table;
}

/// Continues a CRC-32 over [length] bytes. Start with 0xFFFFFFFF and finish
/// by XOR-ing the result with 0xFFFFFFFF.
int _crcUpdate(int state, Uint8List data, int length) {
  var c = state;
  for (var i = 0; i < length; i++) {
    c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return c;
}

Uint8List _localHeader(List<int> name, int time, int date) {
  final bytes = Uint8List(30 + name.length);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, 0x04034b50, Endian.little);
  view.setUint16(4, 20, Endian.little);
  view.setUint16(6, 0x0800, Endian.little); // names are UTF-8
  view.setUint16(8, 0, Endian.little); // stored
  view.setUint16(10, time, Endian.little);
  view.setUint16(12, date, Endian.little);
  // CRC and sizes (14..25) are filled in after the data is written.
  view.setUint16(26, name.length, Endian.little);
  view.setUint16(28, 0, Endian.little);
  bytes.setRange(30, bytes.length, name);
  return bytes;
}

Uint8List _centralEntry(
  List<int> name,
  int time,
  int date,
  int crc,
  int size,
  int offset,
) {
  final bytes = Uint8List(46 + name.length);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, 0x02014b50, Endian.little);
  view.setUint16(4, 20, Endian.little);
  view.setUint16(6, 20, Endian.little);
  view.setUint16(8, 0x0800, Endian.little);
  view.setUint16(10, 0, Endian.little);
  view.setUint16(12, time, Endian.little);
  view.setUint16(14, date, Endian.little);
  view.setUint32(16, crc, Endian.little);
  view.setUint32(20, size, Endian.little);
  view.setUint32(24, size, Endian.little);
  view.setUint16(28, name.length, Endian.little);
  view.setUint16(30, 0, Endian.little);
  view.setUint16(32, 0, Endian.little);
  view.setUint16(34, 0, Endian.little);
  view.setUint16(36, 0, Endian.little);
  view.setUint32(38, 0, Endian.little);
  view.setUint32(42, offset, Endian.little);
  bytes.setRange(46, bytes.length, name);
  return bytes;
}

bool _packSync(List<String> paths, List<String> names, String outPath) {
  const limit = 0xFFFFFF00;
  if (paths.isEmpty || paths.length > 65000) return false;
  final out = File(outPath).openSync(mode: FileMode.write);
  final central = BytesBuilder(copy: false);
  final buffer = Uint8List(256 * 1024);
  var offset = 0;
  var count = 0;
  var ok = true;
  try {
    for (var index = 0; index < paths.length; index++) {
      final source = File(paths[index]);
      RandomAccessFile input;
      DateTime modified;
      try {
        input = source.openSync();
        modified = source.lastModifiedSync();
      } catch (_) {
        continue; // Cannot be read: leave it out.
      }
      try {
        final name = utf8.encode(names[index]);
        final year = modified.year < 1980
            ? 1980
            : (modified.year > 2107 ? 2107 : modified.year);
        final time =
            (modified.hour << 11) | (modified.minute << 5) | (modified.second ~/ 2);
        final date = ((year - 1980) << 9) | (modified.month << 5) | modified.day;
        final headerOffset = offset;
        out.writeFromSync(_localHeader(name, time, date));
        offset += 30 + name.length;
        var state = 0xFFFFFFFF;
        var size = 0;
        while (true) {
          final read = input.readIntoSync(buffer);
          if (read <= 0) break;
          state = _crcUpdate(state, buffer, read);
          out.writeFromSync(buffer, 0, read);
          size += read;
          offset += read;
          if (offset >= limit) {
            ok = false;
            break;
          }
        }
        if (!ok) break;
        final crc = state ^ 0xFFFFFFFF;
        final patch = Uint8List(12);
        final view = ByteData.sublistView(patch);
        view.setUint32(0, crc, Endian.little);
        view.setUint32(4, size, Endian.little);
        view.setUint32(8, size, Endian.little);
        out.setPositionSync(headerOffset + 14);
        out.writeFromSync(patch);
        out.setPositionSync(offset);
        central.add(_centralEntry(name, time, date, crc, size, headerOffset));
        count++;
      } finally {
        input.closeSync();
      }
    }
    if (ok && count > 0) {
      final directory = central.takeBytes();
      out.writeFromSync(directory);
      final end = Uint8List(22);
      final view = ByteData.sublistView(end);
      view.setUint32(0, 0x06054b50, Endian.little);
      view.setUint16(8, count, Endian.little);
      view.setUint16(10, count, Endian.little);
      view.setUint32(12, directory.length, Endian.little);
      view.setUint32(16, offset, Endian.little);
      out.writeFromSync(end);
    } else {
      ok = false;
    }
  } catch (_) {
    ok = false;
  } finally {
    out.closeSync();
  }
  if (!ok) {
    try {
      File(outPath).deleteSync();
    } catch (_) {
      // Nothing to remove.
    }
  }
  return ok;
}
