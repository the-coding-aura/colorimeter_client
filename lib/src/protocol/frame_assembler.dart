import 'dart:typed_data';

import 'ls170_protocol.dart';

/// Reassembles notification chunks into complete [Ls170Frame]s.
///
/// Rules (ported from the hardware-tested Kotlin client):
/// * a chunk starting with `0xAB` starts a new frame and discards any partial
///   data;
/// * the frame length is derived from the type byte and the little-endian
///   length at bytes 6–7 (see [expectedLength]);
/// * bytes after a complete frame stay buffered.
final class Ls170FrameAssembler {
  /// Creates an assembler. The buffer is cleared when it grows beyond
  /// [maxBufferSize] without producing a frame.
  Ls170FrameAssembler({this.maxBufferSize = 512});

  /// AB44 frames are never shorter than this (8 header + 12 × int16 + 4 + RGB).
  static const int colorFrameMinLength = 39;

  /// Length of AB20 status frames.
  static const int statusFrameLength = 10;

  /// Length of AB40 device-info frames.
  static const int deviceInfoFrameLength = 40;

  /// Upper bound on buffered bytes.
  final int maxBufferSize;

  final BytesBuilder _buffer = BytesBuilder();

  /// Number of buffered bytes not yet part of a complete frame.
  int get bufferedLength => _buffer.length;

  /// Discards buffered bytes.
  void reset() => _buffer.clear();

  /// Feeds one notification [chunk]; returns the frames it completed.
  List<Ls170Frame> add(List<int> chunk) {
    if (chunk.isEmpty) return const [];
    if (chunk[0] == Ls170Commands.frameStart) _buffer.clear();
    _buffer.add(chunk);

    final frames = <Ls170Frame>[];
    var data = _buffer.toBytes();
    while (data.length >= 3 && data[0] == Ls170Commands.frameStart) {
      final needed = expectedLength(data);
      if (needed <= 0 || data.length < needed) break;
      frames.add(Ls170Frame(data.sublist(0, needed)));
      data = data.sublist(needed);
    }
    _buffer
      ..clear()
      ..add(data);
    if (_buffer.length > maxBufferSize) _buffer.clear();
    return frames;
  }

  /// Total frame length implied by the header in [buf], or −1 when unknown.
  static int expectedLength(List<int> buf) {
    if (buf.length < 2) return -1;
    final declared = buf.length >= 8 ? (buf[6] & 0xFF) | ((buf[7] & 0xFF) << 8) : null;
    switch (buf[1]) {
      case 0x44:
        if (declared == null) return colorFrameMinLength;
        final total = declared >= 30 && declared <= 200 ? declared + 8 : colorFrameMinLength;
        return total < colorFrameMinLength ? colorFrameMinLength : total;
      case 0x20:
        return statusFrameLength;
      case 0x40:
        return deviceInfoFrameLength;
      default:
        if (declared == null) return -1;
        return declared >= 4 && declared <= 200 ? declared + 8 : -1;
    }
  }
}
