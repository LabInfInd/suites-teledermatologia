import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

const clinicalClasses = ['ACK', 'BCC', 'MEL', 'NEV', 'SCC', 'SEK'];
const dermoscopicClasses = ['AK', 'BCC', 'BKL', 'DF', 'MEL', 'NV', 'VASC'];

const gradcamWarning =
    'Mappa sperimentale del modello per la classe indicata, condivisa dal medico. '
    'Non è il contorno della lesione né una misura del rischio.';

/// Server in memoria con gli endpoint `/v1/session` e `/api` usati
/// dall'app, con le regole essenziali del contratto 2 dei casi
/// (`server/docs/CASE_GRADCAM.md`): token, `x-requested-with`, versione
/// attesa, ruoli, modalità, consenso Grad-CAM e revoca delle mappe.
class FakePlatformServer {
  FakePlatformServer({this.role = 'patient', this.caseContract = 2});

  String role;

  /// Versione del contratto annunciata da `/api/status`.
  int caseContract;
  final cases = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];

  /// URL di mappe che il server deve trattare come non più disponibili.
  final revoked = <String>{};
  int _ids = 0;

  late final http.Client client = MockClient(_handle);

  String _id() =>
      '00000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}';

  static List<Map<String, dynamic>> catalog(String mode) => [
    if (mode == 'clinical') ...[
      _model('clinical-convnextv2-tiny', 'ConvNeXt V2 clinico', mode, true),
      _model('clinical-dinov2-base', 'DINOv2 clinico', mode, false),
    ] else
      _model('dermoscopic-ftn', 'FTN 7 classi', mode, true, segmentation: true),
  ];

  static Map<String, dynamic> _model(
    String id,
    String name,
    String mode,
    bool isDefault, {
    bool segmentation = false,
  }) => {
    'id': id,
    'name': name,
    'mode': mode,
    'default': isDefault,
    'available': true,
    'classes': mode == 'clinical' ? clinicalClasses : dermoscopicClasses,
    'classification': true,
    'segmentation': segmentation,
    'explanation': 'gradcam',
    'intended_use': 'research_only_external_validation_required',
  };

  static String _defaultModel(String mode) =>
      mode == 'clinical' ? 'clinical-convnextv2-tiny' : 'dermoscopic-ftn';

  /// Caso con foto, inviato e con un'analisi completata.
  /// [mode] `null` crea un caso storico senza modalità.
  Map<String, dynamic> addAnalyzedCase({
    String? mode = 'clinical',
    int images = 1,
    String state = 'awaiting_review',
  }) {
    final caseId = _id();
    final data = cases[caseId] = {
      'id': caseId,
      'code': 'TD-2026-${caseId.substring(30).toUpperCase()}',
      'mode': mode,
      'body_site': 'Dorso',
      'notes': '',
      'state': state,
      'version': 3,
      'patient_code': 'paziente.uno',
      'created_at': '2026-11-14T10:00:00Z',
      'updated_at': '2026-11-14T10:05:00Z',
      'images': [
        for (var i = 0; i < images; i++)
          () {
            final imageId = _id();
            return {
              'id': imageId,
              'width': 100,
              'height': 80,
              'url': '/api/cases/$caseId/images/$imageId',
            };
          }(),
      ],
      'reviews': <Map<String, dynamic>>[],
      'analyses': <Map<String, dynamic>>[],
    };
    final run = _newAnalysis(
      data,
      mode: mode,
      modelId: mode == null ? null : _defaultModel(mode),
      target: null,
    );
    completeAnalysis(data, run: run);
    data['state'] = state;
    return data;
  }

  Map<String, dynamic> _newAnalysis(
    Map<String, dynamic> data, {
    required String? mode,
    required String? modelId,
    required String? target,
  }) {
    final run = {
      'id': _id(),
      'state': 'queued',
      'mode': mode,
      'model_id': modelId,
      'explanation_target': target,
      'failure_code': null,
      'created_at': '2026-11-14T10:01:00Z',
      'finished_at': null,
      'images': <Map<String, dynamic>>[],
    };
    (data['analyses'] as List<Map<String, dynamic>>).insert(0, run);
    return run;
  }

  /// Simula il worker: completa l'ultima analisi del caso. La classe
  /// predetta è NEV (clinico) o NV (dermatoscopico); Grad-CAM spiega
  /// `explanation_target` se richiesto, altrimenti la classe predetta.
  void completeAnalysis(
    Map<String, dynamic> data, {
    Map<String, dynamic>? run,
  }) {
    run ??= (data['analyses'] as List<Map<String, dynamic>>).first;
    final mode = run['mode'] as String?;
    final top = mode == 'dermoscopic' ? 'NV' : 'NEV';
    final ftn = run['model_id'] == 'dermoscopic-ftn';
    run['state'] = 'completed';
    run['finished_at'] = '2026-11-14T10:02:00Z';
    run['images'] = [
      for (final image in data['images'] as List)
        () {
          final base =
              '/api/cases/${data['id']}/analyses/${run!['id']}/images/${image['id']}';
          return {
            'image_id': image['id'],
            'input_sha256': 'f' * 64,
            'classification': {
              'model_name': ftn ? 'FTN 7 classi' : 'ConvNeXt V2 clinico',
              'model_version': 'test-1',
              'labels': [
                {'label': top, 'score': 0.8},
                {'label': 'MEL', 'score': 0.2},
              ],
            },
            'segmentation_available': ftn,
            'mask_url': ftn ? '$base/mask' : null,
            'overlay_url': ftn ? '$base/overlay' : null,
            'explanation': {
              'method': 'gradcam',
              'target_class': run['explanation_target'] ?? top,
              'status': 'available',
            },
            'heatmap_url': '$base/heatmap',
            'heatmap_overlay_url': '$base/heatmap_overlay',
            'heatmap_composite_url': '$base/heatmap_composite',
          };
        }(),
    ];
    if (data['state'] == 'queued') data['state'] = 'awaiting_review';
  }

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _detail(String message, int status) =>
      _json({'detail': message}, status);

  Map<String, dynamic>? _latestRun(Map<String, dynamic> data) {
    final runs = data['analyses'] as List<Map<String, dynamic>>;
    return runs.isEmpty ? null : runs.first;
  }

  static bool _explanationReady(Map<String, dynamic> item, String? label) {
    final e = item['explanation'] as Map<String, dynamic>?;
    return e != null &&
        e['method'] == 'gradcam' &&
        e['target_class'] == label &&
        {'available', 'no_positive_signal'}.contains(e['status']) &&
        item['heatmap_url'] != null &&
        item['heatmap_overlay_url'] != null &&
        item['heatmap_composite_url'] != null;
  }

  /// Mappe dell'ultima valutazione pubblicate al paziente, come il server.
  (List<Map<String, dynamic>>, List<Map<String, dynamic>>) _published(
    Map<String, dynamic> data,
  ) {
    final reviews = data['reviews'] as List<Map<String, dynamic>>;
    final review = reviews.isEmpty ? null : reviews.last;
    final run = (data['analyses'] as List<Map<String, dynamic>>)
        .where((r) => r['id'] == review?['analysis_id'])
        .firstOrNull;
    if (review == null ||
        run == null ||
        !{'approved', 'corrected'}.contains(review['decision']) ||
        run['state'] != 'completed' ||
        (data['mode'] != null && data['mode'] != run['mode'])) {
      return (const [], const []);
    }
    final segmentations = <Map<String, dynamic>>[];
    final explanations = <Map<String, dynamic>>[];
    for (final item in (run['images'] as List).cast<Map<String, dynamic>>()) {
      if (review['share_segmentation'] == true && item['mask_url'] != null) {
        segmentations.add({
          'image_id': item['image_id'],
          'mask_url': item['mask_url'],
          'overlay_url': item['overlay_url'],
        });
      }
      if (review['share_explanation'] == true &&
          _explanationReady(item, review['final_label'] as String?)) {
        explanations.add({
          'image_id': item['image_id'],
          'analysis_id': run['id'],
          'review_id': review['id'],
          'method': 'gradcam',
          'target_class': review['final_label'],
          'status': (item['explanation'] as Map)['status'],
          'heatmap_url': item['heatmap_url'],
          'overlay_url': item['heatmap_overlay_url'],
          'composite_url': item['heatmap_composite_url'],
          'warning': gradcamWarning,
        });
      }
    }
    return (segmentations, explanations);
  }

  /// Come il server: il paziente non riceve codice paziente né analisi.
  Map<String, dynamic> _view(Map<String, dynamic> data) {
    final view = {...data, 'image_count': (data['images'] as List).length}
      ..remove('upload_body');
    if (role != 'doctor') {
      view
        ..remove('patient_code')
        ..remove('analyses');
      final (segmentations, explanations) = _published(data);
      view['published_segmentations'] = segmentations;
      view['published_explanations'] = explanations;
    }
    return view;
  }

  Future<http.Response> _handle(http.Request r) async {
    requests.add(r);
    final path = r.url.path;
    final method = r.method;
    if (path == '/v1/session') {
      if (method == 'DELETE') return http.Response('', 204);
      return _json({
        'access_token': 'token-di-prova',
        'token_type': 'Bearer',
        'user': {
          'id': 'u1',
          'username': '$role.uno',
          'role': role,
          'active': true,
        },
      });
    }
    if (path == '/v1/models') return _json({'models': <Object>[]});
    if (r.headers['authorization'] != 'Bearer token-di-prova') {
      return _detail('Accedi per continuare.', 401);
    }
    if (method != 'GET' && r.headers['x-requested-with'] != 'Telederm') {
      return _detail('Richiesta non verificata.', 403);
    }
    if (path == '/api/status') {
      return _json({
        'demo': true,
        'max_images': 4,
        'max_upload_mb': 40,
        if (caseContract >= 2) ...{
          'case_contract_version': caseContract,
          'acquisition_modes': ['clinical', 'dermoscopic'],
        },
      });
    }
    if (path == '/api/models') {
      if (role != 'doctor') {
        return _detail('Operazione non consentita per questo account.', 403);
      }
      return _json({
        'schema_version': 1,
        'models': catalog(r.url.queryParameters['mode'] ?? 'clinical'),
      });
    }
    if (path == '/api/cases') {
      if (method == 'GET') {
        final visible = cases.values.where(
          (c) => role != 'doctor' || c['state'] != 'draft',
        );
        return _json({
          'items': visible.map(_view).toList(),
          'total': visible.length,
        });
      }
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (body['demo_confirmed'] != true ||
          !{'clinical', 'dermoscopic'}.contains(body['mode'])) {
        return _json({
          'detail': 'Controlla i campi inseriti.',
          'errors': [
            {'field': 'mode', 'message': 'Field required'},
          ],
        }, 422);
      }
      final caseId = _id();
      cases[caseId] = {
        'id': caseId,
        'code': 'TD-2026-${caseId.substring(30).toUpperCase()}',
        'mode': body['mode'],
        'body_site': body['body_site'],
        'notes': body['notes'],
        'state': 'draft',
        'version': 1,
        'created_at': '2026-11-14T10:00:00Z',
        'updated_at': '2026-11-14T10:00:00Z',
        'images': <Map<String, dynamic>>[],
        'reviews': <Map<String, dynamic>>[],
        'analyses': <Map<String, dynamic>>[],
      };
      return _json(_view(cases[caseId]!), 201);
    }
    final match = RegExp(r'^/api/cases/([^/]+)(/.*)?$').firstMatch(path);
    final data = match == null ? null : cases[match.group(1)];
    if (data == null) return _detail('Caso non trovato.', 404);
    final rest = match!.group(2) ?? '';
    if (method == 'GET' && rest.isEmpty) return _json(_view(data));
    if (method == 'GET') return _artifact(data, path, rest);

    // Il corpo multipart contiene i byte della foto: latin1 li conserva tutti.
    final multipart = r.headers['content-type']!.startsWith('multipart/');
    final raw = multipart ? latin1.decode(r.bodyBytes) : r.body;
    final body = multipart
        ? <String, dynamic>{
            'expected_version': int.parse(
              RegExp(
                r'name="expected_version"\r\n\r\n(\d+)',
              ).firstMatch(raw)!.group(1)!,
            ),
          }
        : jsonDecode(raw) as Map<String, dynamic>;
    if (body['expected_version'] != data['version']) {
      return _detail(
        'Il caso è stato aggiornato. Ricarica i dettagli prima di continuare.',
        409,
      );
    }
    final images = data['images'] as List<Map<String, dynamic>>;
    final state = data['state'] as String;
    switch ((method, rest)) {
      case ('POST', '/images'):
        final imageId = _id();
        images.add({
          'id': imageId,
          'width': 100,
          'height': 80,
          'url': '/api/cases/${data['id']}/images/$imageId',
        });
        data['upload_body'] = raw;
      case ('DELETE', final String p) when p.startsWith('/images/'):
        images.removeWhere((i) => i['id'] == p.substring(8));
      case ('PATCH', '/acquisition'):
        if (role != 'patient') {
          return _detail('Operazione non consentita per questo account.', 403);
        }
        if (state != 'draft' && state != 'needs_images') {
          return _detail(
            'La modalità può essere modificata dal paziente solo prima dell’invio.',
            409,
          );
        }
        if (state == 'needs_images' &&
            data['mode'] != null &&
            data['mode'] != body['mode']) {
          return _detail(
            'Le foto già inviate mantengono la modalità dichiarata.',
            409,
          );
        }
        data['mode'] = body['mode'];
      case ('POST', '/submit'):
        if (images.isEmpty) {
          return _detail(
            'Carica almeno una foto prima di inviare il caso.',
            400,
          );
        }
        if (data['mode'] == null) {
          return _detail(
            'Conferma la modalità clinical o dermoscopic prima dell’analisi.',
            409,
          );
        }
        _newAnalysis(
          data,
          mode: data['mode'] as String,
          modelId: _defaultModel(data['mode'] as String),
          target: null,
        );
        data['state'] = 'queued';
      case ('POST', '/reanalyze'):
        if (!{
          'waiting_model',
          'analysis_failed',
          'awaiting_review',
          'released',
        }.contains(state)) {
          return _detail(
            'Il caso non può essere analizzato in questo stato.',
            409,
          );
        }
        final mode = (body['mode'] ?? data['mode']) as String?;
        if (mode == null) {
          return _detail(
            'Conferma la modalità clinical o dermoscopic prima dell’analisi.',
            409,
          );
        }
        final modelId = (body['model_id'] ?? _defaultModel(mode)) as String;
        final model = catalog(
          mode,
        ).where((m) => m['id'] == modelId).firstOrNull;
        final target = body['explanation_target'] as String?;
        if (model == null ||
            (target != null && !(model['classes'] as List).contains(target))) {
          return _detail(
            'Modello o classe incompatibili con la modalità.',
            400,
          );
        }
        _newAnalysis(data, mode: mode, modelId: modelId, target: target);
        data['mode'] = mode;
        data['state'] = 'queued';
      case ('POST', '/reviews'):
        final decision = body['decision'];
        final run = _latestRun(data);
        if (decision == 'needs_images') {
          if (body['final_label'] != null ||
              body['share_segmentation'] == true ||
              body['share_explanation'] == true) {
            return _detail(
              'La richiesta di foto non deve includere classificazioni o mappe.',
              400,
            );
          }
          data['state'] = 'needs_images';
        } else {
          if (state != 'awaiting_review' ||
              run == null ||
              run['state'] != 'completed' ||
              data['mode'] == null ||
              run['mode'] != data['mode']) {
            return _detail(
              'Per validare occorre prima un’analisi completata.',
              409,
            );
          }
          final items = (run['images'] as List).cast<Map<String, dynamic>>();
          final tops = {
            for (final item in items)
              ((item['classification'] as Map)['labels'] as List)
                  .first['label'],
          };
          if (decision == 'approved' && !tops.contains(body['final_label'])) {
            return _detail(
              'Per una classificazione diversa dalla predizione seleziona «Correggi».',
              400,
            );
          }
          if (body['share_explanation'] == true &&
              !items.every(
                (i) => _explanationReady(i, body['final_label'] as String?),
              )) {
            return _detail(
              'Genera e verifica Grad-CAM per la classe finale su tutte le immagini prima di condividerla.',
              409,
            );
          }
          data['state'] = 'released';
        }
        (data['reviews'] as List<Map<String, dynamic>>).add({
          'id': _id(),
          'decision': decision,
          'final_label': body['final_label'],
          'patient_message': body['patient_message'],
          'share_segmentation': body['share_segmentation'] == true,
          'share_explanation': body['share_explanation'] == true,
          'analysis_id': run?['state'] == 'completed' ? run!['id'] : null,
          'doctor': 'medico.uno',
          'created_at': '2026-11-14T11:00:00Z',
        });
      default:
        return _detail('Non trovato.', 404);
    }
    data['version'] = (data['version'] as int) + 1;
    return _json(
      _view(data),
      method == 'POST' && (rest == '/images' || rest == '/reviews') ? 201 : 200,
    );
  }

  http.Response _png() => http.Response.bytes(
    pngBytes,
    200,
    headers: {'content-type': 'image/png'},
  );

  http.Response _artifact(Map<String, dynamic> data, String path, String rest) {
    if (rest.startsWith('/images/')) return _png();
    if (revoked.contains(path)) return _detail('Mappa non disponibile.', 404);
    if (role == 'patient') {
      final (segmentations, explanations) = _published(data);
      final allowed = {
        for (final s in segmentations) ...[s['mask_url'], s['overlay_url']],
        for (final e in explanations) ...[
          e['heatmap_url'],
          e['overlay_url'],
          e['composite_url'],
        ],
      };
      if (!allowed.contains(path)) {
        return _detail('Mappa non disponibile.', 404);
      }
    }
    return _png();
  }
}
