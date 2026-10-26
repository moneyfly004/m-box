// ignore_for_file: avoid_print, directives_ordering
// 探针：验证 dio ResponseType.stream 能否正确读取内核 /traffic 持续流
// 用法：先启动内核，再 dart run tool/stream_probe.dart
import 'dart:convert';

import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:9090',
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));
  try {
    final resp = await dio.get('/traffic',
        options: Options(responseType: ResponseType.stream));
    print('status=${resp.statusCode} headers=${resp.headers.value('content-type')}');
    print('data type=${resp.data.runtimeType}');
    final stream = resp.data.stream as Stream<List<int>>;
    var lines = 0;
    await for (final chunk in stream) {
      final text = utf8.decode(chunk);
      print('chunk(${chunk.length}B): $text');
      lines++;
      if (lines >= 3) break;
    }
    print('OK $lines chunks');
  } catch (e) {
    print('FAIL: $e');
  }
}
