import 'package:picseas/core/l10n/app_strings.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../../../core/spike_log.dart';
import 'shearwater_framing.dart';
import 'slip.dart';

/// 프로토콜 위반이나 기기의 거부 응답. 전송 실패(BLE 오류)와 구분한다.
class ShearwaterProtocolException implements Exception {
  ShearwaterProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ShearwaterProtocolException: $message';
}

/// 사용자가 중단을 요청해 전송을 접었다. **실패가 아니다** — 실패 목록에
/// 넣거나 재시도 대상으로 삼으면 안 된다.
class ShearwaterCancelledException implements Exception {
  const ShearwaterCancelledException();

  @override
  String toString() => 'ShearwaterCancelledException';
}

/// 연결된 Shearwater 기기와의 요청/응답 왕복.
///
/// 한 요청에 한 응답이 오는 단순한 동기 프로토콜이라, 동시에 여러 요청을
/// 띄우지 않는다. 응답은 여러 notify 청크에 걸쳐 오므로 SLIP으로 재조립한다.
class ShearwaterTransport {
  ShearwaterTransport({
    required this.deviceId,
    required this.serviceUuid,
    required this.writeUuid,
    required this.notifyUuid,
    required this.writeWithoutResponse,
    required this.log,
  });

  final String deviceId;
  final String serviceUuid;

  /// Peregrine은 한 특성이 write와 notify를 겸하지만, 기종에 따라 나뉠 수 있다.
  final String writeUuid;
  final String notifyUuid;

  final bool writeWithoutResponse;
  final SpikeLog log;

  StreamSubscription<Uint8List>? _sub;
  final SlipAssembler _assembler = SlipAssembler();
  Completer<List<int>>? _pending;

  /// 바이트를 전부 로그에 남길지. 매니페스트처럼 큰 전송에서는 끈다.
  bool verbose = true;

  Future<void> open() async {
    await close();
    _assembler.reset();

    _sub = UniversalBle.characteristicValueStream(
      deviceId,
      notifyUuid,
    ).listen(_onNotify);
    await UniversalBle.subscribeNotifications(
      deviceId,
      serviceUuid,
      notifyUuid,
    );
    log.ok(tr('msg518', [writeUuid, notifyUuid]));
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// 연결 간격을 좁혀 달라고 다시 요청한다.
  ///
  /// Android는 이 상향을 **일정 시간만 유지하고 되돌린다.** 실측에서 첫
  /// 다이브는 4.7초, 이후는 20~22초였다 — 효과 자체는 4~5배로 분명하지만
  /// 오래가지 않는다. 그래서 다이브마다 다시 요청한다. 호출 비용은 거의 없고,
  /// 받아들이지 않는 플랫폼(iOS)에서는 조용히 실패한다.
  Future<void> boostThroughput() async {
    try {
      await UniversalBle.requestConnectionPriority(
        deviceId,
        BleConnectionPriority.highPerformance,
      );
    } catch (_) {
      // 플랫폼이 지원하지 않을 뿐이고 전송 자체에는 지장이 없다.
    }
  }

  void _onNotify(Uint8List chunk) {
    // 청크마다 [전체 프레임 수, 인덱스] 2바이트가 붙어 온다.
    if (chunk.length <= shearwaterBleHeaderLength) return;
    if (verbose) log.rx(hex(chunk));

    for (final frame in _assembler.feed(
      chunk.sublist(shearwaterBleHeaderLength),
    )) {
      final p = _pending;
      if (p == null || p.isCompleted) continue;
      p.complete(frame);
    }
  }

  /// 명령 body를 보내고 응답 body를 돌려준다.
  /// 패킷 헤더(`FF 01 …` / `01 FF …`)는 이 계층에서 붙이고 떼낸다.
  Future<List<int>> request(
    List<int> body, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _assembler.reset();
    final pending = _pending = Completer<List<int>>();

    for (final frame in shearwaterBleFrames(shearwaterPacket(body))) {
      final bytes = Uint8List.fromList(frame);
      if (verbose) log.tx(hex(bytes));
      await UniversalBle.write(
        deviceId,
        serviceUuid,
        writeUuid,
        bytes,
        withoutResponse: writeWithoutResponse,
      );
    }

    final List<int> frame;
    try {
      frame = await pending.future.timeout(timeout);
    } on TimeoutException {
      throw ShearwaterProtocolException(
        tr('msg519', [timeout.inSeconds, hex(body)]),
      );
    } finally {
      _pending = null;
    }

    return _unwrap(frame);
  }

  /// 응답 헤더는 요청과 바이트 순서가 뒤집힌 `01 FF [len+1] 00` 이다.
  List<int> _unwrap(List<int> frame) {
    if (frame.length < 4 ||
        frame[0] != 0x01 ||
        frame[1] != 0xFF ||
        frame[3] != 0x00) {
      throw ShearwaterProtocolException(tr('msg520', [hex(frame)]));
    }

    final declared = frame[2];
    if (declared < 1) {
      throw ShearwaterProtocolException(tr('msg521', [hex(frame)]));
    }

    final length = declared - 1;
    if (length + 4 != frame.length) {
      throw ShearwaterProtocolException(
        tr('msg522', [length, frame.length - 4, hex(frame)]),
      );
    }

    return frame.sublist(4);
  }
}
