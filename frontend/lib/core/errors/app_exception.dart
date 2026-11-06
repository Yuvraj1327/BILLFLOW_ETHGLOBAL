import 'package:dio/dio.dart';

/// Every failure reaches the UI as an [AppException] (backend envelope: {"error": {code, message, details}}).
class AppException implements Exception {
  AppException(this.code, this.message, {this.status, this.details = const {}});
  final String code;
  final String message;
  final int? status;
  final Map<String, dynamic> details;

  bool get isNetwork => code == 'network' || code == 'timeout';
  bool get isUnauthorized => status == 401;

  factory AppException.fromDio(DioException e) {
    final res = e.response;
    final data = res?.data;
    if (data is Map && data['error'] is Map) {
      final err = Map<String, dynamic>.from(data['error'] as Map);
      return AppException((err['code'] ?? 'error').toString(), (err['message'] ?? 'Request failed').toString(),
          status: res?.statusCode, details: err['details'] is Map ? Map<String, dynamic>.from(err['details'] as Map) : const {});
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return AppException('timeout', 'The server took too long to respond. Please try again.');
      case DioExceptionType.connectionError:
        return AppException('network', 'Cannot reach the BillFlow server. Check your connection and API_BASE_URL.');
      default:
        return AppException('http_${res?.statusCode ?? 0}', 'Unexpected server response (${res?.statusCode ?? 'no status'}).',
            status: res?.statusCode);
    }
  }

  @override
  String toString() => message;
}

String errorText(Object e) => e is AppException ? e.message : 'Something went wrong: $e';
