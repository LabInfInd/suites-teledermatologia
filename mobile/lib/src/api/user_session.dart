import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class SessionFailure implements Exception {
  const SessionFailure(this.message);
  final String message;
}

/// Ruoli che possono usare l'app. Gli amministratori usano solo il web.
enum UserRole { patient, doctor }

class ServerModel {
  const ServerModel({required this.id, required this.name, required this.mode});
  final String id;
  final String name;
  final String mode;
}

/// Token held only in memory. No credential is stored in build configuration.
class UserSession extends ChangeNotifier {
  UserSession({required this.baseUrl, required this._client});
  final Uri baseUrl;
  final http.Client _client;
  String? _token;
  UserRole? _role;
  String? _username;
  List<ServerModel> _models = const [];
  String? get token => _token;
  UserRole? get role => _role;
  String? get username => _username;
  bool get authenticated => _token != null;
  List<ServerModel> get models => List.unmodifiable(_models);
  http.Client get client => _client;
  Uri endpoint(String path) => baseUrl.replace(
    pathSegments: [
      ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ],
  );

  /// Intestazioni di ogni richiesta autenticata. `x-requested-with` è
  /// richiesta dal server per le scritture su `/api`.
  Map<String, String> get headers => {
    'authorization': 'Bearer ${_token ?? ''}',
    'accept': 'application/json',
    'x-requested-with': 'Telederm',
  };

  Future<void> login(String username, String password) async {
    final response = await _client
        .post(
          endpoint('/v1/session'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw SessionFailure(switch (response.statusCode) {
        401 => 'Accesso non riuscito. Verifica nome utente e password.',
        429 => 'Troppi tentativi. Riprova fra 15 minuti.',
        403 =>
          _serverMessage(response) ?? 'Questo account non può usare l’app.',
        _ => 'Accesso non riuscito. Riprova più tardi.',
      });
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final token = data['access_token'];
    if (token is! String || token.isEmpty || data['token_type'] != 'Bearer') {
      throw const SessionFailure('Risposta di accesso non valida.');
    }
    final user = data['user'];
    final role = switch (user is Map<String, dynamic> ? user['role'] : null) {
      'patient' => UserRole.patient,
      'doctor' => UserRole.doctor,
      _ => null,
    };
    _token = token;
    if (role == null) {
      await logout();
      throw const SessionFailure('Questo account non può usare l’app.');
    }
    _role = role;
    _username = (user as Map<String, dynamic>)['username'] as String?;
    if (role == UserRole.doctor) {
      try {
        _models = await _loadModels();
      } catch (_) {
        await logout();
        rethrow;
      }
    }
    notifyListeners();
  }

  Future<List<ServerModel>> _loadModels() async {
    final catalog = await _client
        .get(endpoint('/v1/models'), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (catalog.statusCode != 200) {
      throw const SessionFailure('Catalogo dei modelli non disponibile.');
    }
    final rows =
        (jsonDecode(utf8.decode(catalog.bodyBytes)) as Map<String, dynamic>)['models']
            as List<dynamic>;
    return rows
        .whereType<Map<String, dynamic>>()
        .where((r) => r['available'] == true)
        .map(
          (r) => ServerModel(
            id: r['id'] as String,
            name: r['name'] as String,
            mode: r['mode'] as String,
          ),
        )
        .toList();
  }

  static String? _serverMessage(http.Response response) {
    try {
      final error =
          (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)['error'];
      final message = error is Map<String, dynamic> ? error['message'] : null;
      return message is String && message.isNotEmpty ? message : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> logout() async {
    final old = _token;
    _clear();
    if (old != null) {
      try {
        await _client
            .delete(
              endpoint('/v1/session'),
              headers: {'authorization': 'Bearer $old'},
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        /* Local logout remains effective; remote token expires. */
      }
    }
  }

  /// Sessione scaduta o revocata sul server: torna all'accesso senza
  /// contattare di nuovo il server.
  void expire() {
    if (_token != null) _clear();
  }

  void _clear() {
    _token = null;
    _role = null;
    _username = null;
    _models = const [];
    notifyListeners();
  }

  Future<Map<String, dynamic>> status(String id) async {
    final response = await _client
        .get(endpoint('/v1/submissions/$id'), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401) expire();
    if (response.statusCode != 200) {
      throw const SessionFailure('Analisi non disponibile o sessione scaduta.');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Uint8List> artifact(String path) async {
    // Never send a token to an absolute or untrusted URL returned by a server.
    if (!RegExp(
      r'^/v1/submissions/[a-f0-9-]{36}/artifacts/(normalized_image|heatmap|heatmap_overlay|segmentation_mask|segmentation_overlay)$',
    ).hasMatch(path)) {
      throw const SessionFailure('Indirizzo della mappa non valido.');
    }
    final response = await _client
        .get(endpoint(path), headers: headers)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200 ||
        !(response.headers['content-type'] ?? '').startsWith('image/png')) {
      throw const SessionFailure('Mappa non disponibile.');
    }
    return response.bodyBytes;
  }
}
