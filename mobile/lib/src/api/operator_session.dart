import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class OperatorFailure implements Exception {
  const OperatorFailure(this.message);
  final String message;
}

class ServerModel {
  const ServerModel({required this.id, required this.name, required this.mode});
  final String id;
  final String name;
  final String mode;
}

/// Token held only in memory. No credential is stored in build configuration.
class OperatorSession extends ChangeNotifier {
  OperatorSession({required this.baseUrl, required this._client});
  final Uri baseUrl;
  final http.Client _client;
  String? _token;
  List<ServerModel> _models = const [];
  String? get token => _token;
  bool get authenticated => _token != null;
  List<ServerModel> get models => List.unmodifiable(_models);
  Uri endpoint(String path) => baseUrl.replace(
    pathSegments: [
      ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ],
  );
  Map<String, String> get headers => {
    'authorization': 'Bearer ${_token ?? ''}',
    'accept': 'application/json',
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
      throw const OperatorFailure(
        'Accesso non riuscito. Verifica le credenziali e l’account medico.',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = data['access_token'];
    if (token is! String || token.isEmpty || data['token_type'] != 'Bearer') {
      throw const OperatorFailure('Risposta di accesso non valida.');
    }
    _token = token;
    try {
      final catalog = await _client
          .get(endpoint('/v1/models'), headers: headers)
          .timeout(const Duration(seconds: 30));
      if (catalog.statusCode != 200) {
        throw const OperatorFailure('Catalogo dei modelli non disponibile.');
      }
      final rows =
          (jsonDecode(catalog.body) as Map<String, dynamic>)['models']
              as List<dynamic>;
      _models = rows
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
    } catch (_) {
      await logout();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> logout() async {
    final old = _token;
    _token = null;
    _models = const [];
    notifyListeners();
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

  Future<Map<String, dynamic>> status(String id) async {
    final response = await _client
        .get(endpoint('/v1/submissions/$id'), headers: headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw const OperatorFailure(
        'Analisi non disponibile o sessione scaduta.',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Uint8List> artifact(String path) async {
    // Never send a token to an absolute or untrusted URL returned by a server.
    if (!RegExp(
      r'^/v1/submissions/[a-f0-9-]{36}/artifacts/(normalized_image|heatmap|heatmap_overlay|segmentation_mask|segmentation_overlay)$',
    ).hasMatch(path)) {
      throw const OperatorFailure('Indirizzo della mappa non valido.');
    }
    final response = await _client
        .get(endpoint(path), headers: headers)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200 ||
        !(response.headers['content-type'] ?? '').startsWith('image/png')) {
      throw const OperatorFailure('Mappa non disponibile.');
    }
    return response.bodyBytes;
  }
}
