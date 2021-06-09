import 'dart:developer';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

const supportedFileNames = ['jpg', 'jpeg', 'png', 'tga', 'gif', 'cur', 'ico'];
mixin ImageCacheManager on BaseCacheManager {
  /// Returns a resized image file to fit within maxHeight and maxWidth. It
  /// tries to keep the aspect ratio. It stores the resized image by adding
  /// the size to the key or url. For example when resizing
  /// https://via.placeholder.com/150 to max width 100 and height 75 it will
  /// store it with cacheKey resized_w100_h75_https://via.placeholder.com/150.
  ///
  /// When the resized file is not found in the cache the original is fetched
  /// from the cache or online and stored in the cache. Then it is resized
  /// and returned to the caller.
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    if (maxHeight == null && maxWidth == null) {
      yield* getFileStream(url,
          key: key, headers: headers, withProgress: withProgress);
      return;
    }
    key ??= url;
    var resizedKey = 'resized';
    if (maxWidth != null) resizedKey += '_w$maxWidth';
    if (maxHeight != null) resizedKey += '_h$maxHeight';
    resizedKey += '_$key';

    var fromCache = await getFileFromCache(resizedKey);
    if (fromCache != null) {
      yield fromCache;
      if (fromCache.validTill.isAfter(DateTime.now())) {
        return;
      }
      withProgress = false;
    }
    var runningResize = _runningResizes[resizedKey];
    if (runningResize == null) {
      runningResize = _fetchedResizedFile(
        url,
        key,
        resizedKey,
        headers,
        withProgress,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ).asBroadcastStream();
      _runningResizes[resizedKey] = runningResize;
    }
    yield* runningResize;
    _runningResizes.remove(resizedKey);
  }

  final Map<String, Stream<FileResponse>> _runningResizes = {};

  Stream<FileResponse> _fetchedResizedFile(
    String url,
    String originalKey,
    String resizedKey,
    Map<String, String>? headers,
    bool withProgress, {
    int? maxWidth,
    int? maxHeight,
  }) async* {
    await for (var response in getFileStream(
      url,
      key: originalKey,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (response is DownloadProgress) {
        yield response;
      }
      if (response is FileInfo) {
        /*yield await compute<ResizeImageInfo, FileResponse>(
          _resizeImageFile,
          ResizeImageInfo(
            originalFile: response,
            key: resizedKey,
            cacheManager: this,
            maxHeight: maxHeight,
            maxWidth: maxWidth,
          ),
          debugLabel: 'computeSizeChange',
        ); */
        yield await _resizeImageFile(ResizeImageInfo(
          originalFile: response,
          key: resizedKey,
          cacheManager: this,
          maxHeight: maxHeight,
          maxWidth: maxWidth,
        ));
      }
    }
  }
}

class ResizeImageInfo {
  final FileInfo originalFile;
  final String key;
  int? maxWidth;
  int? maxHeight;
  final BaseCacheManager cacheManager;
  ResizeImageInfo({
    required this.originalFile,
    required this.key,
    required this.cacheManager,
    this.maxWidth,
    this.maxHeight,
  });
}

Future<FileInfo> _resizeImageFile(ResizeImageInfo info) async {
  Timeline.startSync(
    '_resizeImageFile',
    arguments: {'file': info.originalFile.file.path},
  );
  var originalFileName = info.originalFile.file.path;
  var fileExtension = originalFileName.split('.').last;
  if (!supportedFileNames.contains(fileExtension)) {
    return info.originalFile;
  }

  Timeline.startSync('decodeImage');
  Timeline.startSync('readOriginalFile');
  final imageBytes = await info.originalFile.file.readAsBytes();
  Timeline.finishSync();
  var image = (await compute<List<int>, Image?>(
    decodeImage,
    imageBytes,
    debugLabel: 'computeDecodeImage',
  ))!;
  Timeline.finishSync();
  if (info.maxWidth != null && info.maxHeight != null) {
    var resizeFactorWidth = image.width / info.maxWidth!;
    var resizeFactorHeight = image.height / info.maxHeight!;
    var resizeFactor = max(resizeFactorHeight, resizeFactorWidth);

    info.maxWidth = (image.width / resizeFactor).round();
    info.maxHeight = (image.height / resizeFactor).round();
  }

  Timeline.startSync('copyResize');
  var resized = copyResize(image, width: info.maxWidth, height: info.maxHeight);
  Timeline.finishSync();
  Timeline.startSync('encodeNamedImage');
  var resizedFile = encodeNamedImage(resized, originalFileName)!;
  Timeline.finishSync();
  var maxAge = info.originalFile.validTill.difference(DateTime.now());

  var file = await info.cacheManager.putFile(
    info.originalFile.originalUrl,
    Uint8List.fromList(resizedFile),
    key: info.key,
    maxAge: maxAge,
    fileExtension: fileExtension,
  );

  Timeline.finishSync();

  return FileInfo(
    file,
    info.originalFile.source,
    info.originalFile.validTill,
    info.originalFile.originalUrl,
  );
}
