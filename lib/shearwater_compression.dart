// Derived from libdivecomputer's Shearwater support.
// Copyright (C) 2013 Jef Driesen and libdivecomputer contributors.
// Dart port and modifications Copyright (C) 2026 PicSeas contributors.
// Licensed under LGPL-2.1-or-later. Modified for PicSeas in 2026.
// Corresponding source: https://github.com/decaffeinesoft/picseas-shearwater

import 'package:picseas/core/l10n/app_strings.dart';
import 'dart:typed_data';

/// 다이브 본문에 걸려 있는 두 겹의 압축.
///
/// libdivecomputer `shearwater_common.c`의 `shearwater_common_decompress_lre` /
/// `_decompress_xor`를 그대로 옮겼다. 매니페스트는 비압축이지만 다이브 본문은
/// 이 둘을 순서대로 풀어야 한다 — 먼저 블록마다 LRE를 풀어 이어붙이고,
/// 전부 모인 뒤 XOR을 푼다.
class ShearwaterCompressionException implements Exception {
  ShearwaterCompressionException(this.message);
  final String message;

  @override
  String toString() => 'ShearwaterCompressionException: $message';
}

/// 9비트 런렝스 해제기.
///
/// 데이터를 **9비트 값의 연속**으로 읽는다. 9번째 비트가 서면 나머지 8비트가
/// 그대로 데이터 바이트이고, 서지 않으면 그 값만큼 0 바이트가 이어진다는
/// 뜻이다. 값이 0이면 스트림의 끝이다.
///
/// 블록이 여러 번에 나눠 들어오므로 상태를 들고 있는다.
class ShearwaterLreDecoder {
  final BytesBuilder _out = BytesBuilder();
  bool _isFinal = false;

  /// 스트림 종료 표시를 만났는지. 이게 서면 더 받을 필요가 없다.
  bool get isFinal => _isFinal;

  int get length => _out.length;

  void addBlock(List<int> block) {
    // 9비트 단위로 딱 떨어져야 한다. 안 맞으면 블록 경계가 어긋난 것이다.
    final nbits = block.length * 8;
    if (nbits % 9 != 0) {
      throw ShearwaterCompressionException(tr('msg523', [block.length]));
    }

    var offset = 0;
    while (offset + 9 <= nbits) {
      final index = offset ~/ 8;
      final bit = offset % 8;
      final shift = 16 - (bit + 9);

      // 9비트가 두 바이트에 걸치므로 16비트로 읽어 잘라낸다.
      // 마지막 값은 두 번째 바이트가 없을 수 있어 0으로 채운다.
      final hi = block[index];
      final lo = index + 1 < block.length ? block[index + 1] : 0;
      final value = (((hi << 8) | lo) >> shift) & 0x1FF;

      if (value & 0x100 != 0) {
        _out.addByte(value & 0xFF);
      } else if (value == 0) {
        _isFinal = true;
        return;
      } else {
        _out.add(Uint8List(value));
      }

      offset += 9;
    }
  }

  Uint8List takeBytes() => _out.takeBytes();
}

/// 32바이트 블록 XOR 해제.
///
/// 첫 32바이트는 그대로 두고, 이후 각 바이트를 32바이트 앞의 **이미 해제된**
/// 바이트와 XOR한다. 앞에서부터 제자리로 처리해야 한다.
Uint8List shearwaterXorDecode(Uint8List data) {
  for (var i = 32; i < data.length; i++) {
    data[i] ^= data[i - 32];
  }
  return data;
}
