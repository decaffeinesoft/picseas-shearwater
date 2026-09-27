// Derived in part from libdivecomputer's Shearwater support.
// Copyright (C) 2013 Jef Driesen and libdivecomputer contributors.
// Dart port and modifications Copyright (C) 2026 PicSeas contributors.
// Licensed under LGPL-2.1-or-later. Modified for PicSeas in 2026.
// Corresponding source: https://github.com/decaffeinesoft/picseas-shearwater

import 'package:picseas/core/l10n/app_strings.dart';
import 'dart:typed_data';

/// 압축을 푼 다이브 본문을 해석한다.
///
/// 필드 위치는 추측이 아니라 libdivecomputer `shearwater_predator_parser.c`에서
/// 옮겼고, 실기기 덤프로 교차 확인했다(PLAN.md §2.3).
///
/// **Petrel Native Format(PNF)만 다룬다.** 본문 전체가 32바이트 레코드의
/// 연속이고, 각 레코드의 첫 바이트가 종류를 가리킨다. 구형 Predator 포맷은
/// 128바이트 헤더/푸터 구조라 취급이 달라서, v1 대상(Peregrine 계열)이 아닌
/// 만큼 지원하지 않고 명시적으로 거부한다.

const int _recordSize = 0x20;

/// 레코드 종류 (`LOG_RECORD_*`).
const int _typeDiveSample = 0x01;
const int _typeAveloSample = 0x03;
const int _typeOpening0 = 0x10;
const int _typeOpening9 = 0x19;
const int _typeClosing0 = 0x20;
const int _typeClosing9 = 0x29;

const int _imperial = 1;
const double _feet = 0.3048;

/// 로그 버전 9부터 샘플 간격이 기록된다. 그전에는 10초 고정이다.
const int _defaultIntervalMs = 10000;

class ShearwaterParseException implements Exception {
  ShearwaterParseException(this.message);
  final String message;

  @override
  String toString() => 'ShearwaterParseException: $message';
}

class DiveSample {
  const DiveSample({
    required this.time,
    required this.depthMeters,
    required this.temperatureC,
  });

  /// 다이브 시작으로부터의 경과 시간.
  final Duration time;
  final double depthMeters;
  final double temperatureC;
}

class ParsedDive {
  const ParsedDive({
    required this.number,
    required this.start,
    required this.duration,
    required this.maxDepthMeters,
    required this.sampleInterval,
    required this.logVersion,
    required this.imperial,
    required this.samples,
  });

  /// 기기가 매긴 다이브 번호. **기기 화면에 뜨는 바로 그 번호다.**
  ///
  /// libdivecomputer는 이 값을 읽지 않는다 — API의 필드 목록(`DC_FIELD_*`)에
  /// 다이브 번호라는 항목 자체가 없어서 어느 백엔드도 뽑지 않는다. 그래서
  /// 옮겨올 원본이 없었고, "번호는 다이브마다 1씩 늘어난다"는 성질로 자리를
  /// 찾아 실기기에서 확인했다(2026-09-13, Peregrine에서 62).
  ///
  /// 매니페스트에도 1씩 줄어드는 자리(18-19)가 있지만 그건 **순차 인덱스**라
  /// 항상 1부터 시작한다. 사용자가 시작 번호를 맞춰둔 기기에서는 화면 번호와
  /// 다르다(실기기: 인덱스 1~26 ↔ 화면 37~62). 여기 있는 값이 정본이다.
  ///
  /// 읽지 못했으면 null이다.
  final int? number;

  /// 다이브 시작 시각 — **기기 시계의 벽시계 값이지 UTC가 아니다.**
  /// 시간대 변환을 걸면 그만큼 밀린다 (PLAN.md §2.3 "시각은 벽시계다").
  final DateTime start;

  final Duration duration;
  final double maxDepthMeters;
  final Duration sampleInterval;
  final int logVersion;

  /// 기기가 야드파운드 단위로 설정돼 있었는지. 저장값 해석이 달라진다.
  final bool imperial;

  final List<DiveSample> samples;

  /// 시간대를 주장하지 않는 표기.
  String get startText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${start.year}-${two(start.month)}-${two(start.day)} '
        '${two(start.hour)}:${two(start.minute)}:${two(start.second)}';
  }

  /// 샘플에서 직접 구한 최대수심. 푸터의 값과 대조하면 파싱이 맞았는지 알 수 있다.
  double get maxDepthFromSamples => samples.isEmpty
      ? 0
      : samples.map((s) => s.depthMeters).reduce((a, b) => a > b ? a : b);

  double get minTemperatureC => samples.isEmpty
      ? 0
      : samples.map((s) => s.temperatureC).reduce((a, b) => a < b ? a : b);
}

int _u16(Uint8List d, int o) => (d[o] << 8) | d[o + 1];

int _u24(Uint8List d, int o) => (d[o] << 16) | (d[o + 1] << 8) | d[o + 2];

int _u32(Uint8List d, int o) =>
    (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

bool _allZero(Uint8List d, int o, int n) {
  for (var i = o; i < o + n; i++) {
    if (d[i] != 0) return false;
  }
  return true;
}

ParsedDive parseShearwaterDive(Uint8List data) {
  if (data.length < _recordSize) {
    throw ShearwaterParseException(tr('msg562', [data.length]));
  }
  // 첫 두 바이트가 0xFFFF면 구형 Predator 계열 포맷이다.
  if (_u16(data, 0) == 0xFFFF) {
    throw ShearwaterParseException(tr('msg563'));
  }

  // 1차: 헤더/푸터 레코드 위치를 모은다. 샘플 해석에 필요한 단위·간격이
  // 헤더에 있으므로 샘플보다 먼저 훑어야 한다.
  final opening = <int, int>{};
  final closing = <int, int>{};
  for (
    var offset = 0;
    offset + _recordSize <= data.length;
    offset += _recordSize
  ) {
    final type = data[offset];
    if (type >= _typeOpening0 && type <= _typeOpening9) {
      opening[type - _typeOpening0] = offset;
    } else if (type >= _typeClosing0 && type <= _typeClosing9) {
      closing[type - _typeClosing0] = offset;
    }
  }

  final o0 = opening[0];
  final c0 = closing[0];
  if (o0 == null) {
    throw ShearwaterParseException(tr('msg564'));
  }
  if (c0 == null) {
    throw ShearwaterParseException(tr('msg565'));
  }

  final imperial = data[o0 + 8] == _imperial;
  final ticks = _u32(data, o0 + 12);

  // 2바이트인 이유: 같은 값이 u8로도 읽히지만 그건 하위 바이트라 256번째
  // 다이브에서 0으로 돌아간다.
  final number = _u16(data, o0 + 2);

  final o4 = opening[4];
  final logVersion = o4 != null ? data[o4 + 16] : 0;

  final o5 = opening[5];
  final intervalMs = (logVersion >= 9 && o5 != null)
      ? _u16(data, o5 + 23)
      : _defaultIntervalMs;

  final rawMaxDepth = _u16(data, c0 + 4);
  final maxDepthMeters =
      (imperial ? rawMaxDepth * _feet : rawMaxDepth.toDouble()) / 10.0;

  // 2차: 샘플.
  final samples = <DiveSample>[];
  var elapsedMs = 0;
  for (
    var offset = 0;
    offset + _recordSize <= data.length;
    offset += _recordSize
  ) {
    if (_allZero(data, offset, _recordSize)) continue;

    final type = data[offset];
    if (type != _typeDiveSample && type != _typeAveloSample) continue;

    elapsedMs += intervalMs;

    // PNF는 레코드 첫 바이트가 종류라서 이후 필드가 한 칸씩 밀려 있다.
    final rawDepth = _u16(data, offset + 1);
    final depth = (imperial ? rawDepth * _feet : rawDepth.toDouble()) / 10.0;

    // 음수 온도는 별도 보정이 필요하다 (libdivecomputer의 처리를 그대로 따른다).
    var t = data[offset + 14];
    if (t > 127) t -= 256;
    if (t < 0) {
      t += 102;
      if (t > 0) t = 0;
    }
    final temperature = imperial ? (t - 32.0) * (5.0 / 9.0) : t.toDouble();

    samples.add(
      DiveSample(
        time: Duration(milliseconds: elapsedMs),
        depthMeters: depth,
        temperatureC: temperature,
      ),
    );
  }

  return ParsedDive(
    // 0은 번호가 아니다. 값이 없는 것으로 본다.
    number: number == 0 ? null : number,
    start: DateTime.fromMillisecondsSinceEpoch(ticks * 1000, isUtc: true),
    duration: Duration(seconds: _u24(data, c0 + 6)),
    maxDepthMeters: maxDepthMeters,
    sampleInterval: Duration(milliseconds: intervalMs),
    logVersion: logVersion,
    imperial: imperial,
    samples: samples,
  );
}
