import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class UploadedMedia {
  const UploadedMedia({required this.assetId, this.downloadUrl});

  final String assetId;
  final String? downloadUrl;
}

class MediaUpload {
  MediaUpload._();

  static String createAssetId() {
    final suffix = Random.secure()
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    return '${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  static Future<UploadedMedia> uploadAndWait(
    XFile image, {
    required String kind,
    void Function(double value)? onProgress,
  }) async {
    if (kind != 'product' && kind != 'store') {
      throw ArgumentError.value(kind, 'kind');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Sign in before uploading a product photo.');
    }
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('Choose an image smaller than 8 MiB.');
    }
    final format = _format(bytes);
    if (format == null) throw StateError('Use a JPEG, PNG, or WebP image.');

    final assetId = createAssetId();
    final root = kind == 'store' ? 'stores' : 'products';
    final path = '$root/quarantine/${user.uid}/$assetId';
    final task = FirebaseStorage.instance
        .ref(path)
        .putData(bytes, SettableMetadata(contentType: format.$1));
    await for (final snapshot in task.snapshotEvents) {
      if (snapshot.totalBytes > 0) {
        onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
      }
    }

    final media = FirebaseFirestore.instance
        .collection('mediaAssets')
        .doc('${user.uid}_$assetId');
    final result = await media
        .snapshots()
        .firstWhere((snapshot) {
          final status = snapshot.data()?['status'];
          return status == 'ready' || status == 'failed';
        })
        .timeout(const Duration(seconds: 90));
    final data = result.data()!;
    if (data['status'] != 'ready' ||
        data['mediaType'] != kind ||
        (kind == 'product' && data['downloadUrl'] is! String)) {
      throw StateError(
        'The photo could not be processed. Choose another image or try again.',
      );
    }
    return UploadedMedia(
      assetId: assetId,
      downloadUrl: data['downloadUrl'] as String?,
    );
  }

  static Future<String> uploadPanorama(
    XFile image, {
    required int tourId,
    required String assetId,
    void Function(double value)? onProgress,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before uploading a panorama.');
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty || bytes.length > 50 * 1024 * 1024) {
      throw StateError('Choose a panorama smaller than 50 MiB.');
    }
    final format = _format(bytes);
    if (format == null) throw StateError('Use a JPEG, PNG, or WebP panorama.');

    final path = 'tours/originals/${user.uid}/$tourId/$assetId';
    final task = FirebaseStorage.instance
        .ref(path)
        .putData(bytes, SettableMetadata(contentType: format.$1));
    await for (final snapshot in task.snapshotEvents) {
      if (snapshot.totalBytes > 0) {
        onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
      }
    }
    return path;
  }

  static (String, String)? _format(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return ('image/jpeg', 'jpg');
    }
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length >= png.length &&
        List.generate(png.length, (i) => bytes[i]).toString() ==
            png.toString()) {
      return ('image/png', 'png');
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return ('image/webp', 'webp');
    }
    return null;
  }
}
