import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';

class PhotoProblem implements Exception {
  const PhotoProblem();
}

class ProcessedPhoto {
  const ProcessedPhoto(
    this.full,
    this.thumb,
    this.hash,
    this.thumbHash,
    this.width,
    this.height,
  );
  final Uint8List full, thumb;
  final String hash, thumbHash;
  final int width, height;
}

const sourceLimit = 20 * 1024 * 1024;
const _heic = MethodChannel('dev.soramaru/photos');

bool _isHeic(Uint8List bytes) {
  if (bytes.length < 16 ||
      String.fromCharCodes(bytes.sublist(4, 8)) != 'ftyp') {
    return false;
  }
  const brands = {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1'};
  final end = ByteData.sublistView(bytes).getUint32(0).clamp(0, bytes.length);
  if (brands.contains(String.fromCharCodes(bytes.sublist(8, 12)))) return true;
  for (var offset = 16; offset + 4 <= end && offset < 128; offset += 4) {
    if (brands.contains(
      String.fromCharCodes(bytes.sublist(offset, offset + 4)),
    )) {
      return true;
    }
  }
  return false;
}

Future<ProcessedPhoto> processPicked(XFile file, {bool avatar = false}) async {
  // Read under a hard cap even when a provider reports the wrong length.
  if (await file.length() > sourceLimit) throw const PhotoProblem();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (builder.length + chunk.length > sourceLimit) throw const PhotoProblem();
    builder.add(chunk);
  }
  var bytes = builder.takeBytes();
  if (_isHeic(bytes)) {
    try {
      bytes =
          await _heic.invokeMethod<Uint8List>('convertHeic', bytes) ??
          (throw const PhotoProblem());
    } on PlatformException {
      throw const PhotoProblem();
    } on MissingPluginException {
      throw const PhotoProblem();
    }
  }
  return compute(_convert, (bytes: bytes, avatar: avatar));
}

bool _png(Uint8List bytes) =>
    bytes.length >= 33 &&
    bytes[0] == 137 &&
    bytes[1] == 80 &&
    bytes[2] == 78 &&
    bytes[3] == 71 &&
    bytes[4] == 13 &&
    bytes[5] == 10 &&
    bytes[6] == 26 &&
    bytes[7] == 10;

void _checkPng(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var offset = 8;
  var first = true;
  while (offset + 12 <= bytes.length) {
    final size = view.getUint32(offset);
    final end = offset + size + 12;
    if (end > bytes.length) throw const PhotoProblem();
    final chunk = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (first && (chunk != 'IHDR' || size != 13)) throw const PhotoProblem();
    first = false;
    if (chunk == 'acTL' || chunk == 'fcTL' || chunk == 'fdAT') {
      throw const PhotoProblem();
    }
    if (chunk == 'IEND') {
      if (size == 0 && end == bytes.length) return;
      throw const PhotoProblem();
    }
    offset = end;
  }
  throw const PhotoProblem();
}

Future<ProcessedPhoto> _convert(({Uint8List bytes, bool avatar}) input) async {
  final bytes = input.bytes;
  if (bytes.isEmpty || bytes.length > sourceLimit) throw const PhotoProblem();
  final png = _png(bytes);
  final jpeg = bytes.length > 3 && bytes[0] == 255 && bytes[1] == 216;
  if (!png && !jpeg) throw const PhotoProblem();

  try {
    if (png) _checkPng(bytes);
    final image.Decoder decoder = png
        ? image.PngDecoder()
        : image.JpegDecoder();
    final shape = decoder.startDecode(bytes);
    if (shape == null ||
        shape.numFrames != 1 ||
        shape.width < 1 ||
        shape.height < 1 ||
        shape.width > 10240 ||
        shape.height > 10240 ||
        shape.width * shape.height > (png ? 16 : 32) * 1024 * 1024) {
      throw const PhotoProblem();
    }
    final longestSource = shape.width > shape.height
        ? shape.width
        : shape.height;
    final target = input.avatar ? 512 : 1920;
    final scale = longestSource >= target * 4
        ? 4
        : longestSource >= target * 2
        ? 2
        : 1;
    final decoded = jpeg
        ? image.decodeJpg(bytes, scale: scale, maxPixels: 32 * 1024 * 1024)
        : decoder.decode(bytes);
    if (decoded == null || decoded.numFrames != 1) throw const PhotoProblem();
    final upright = image.bakeOrientation(decoded);
    final longest = input.avatar ? 512 : 1920;
    final scaled = input.avatar
        ? image.copyResizeCropSquare(
            upright,
            size: [
              upright.width,
              upright.height,
              longest,
            ].reduce((a, b) => a < b ? a : b),
          )
        : _shrink(upright, longest);
    // Flatten transparency onto white and strip every source metadata field.
    final raster = image.Image(
      width: scaled.width,
      height: scaled.height,
      numChannels: 3,
    );
    image.fill(raster, color: image.ColorRgb8(255, 255, 255));
    image.compositeImage(raster, scaled);
    final full = _encode(raster, input.avatar ? 150000 : 800000, [
      86,
      81,
      75,
      68,
    ]);
    final thumb = input.avatar
        ? Uint8List(0)
        : _encode(_shrink(raster, 400), 90000, [78, 73, 65]);
    final hash = await Sha256().hash(full);
    final thumbHash = await Sha256().hash(thumb);
    return ProcessedPhoto(
      full,
      thumb,
      _hex(hash.bytes),
      _hex(thumbHash.bytes),
      raster.width,
      raster.height,
    );
  } on PhotoProblem {
    rethrow;
  } on Object {
    throw const PhotoProblem();
  }
}

String _hex(List<int> bytes) =>
    bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

image.Image _shrink(image.Image source, int length) {
  final longest = source.width > source.height ? source.width : source.height;
  if (longest <= length) return source;
  return image.copyResize(
    source,
    width: source.width >= source.height ? length : null,
    height: source.width < source.height ? length : null,
    interpolation: image.Interpolation.average,
  );
}

Uint8List _encode(image.Image raster, int cap, List<int> qualities) {
  for (final quality in qualities) {
    final result = image.encodeJpg(
      raster,
      quality: quality,
      chroma: image.JpegChroma.yuv420,
    );
    if (result.length <= cap) return result;
  }
  throw const PhotoProblem();
}
