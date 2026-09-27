// Derived from libdivecomputer's Shearwater support.
// Copyright (C) 2013 Jef Driesen and libdivecomputer contributors.
// Dart port and modifications Copyright (C) 2026 PicSeas contributors.
// Licensed under LGPL-2.1-or-later. Modified for PicSeas in 2026.
// Corresponding source: https://github.com/decaffeinesoft/picseas-shearwater

import 'package:picseas/core/l10n/app_strings.dart';
import 'dart:typed_data';

import '../../../core/spike_log.dart';
import 'shearwater_compression.dart';
import 'shearwater_transport.dart';

/// 명령 코드. libdivecomputer `shearwater_common.c`의 정의를 그대로 쓴다.
const int _rdbiRequest = 0x22;
const int _rdbiResponse = 0x62;
const int _uploadInitRequest = 0x35;
const int _uploadInitResponse = 0x75;
const int _uploadDataRequest = 0x36;
const int _uploadDataResponse = 0x76;
const int _uploadExitRequest = 0x37;
const int _uploadExitResponse = 0x77;
const int _nak = 0x7F;

/// 식별자 ID (`shearwater_common.h`).
const int idSerial = 0x8010;
const int idFirmware = 0x8011;
const int idLogUpload = 0x8021;
const int idModel = 0x8060;

/// 매니페스트 영역 (`shearwater_petrel.c`).
const int manifestAddr = 0xE0000000;
const int manifestSize = 0x600;
const int recordSize = 0x20;
const int recordCount = manifestSize ~/ recordSize;

/// 다이브 본문 요청 시 쓰는 크기 상한. 실제 끝은 압축 스트림의 종료 표시로
/// 판단하므로 이 값 자체에 의미는 없다 (`DIVE_SIZE`).
const int diveSizeLimit = 0xFFFFFF;

/// 유효한 다이브 레코드 / 삭제된 다이브의 머리 2바이트.
const int _recordValid = 0xA5C4;
const int _recordDeleted = 0x5A23;

int _uint16be(List<int> b, int o) => (b[o] << 8) | b[o + 1];

int _uint32be(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// 매니페스트 한 줄 = 다이브 하나.
///
/// libdivecomputer가 실제로 읽는 필드는 두 개뿐이다 — 지문(offset 4)과
/// 다이브 본문 주소(offset 20). 날짜·최대수심 같은 값은 매니페스트가 아니라
/// 다이브를 내려받아야 나온다.
class ManifestRecord {
  ManifestRecord({
    required this.fingerprint,
    required this.address,
    required this.raw,
  });

  factory ManifestRecord.parse(List<int> page, int offset) => ManifestRecord(
    fingerprint: page.sublist(offset + 4, offset + 8),
    address: _uint32be(page, offset + 20),
    raw: page.sublist(offset, offset + recordSize),
  );

  final List<int> fingerprint;
  final int address;
  final List<int> raw;

  /// 기기가 매긴 다이브 순번. 첫 다이브가 1이다.
  ///
  /// **libdivecomputer에 없는 값이다.** 원본이 매니페스트에서 헤더·지문·주소만
  /// 읽으므로 옮겨올 구현이 없었고, 대신 "번호는 레코드마다 1씩 줄어든다"는
  /// 성질로 자리를 찾아 실기기로 확인했다(2026-09-13, Peregrine 26다이브에서
  /// 1~26). 주소(20-23) 바로 앞자리다.
  ///
  /// 폭이 2인 이유: 같은 값이 `u8@19`로도, `u16le@19`로도 읽혔지만 둘 다
  /// 우연이다. 앞은 256번째 다이브에서, 뒤는 주소의 최상위 바이트가 0이 아니게
  /// 되는 순간 깨진다.
  ///
  /// **기기 화면에 뜨는 번호와는 다를 수 있다.** 사용자가 시작 번호를 손으로
  /// 맞춰둔 경우가 있고(다른 곳에 적던 로그를 이어 쓰는 경우), 그 보정값은
  /// 기기 설정이라 여기 없다. 보정은 앱에서 받는다(§2.3).
  int get diveIndex => _uint16be(raw, 18);

  /// 다이브 시작 시각 — **기기 시계의 벽시계 값이지 UTC가 아니다.**
  ///
  /// 실기기에서 확인했다: 기기 화면이 보여주는 시각과 이 원시값이 그대로
  /// 일치한다(2026-05-04 13:55). 저장과 표시 사이에 시간대 변환이 없다는 뜻이다.
  /// 그때 기기 시계가 어느 시간대였는지는 데이터만으로 알 수 없고, 알 필요도
  /// 없다 — 사진 매칭은 카메라 시계와의 **차이**만 맞추면 되기 때문이다(§5.1).
  ///
  /// `isUtc: true`는 "UTC다"라는 주장이 아니라 **암묵적 로컬 변환을 막기 위한
  /// 것**이다. 이 값에 시간대 변환을 걸면 그만큼 시각이 밀린다.
  DateTime get deviceClock => DateTime.fromMillisecondsSinceEpoch(
    _uint32be(fingerprint, 0) * 1000,
    isUtc: true,
  );

  /// 시간대를 주장하지 않는 표기. `Z`를 붙이면 UTC라고 오해하게 된다.
  String get deviceClockText {
    final t = deviceClock;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  String toString() => tr('msg499', [
    address.toRadixString(16).padLeft(8, '0'),
    hex(fingerprint),
    deviceClockText,
  ]);
}

/// 매니페스트까지의 다운로드 경로. 다이브 본문은 압축(LRE+XOR)이 걸려 있어
/// 별도 작업이며 여기 포함하지 않는다 (PLAN.md §2.3 1.5단계).
class ShearwaterDownloader {
  ShearwaterDownloader(this.transport, this.log, {this.isCancelled});

  final ShearwaterTransport transport;
  final SpikeLog log;

  /// 블록마다 확인한다. 다이브 하나가 수십 초라 다이브 경계에서만 보면
  /// 사용자에게는 먹통으로 보인다. 블록은 0.5초 남짓이다.
  final bool Function()? isCancelled;

  /// 식별자 읽기. 응답은 `62 [id_hi] [id_lo] <data…>`.
  Future<List<int>> rdbi(int id) async {
    final request = [_rdbiRequest, (id >> 8) & 0xFF, id & 0xFF];
    final r = await transport.request(request);

    if (r.length == 3 && r[0] == _nak && r[1] == _rdbiRequest) {
      throw ShearwaterProtocolException(
        tr('msg500', [id.toRadixString(16), r[2].toRadixString(16)]),
      );
    }
    if (r.length < 3 ||
        r[0] != _rdbiResponse ||
        r[1] != request[1] ||
        r[2] != request[2]) {
      throw ShearwaterProtocolException(tr('msg501', [hex(r)]));
    }
    return r.sublist(3);
  }

  /// 로그북 기준 주소. 다이브 본문 주소는 이 값에 매니페스트의 주소를 더한 것이다.
  Future<int> readLogbookBaseAddress() async {
    final r = await rdbi(idLogUpload);
    if (r.length < 5) {
      throw ShearwaterProtocolException(tr('msg502', [hex(r)]));
    }

    final raw = _uint32be(r, 1);
    // 구형 포맷 몇 가지는 Predator 계열 주소로 모아서 처리한다.
    return switch (raw) {
      0xDD000000 || 0xC0000000 || 0x90000000 => 0xC0000000,
      0x80000000 => 0x80000000,
      _ => throw ShearwaterProtocolException(
        tr('msg503', [raw.toRadixString(16)]),
      ),
    };
  }

  /// 지정 영역을 블록 단위로 받아온다.
  /// `0x35`로 열고 `0x36`을 블록 번호를 올려가며 반복한 뒤 `0x37`로 닫는다.
  ///
  /// 매니페스트는 비압축이고, 다이브 본문은 압축(LRE + XOR)이 걸려 있다.
  /// 압축 경로에서는 `size`가 실제 크기가 아니라 상한 표시(`0xFFFFFF`)로
  /// 쓰이며, 끝은 LRE 스트림의 종료 표시로 판단한다.
  Future<Uint8List> download(
    int address,
    int size, {
    bool compressed = false,
  }) async {
    final init = await transport.request([
      _uploadInitRequest,
      compressed ? 0x10 : 0x00,
      0x34,
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
    ]);

    if (init.length < 2 || init[0] != _uploadInitResponse) {
      throw ShearwaterProtocolException(tr('msg504', [hex(init)]));
    }

    final raw = BytesBuilder();
    final lre = compressed ? ShearwaterLreDecoder() : null;
    var block = 1;
    var received = 0;

    try {
      while (received < size) {
        if (isCancelled?.call() ?? false) {
          throw const ShearwaterCancelledException();
        }

        final r = await _requestBlock(block);

        final data = r.sublist(2);
        // 기기가 빈 블록을 돌려주면 끝난 것으로 본다. 이 탈출구가 없으면
        // size를 채우지 못한 채 영원히 돈다.
        if (data.isEmpty) break;

        if (lre != null) {
          lre.addBlock(data);
        } else {
          if (received + data.length > size) {
            throw ShearwaterProtocolException(
              tr('msg505', [block, received + data.length, size]),
            );
          }
          raw.add(data);
        }

        received += data.length;
        block++;

        if (lre != null && lre.isFinal) break;
      }
    } catch (_) {
      // 세션을 열어둔 채로 빠져나오면 기기가 다음 0x35를 받지 않는다.
      // 실기기에서 확인했다 — 다이브 하나가 실패하면 이후 전부가 무응답이 되고
      // 결국 연결까지 끊어졌다.
      await _exitUpload(strict: false);
      rethrow;
    }

    await _exitUpload(strict: true);

    if (lre == null) return raw.toBytes();

    if (!lre.isFinal) {
      throw ShearwaterProtocolException(tr('msg506', [lre.length]));
    }
    return shearwaterXorDecode(lre.takeBytes());
  }

  /// 다이브 본문 하나를 받아 압축을 푼 바이트를 돌려준다.
  /// 실제 주소는 로그북 기준 주소에 매니페스트의 상대 주소를 더한 값이다.
  Future<Uint8List> downloadDive(int baseAddress, ManifestRecord record) =>
      download(baseAddress + record.address, diveSizeLimit, compressed: true);

  /// 블록 하나를 요청한다. 무응답이면 한 번만 다시 시도한다.
  ///
  /// 블록은 번호로 지정하므로 같은 요청을 다시 보내도 같은 데이터가 온다.
  /// 재시도가 안전한 이유이고, 한 번의 유실로 다이브 전체를 버리지 않아도 된다.
  Future<List<int>> _requestBlock(int block) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      final List<int> r;
      try {
        r = await transport.request([_uploadDataRequest, block & 0xFF]);
      } on ShearwaterProtocolException {
        if (attempt == 2) rethrow;
        log.warn(tr('msg507', [block]));
        continue;
      }

      if (r.length < 2 ||
          r[0] != _uploadDataResponse ||
          r[1] != (block & 0xFF)) {
        throw ShearwaterProtocolException(tr('msg508', [block, hex(r)]));
      }
      return r;
    }
    throw StateError(tr('msg509'));
  }

  /// 업로드 세션을 닫는다.
  ///
  /// 실패한 세션을 정리하는 중이라면(`strict: false`) 종료 응답이 오지 않아도
  /// 넘어간다. 이미 응답하지 않는 기기에 대고 더 할 수 있는 일이 없고, 원래
  /// 실패 원인을 이 실패로 덮으면 진단만 어려워진다.
  Future<void> _exitUpload({required bool strict}) async {
    try {
      final quit = await transport.request([_uploadExitRequest]);
      if (quit.length != 2 ||
          quit[0] != _uploadExitResponse ||
          quit[1] != 0x00) {
        if (strict) {
          throw ShearwaterProtocolException(tr('msg510', [hex(quit)]));
        }
      }
    } on ShearwaterProtocolException {
      if (strict) rethrow;
      log.warn(tr('msg511'));
    }
  }

  /// 매니페스트를 끝까지 읽어 다이브 목록을 만든다.
  ///
  /// 같은 주소를 반복해서 내려받는 것이 정상이다 — 기기가 페이지를 넘겨준다.
  /// 한 페이지가 꽉 차지 않으면 마지막 페이지다.
  Future<List<ManifestRecord>> readManifest() async {
    final records = <ManifestRecord>[];
    var page = 0;

    while (true) {
      page++;
      log.info(tr('msg512', [page]));
      final data = await download(manifestAddr, manifestSize);
      log.ok(tr('msg513', [page, data.length]));

      var count = 0;
      var deleted = 0;
      var offset = 0;

      while (offset + recordSize <= data.length) {
        final header = _uint16be(data, offset);
        if (header == _recordDeleted) {
          offset += recordSize;
          deleted++;
          continue;
        }
        if (header != _recordValid) break;

        records.add(ManifestRecord.parse(data, offset));
        offset += recordSize;
        count++;
      }

      log.info(tr('msg514', [count, deleted]));

      // 첫 페이지부터 비어 있으면 목록이 없는 게 아니라, 기기가 이전 읽기에서
      // 넘어간 페이지를 계속 내주고 있는 것이다. 커서는 연결 안에서 유지된다.
      if (page == 1 && count == 0 && deleted == 0) {
        throw ShearwaterProtocolException(tr('msg515'));
      }

      if (count + deleted != recordCount) break;
    }

    return records;
  }
}
