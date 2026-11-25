import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../domain/acquisition_mode.dart';
import '../domain/analysis_task.dart';
import '../domain/captured_photo.dart';
import '../domain/patient_case.dart';
import 'user_session.dart';

class CasesFailure implements Exception {
  const CasesFailure(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// Il caso è cambiato sul server: va ricaricato prima di riprovare.
  bool get isConflict => statusCode == 409;
}

/// Invio rapido del medico, dallo storico `/api/mobile-submissions`.
class QuickSubmissionSummary {
  const QuickSubmissionSummary({
    required this.id,
    required this.caseCode,
    required this.mode,
    required this.state,
    this.topLabel,
    this.topScore,
    this.receivedAt,
  });

  factory QuickSubmissionSummary.fromJson(Map<String, dynamic> json) {
    final top = json['top_label'];
    return QuickSubmissionSummary(
      id: json['submission_id'] as String,
      caseCode: json['case_code'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      state: json['state'] as String? ?? '',
      topLabel: top is Map<String, dynamic>
          ? top['label'] as String?
          : top as String?,
      topScore: top is Map<String, dynamic>
          ? (top['score'] as num?)?.toDouble()
          : (json['top_score'] as num?)?.toDouble(),
      receivedAt: DateTime.tryParse(json['received_at'] as String? ?? '')
          ?.toLocal(),
    );
  }

  final String id;
  final String caseCode;
  final String mode;
  final String state;
  final String? topLabel;
  final double? topScore;
  final DateTime? receivedAt;
}

/// Endpoint `/api` condivisi con l'interfaccia web, usati con il token
/// della sessione. Le regole di accesso sono applicate dal server.
class CasesApi {
  CasesApi(this._session);

  final UserSession _session;

  static final _imagePath = RegExp(
    r'^/api/cases/[a-f0-9-]{36}/(images/[a-f0-9-]{36}|analyses/[a-f0-9-]{36}/images/[a-f0-9-]{36}/(mask|overlay|heatmap|heatmap_overlay|heatmap_composite))$',
  );

  /// Contratto e limiti dei casi; un server senza contratto 2 non permette
  /// di creare casi con la modalità dichiarata.
  Future<ServerStatus> status() async => ServerStatus.fromJson(
    await _json('GET', '/api/status') as Map<String, dynamic>,
  );

  /// Catalogo dei modelli per i casi (solo medico: il paziente non lo
  /// chiama mai). Contiene anche i modelli non disponibili, per mostrarne
  /// lo stato.
  Future<List<CatalogModel>> models(AcquisitionMode mode) async {
    final data = await _json(
      'GET',
      '/api/models',
      query: {'mode': mode.apiValue},
    ) as Map<String, dynamic>;
    return CatalogModel.parseList(data['models']);
  }

  Future<CaseList> list() async => CaseList.fromJson(
    await _json('GET', '/api/cases') as Map<String, dynamic>,
  );

  Future<CaseDetails> details(String id) async =>
      _case(await _json('GET', '/api/cases/$id'));

  /// La modalità è obbligatoria; il modello lo sceglie il server all'invio
  /// in base a modalità e tipo di analisi. [task] va passato solo ai server
  /// che dichiarano `analysis_task_contract_version`.
  Future<CaseDetails> create({
    required AcquisitionMode mode,
    AnalysisTask? task,
    required String bodySite,
    required String notes,
  }) async => _case(
    await _json(
      'POST',
      '/api/cases',
      body: {
        'mode': mode.apiValue,
        if (task != null) 'analysis_task': task.apiValue,
        'body_site': bodySite,
        'notes': notes,
        'demo_confirmed': true,
      },
    ),
  );

  /// Conferma o correzione del percorso da parte del paziente (bozza, o
  /// modalità storica mancante con nuove foto richieste). [task] omesso con
  /// la stessa modalità conserva la scelta già fatta sul server.
  Future<CaseDetails> setAcquisition(
    CaseDetails current,
    AcquisitionMode mode, {
    AnalysisTask? task,
  }) async => _case(
    await _json(
      'PATCH',
      '/api/cases/${current.id}/acquisition',
      body: {
        'expected_version': current.version,
        'mode': mode.apiValue,
        if (task != null) 'analysis_task': task.apiValue,
      },
    ),
  );

  Future<CaseDetails> uploadImage(
    CaseDetails current,
    CapturedPhoto photo,
  ) async {
    final request =
        http.MultipartRequest(
            'POST',
            _session.endpoint('/api/cases/${current.id}/images'),
          )
          ..headers.addAll(_session.headers)
          ..fields['expected_version'] = '${current.version}'
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              photo.bytes,
              // Nome generico: il nome originale del file non lascia il telefono.
              filename: 'foto.${photo.format.extension}',
              contentType: MediaType.parse(photo.format.mediaType),
            ),
          );
    return _case(await _send(request, timeout: const Duration(minutes: 2)));
  }

  Future<CaseDetails> removeImage(CaseDetails current, String imageId) async =>
      _case(
        await _json(
          'DELETE',
          '/api/cases/${current.id}/images/$imageId',
          body: {'expected_version': current.version},
        ),
      );

  Future<CaseDetails> submit(CaseDetails current) async => _case(
    await _json(
      'POST',
      '/api/cases/${current.id}/submit',
      body: {'expected_version': current.version},
    ),
  );

  /// Nuova analisi asincrona. [explanationTarget] `null` spiega la classe
  /// predetta di ogni foto; un'etichetta del modello la spiega su tutte.
  /// [task] omesso con un [modelId] esplicito: il server lo ricava dal
  /// modello; se forniti entrambi devono corrispondere.
  Future<CaseDetails> reanalyze(
    CaseDetails current, {
    AcquisitionMode? mode,
    AnalysisTask? task,
    String? modelId,
    String? explanationTarget,
  }) async => _case(
    await _json(
      'POST',
      '/api/cases/${current.id}/reanalyze',
      body: {
        'expected_version': current.version,
        if (mode != null) 'mode': mode.apiValue,
        if (task != null) 'analysis_task': task.apiValue,
        'model_id': ?modelId,
        'explanation_target': ?explanationTarget,
      },
    ),
  );

  Future<CaseDetails> review(
    CaseDetails current, {
    required ReviewDecision decision,
    required String? finalLabel,
    required String patientMessage,
    required bool shareSegmentation,
    required bool shareExplanation,
  }) async => _case(
    await _json(
      'POST',
      '/api/cases/${current.id}/reviews',
      body: {
        'expected_version': current.version,
        'decision': decision.apiValue,
        'final_label': finalLabel,
        'patient_message': patientMessage,
        'share_segmentation': shareSegmentation,
        'share_explanation': shareExplanation,
      },
    ),
  );

  Future<List<QuickSubmissionSummary>> quickSubmissions() async {
    final data =
        await _json('GET', '/api/mobile-submissions') as Map<String, dynamic>;
    final items = data['items'];
    return items is List
        ? items
              .whereType<Map<String, dynamic>>()
              .map(QuickSubmissionSummary.fromJson)
              .toList()
        : const [];
  }

  /// Foto o segmentazione di un caso. Il token viene inviato solo a
  /// percorsi del server riconosciuti, mai a URL assoluti.
  Future<Uint8List> image(String path) async {
    if (!_imagePath.hasMatch(path)) {
      throw const CasesFailure('Indirizzo dell’immagine non valido.');
    }
    final response = await _guard(
      _session.client.get(_session.endpoint(path), headers: _session.headers),
      const Duration(seconds: 60),
    );
    _check(response);
    if (!(response.headers['content-type'] ?? '').startsWith('image/')) {
      throw const CasesFailure('Immagine non disponibile.');
    }
    return response.bodyBytes;
  }

  CaseDetails _case(Object? json) =>
      CaseDetails.fromJson(json as Map<String, dynamic>);

  Future<Object?> _json(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) {
    // I parametri di query vanno separati: endpoint() codifica il percorso.
    final uri = _session.endpoint(path);
    final request = http.Request(
      method,
      query == null ? uri : uri.replace(queryParameters: query),
    )..headers.addAll(_session.headers);
    if (body != null) {
      request
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(body);
    }
    return _send(request);
  }

  Future<Object?> _send(
    http.BaseRequest request, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _guard(
      _session.client.send(request).then(http.Response.fromStream),
      timeout,
    );
    _check(response);
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<http.Response> _guard(
    Future<http.Response> call,
    Duration timeout,
  ) async {
    try {
      return await call.timeout(timeout);
    } on TimeoutException {
      throw const CasesFailure('Il server non ha risposto in tempo. Riprova.');
    } on HandshakeException {
      throw const CasesFailure(
        'Il certificato del server non è valido o non è attendibile.',
      );
    } on SocketException {
      throw const CasesFailure(
        'Impossibile raggiungere il server. Verifica la connessione.',
      );
    } on http.ClientException {
      throw const CasesFailure(
        'Impossibile raggiungere il server. Verifica la connessione.',
      );
    }
  }

  void _check(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    if (status == 401) {
      _session.expire();
      throw const CasesFailure(
        'Sessione scaduta. Accedi di nuovo.',
        statusCode: 401,
      );
    }
    throw CasesFailure(
      _detail(response) ??
          switch (status) {
            403 => 'Operazione non consentita per questo account.',
            404 => 'Caso non trovato.',
            413 => 'La foto è troppo grande per il server.',
            >= 500 => 'Errore del server. Riprova più tardi.',
            _ => 'Richiesta non riuscita (HTTP $status).',
          },
      statusCode: status,
    );
  }

  /// Messaggio del server: `{"detail": "..."}` su `/api`, `{"error": {...}}`
  /// sugli endpoint `/v1` e dal middleware.
  static String? _detail(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return null;
      final detail = data['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      final error = data['error'];
      final message = error is Map<String, dynamic> ? error['message'] : null;
      return message is String && message.isNotEmpty ? message : null;
    } on FormatException {
      return null;
    }
  }
}
