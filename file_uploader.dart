import 'dart:developer';
import 'dart:io';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:audio_tech/utils/const.dart';
import 'package:image/image.dart' as img;
import '../../../controllers/auth_controller.dart';

/// A utility class for uploading files with support for compression, notifications, and retries.
class FileUploader {
  /// Callback triggered upon successful upload, providing the file URL.
  final Function(String url)? uploaded;

  FileUploader({this.uploaded}) {
    _initializeNotifications();
  }

  /// Initializes the notification system using the Awesome Notifications package.
  Future<void> _initializeNotifications() async {
    AwesomeNotifications().initialize(
      'resource://mipmap/ic_launcher',
      [
        NotificationChannel(
          channelKey: 'upload_channel',
          channelName: 'File Uploads',
          channelDescription: 'Notifications for file uploads',
          channelShowBadge: true,
          defaultColor: Color(0xFF9D50E8),
          ledColor: Colors.white,
          importance: NotificationImportance.High,
          playSound: true,
          enableVibration: true,
        )
      ],
    );
  }

  /// Displays a progress notification during file upload.
  Future<void> _showProgressNotification(
      int progress, String filePath, int notificationId) async {
    AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: notificationId,
        channelKey: 'upload_channel',
        title: 'Uploading file',
        body: 'File: $filePath',
        notificationLayout: NotificationLayout.ProgressBar,
        progress: progress.toDouble(),
      ),
    );
  }

  /// Displays a notification when file upload is complete.
  Future<void> _showCompleteNotification(
      String filePath, int notificationId) async {
    AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: notificationId,
        channelKey: 'upload_channel',
        title: 'Upload Complete',
        body: 'File: $filePath has been uploaded successfully.',
      ),
    );
  }

  /// Compresses an image file to reduce its size before upload.
  ///
  /// If the file is not an image or compression fails, the original file is returned.
  Future<File> _compressFile(File file) async {
    try {
      log('Attempting to compress file: ${file.path}');
      final image = img.decodeImage(await file.readAsBytes());
      if (image == null) {
        log('File is not a valid image; skipping compression.');
        return file;
      }

      final compressedImage = img.encodeJpg(image, quality: 80);
      final tempDir = Directory.systemTemp;
      final compressedFile = File('${tempDir.path}/${file.uri.pathSegments.last}')
        ..writeAsBytesSync(compressedImage);

      log('File compressed successfully: ${compressedFile.path}');
      return compressedFile;
    } catch (e) {
      log('Error during file compression: $e');
      return file; // Return the original file if compression fails.
    }
  }

  /// Uploads a file to the server with support for token regeneration on authentication failure.
  ///
  /// Displays notifications for upload progress and completion.
  Future<void> uploadFile(String filePath, String pathName) async {
    try {
      log('Starting file upload for: $filePath');

      // Get the access token from the AuthController.
      String accessToken = Get.put(AuthController()).user!.accessToken!;

      // Unique ID for notifications.
      int notificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Configure Dio for HTTP requests.
      dio.Dio dioClient = dio.Dio(
        dio.BaseOptions(
          headers: {'Authorization': "Bearer $accessToken"},
        ),
      );

      File file = File(filePath);
      String fileName = file.path.split('/').last;

      // Compress the file if it is an image.
      if (['jpg', 'jpeg', 'png'].any((ext) => fileName.endsWith(ext))) {
        file = await _compressFile(file);
      }

      // Create form data for the upload request.
      dio.FormData formData = dio.FormData.fromMap({
        'image': await dio.MultipartFile.fromFile(file.path, filename: fileName),
        'path': pathName,
      });

      // Make the POST request to upload the file.
      final res = await dioClient.post(
        '${Const.baseUrl}/media/upload',
        data: formData,
        onSendProgress: (int sent, int total) {
          int progress = ((sent / total) * 100).toInt();
          _showProgressNotification(progress, filePath, notificationId);
        },
      );

      if (res.data['msg'] == "UNAUTHENTICATED" ||
          res.data['status'] == "UNAUTHENTICATED" ||
          res.statusCode == 401) {
        log('Unauthorized access. Attempting token regeneration.');
        await Get.find<AuthController>().generateToken();
        return uploadFile(filePath, pathName); // Retry after regenerating token.
      } else if (res.statusCode == 200) {
        log('File uploaded successfully: ${res.data}');
        _showCompleteNotification(filePath, notificationId);
        uploaded?.call(res.data['url']);
      } else {
        log('Unexpected server response: ${res.statusCode} - ${res.data}');
      }
    } catch (e) {
      if (e is dio.DioException) {
        log('DioException occurred during upload: ${e.message}');
        log('Response: ${e.response?.data}');
        log('Request: ${e.requestOptions.data}');
        log('Headers: ${e.requestOptions.headers}');
      } else {
        log('Error during file upload: $e');
      }
    }
  }
}
