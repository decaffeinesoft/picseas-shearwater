/// RFC 1055 SLIP 프레이밍.
///
/// Shearwater BLE 전송은 SLIP으로 프레임 경계를 잡는 것으로 알려져 있다.
/// SLIP 자체는 벤더 무관한 표준이라 여기서 확정적으로 구현해도 안전하다.
/// (벤더 종속적인 것은 프레임 *안에* 들어가는 페이로드이며, 그쪽은 probes.dart에서
///  '가설'로 다룬다.)
class Slip {
  static const int end = 0xC0;
  static const int esc = 0xDB;
  static const int escEnd = 0xDC;
  static const int escEsc = 0xDD;

  /// END 경계 없이 이스케이프만 적용한다. 프레임 앞뒤에 END를 몇 개 붙일지는
  /// 구현마다 달라서(선두 END는 보통 생략한다) 호출부가 정하게 둔다.
  static List<int> encodeBody(List<int> payload) {
    final out = <int>[];
    for (final b in payload) {
      switch (b) {
        case end:
          out
            ..add(esc)
            ..add(escEnd);
        case esc:
          out
            ..add(esc)
            ..add(escEsc);
        default:
          out.add(b);
      }
    }
    return out;
  }

  static List<int> encode(List<int> payload) => [
    end,
    ...encodeBody(payload),
    end,
  ];

  static List<int> decode(List<int> frame) {
    final out = <int>[];
    var escaped = false;
    for (final b in frame) {
      if (escaped) {
        out.add(switch (b) {
          escEnd => end,
          escEsc => esc,
          _ => b,
        });
        escaped = false;
      } else if (b == esc) {
        escaped = true;
      } else if (b != end) {
        out.add(b);
      }
    }
    return out;
  }
}

/// BLE notify는 MTU 단위로 잘려 오므로, END 바이트를 만날 때까지 모아야
/// 하나의 논리 프레임이 된다. 이 누적기가 없으면 응답을 "조각"으로 오해하게 된다.
class SlipAssembler {
  final List<int> _buf = [];

  /// notify 청크를 넣고, 완성된 프레임이 있으면 (디코딩된 상태로) 돌려준다.
  List<List<int>> feed(List<int> chunk) {
    final frames = <List<int>>[];
    for (final b in chunk) {
      if (b == Slip.end) {
        if (_buf.isNotEmpty) {
          frames.add(Slip.decode(List<int>.from(_buf)));
          _buf.clear();
        }
        // 연속된 END는 빈 프레임이므로 무시한다.
      } else {
        _buf.add(b);
      }
    }
    return frames;
  }

  /// SLIP이 아닐 경우를 대비해, 아직 프레임으로 닫히지 않은 잔여 바이트를 노출한다.
  List<int> get pending => List.unmodifiable(_buf);

  void reset() => _buf.clear();
}
