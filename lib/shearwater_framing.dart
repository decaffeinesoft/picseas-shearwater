// Derived from libdivecomputer's Shearwater support.
// Copyright (C) 2013 Jef Driesen and libdivecomputer contributors.
// Dart port and modifications Copyright (C) 2026 PicSeas contributors.
// Licensed under LGPL-2.1-or-later. Modified for PicSeas in 2026.
// Corresponding source: https://github.com/decaffeinesoft/picseas-shearwater

import 'slip.dart';

/// Shearwater V1 프로토콜의 BLE 와이어 포맷.
///
/// 값을 추측하지 않고 libdivecomputer `shearwater_common.c`에서 그대로 옮겼다:
/// - 패킷 헤더 `FF 01 [len+1] 00` + body (`shearwater_common_transfer`)
/// - BLE 전송은 20바이트(`BLE_MTU_MIN`) 단위로 쪼개고, **패킷마다 앞에
///   `[전체 프레임 수, 프레임 인덱스]` 2바이트**를 붙인다
/// - SLIP은 **끝을 닫는 END 하나만**. 선두 END는 붙이지 않는다
/// - 응답도 같은 2바이트 헤더를 달고 오므로 수신 시 건너뛴다
///   (`shearwater_common_slip_read`의 `offset = 2`)
///
/// 이 2바이트 헤더가 빠지면 기기는 write를 ACK하면서도 아무 응답을 하지 않는다.
/// 실기기에서 확인했다(PLAN.md §2.3).

/// libdivecomputer의 `BLE_MTU_MIN`.
const int bleMtuMin = 20;

/// 응답 notify 청크마다 앞에 붙어 오는 프레이밍 헤더 길이.
const int shearwaterBleHeaderLength = 2;

/// V1 패킷 헤더: `FF 01 [len+1] 00` + body.
List<int> shearwaterPacket(List<int> body) => [
  0xFF,
  0x01,
  body.length + 1,
  0x00,
  ...body,
];

/// 패킷을 BLE로 나갈 프레임 목록으로 만든다.
/// 대부분의 요청은 짧아서 프레임 1개로 끝난다.
List<List<int>> shearwaterBleFrames(List<int> packet, {bool bleHeader = true}) {
  // 이스케이프 후 바이트 수 + 끝을 닫는 END 한 바이트.
  var count = 1;
  for (final b in packet) {
    count += (b == Slip.end || b == Slip.esc) ? 2 : 1;
  }
  final nframes = (count + bleMtuMin - 1) ~/ bleMtuMin;

  final frames = <List<int>>[];
  var index = 0;
  var buf = bleHeader ? <int>[nframes, index] : <int>[];

  void flushIfFull() {
    if (buf.length < bleMtuMin) return;
    frames.add(buf);
    index++;
    buf = bleHeader ? <int>[nframes, index] : <int>[];
  }

  for (final b in packet) {
    if (b == Slip.end || b == Slip.esc) {
      buf.add(Slip.esc);
      flushIfFull();
      buf.add(b == Slip.end ? Slip.escEnd : Slip.escEsc);
      flushIfFull();
    } else {
      buf.add(b);
      flushIfFull();
    }
  }

  buf.add(Slip.end);
  frames.add(buf);
  return frames;
}
