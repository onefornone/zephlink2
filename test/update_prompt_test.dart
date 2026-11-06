import 'package:flutter_test/flutter_test.dart';
import 'package:zephlink/platform/update_prompt_host.dart';

void main() {
  test('compares released app versions without build metadata', () {
    expect(isNewerVersion('v0.3.0', '0.2.0+9'), isTrue);
    expect(isNewerVersion('0.2.1', '0.2.0'), isTrue);
    expect(isNewerVersion('0.2.0', '0.2.0+9'), isFalse);
    expect(isNewerVersion('0.1.9', '0.2.0'), isFalse);
    expect(isNewerVersion('preview', '0.2.0'), isFalse);
  });
}
