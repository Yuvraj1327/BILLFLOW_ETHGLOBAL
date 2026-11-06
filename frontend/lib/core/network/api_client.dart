import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../errors/app_exception.dart';

typedef TokenGetter = Future<String?> Function();

/// Centralised HTTP client for the Step 3 FastAPI backend.
/// - injects the Supabase access token
/// - on 401 asks [refreshSession] once, then retries the request
/// - GET requests are retried (max 2) on network failures; mutating requests are NEVER retried automatically
class ApiClient {
  ApiClient({required this.tokenGetter, required this.refreshSession, Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 60),
              headers: {'Accept': 'application/json'},
            ));

  final Dio dio;
  final TokenGetter tokenGetter;
  /// Returns true when the session was refreshed and the request may be retried.
  final Future<bool> Function() refreshSession;

  Future<dynamic> _send(String method, String path,
      {Object? data, Map<String, dynamic>? query, bool auth = true, Duration? receiveTimeout}) async {
    var attempt = 0;
    var refreshed = false;
    while (true) {
      try {
        final token = auth ? await tokenGetter() : null;
        final res = await dio.request<dynamic>(path,
            data: data,
            queryParameters: query == null ? null : (Map.of(query)..removeWhere((k, v) => v == null)),
            options: Options(method: method, receiveTimeout: receiveTimeout, headers: {
              if (token != null) 'Authorization': 'Bearer $token',
            }));
        return res.data;
      } on DioException catch (e) {
        final ex = AppException.fromDio(e);
        if (ex.isUnauthorized && auth && !refreshed) {
          refreshed = true;
          if (await refreshSession()) continue;
        }
        if (ex.isNetwork && method == 'GET' && attempt < 2) {
          attempt++;
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
          continue;
        }
        throw ex;
      }
    }
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query, bool auth = true}) => _send('GET', path, query: query, auth: auth);
  Future<dynamic> post(String path, {Object? data, Map<String, dynamic>? query, bool auth = true, Duration? receiveTimeout}) =>
      _send('POST', path, data: data, query: query, auth: auth, receiveTimeout: receiveTimeout);
  Future<dynamic> patch(String path, {Object? data}) => _send('PATCH', path, data: data);
  Future<dynamic> put(String path, {Object? data}) => _send('PUT', path, data: data);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Multipart PDF upload (`file` field), used by invoice upload and AI extraction.
  Future<dynamic> uploadPdf(String path, List<int> bytes, String filename, {Duration? receiveTimeout}) {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: DioMediaType.parse('application/pdf')),
    });
    return _send('POST', path, data: form, receiveTimeout: receiveTimeout ?? const Duration(seconds: 120));
  }
}
