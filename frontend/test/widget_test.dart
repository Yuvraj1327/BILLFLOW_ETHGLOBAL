import 'package:flutter_test/flutter_test.dart';

import 'package:billflow/core/utils/format.dart';

void main() {
  test('shortHash abbreviates long hashes and keeps short ones', () {
    expect(shortHash('0x1234'), '0x1234');
    final long = '0x${'a' * 64}';
    expect(shortHash(long), '${long.substring(0, 10)}…${long.substring(long.length - 6)}');
  });
}
