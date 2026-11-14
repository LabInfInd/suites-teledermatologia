import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

/// Server in memoria con gli endpoint `/v1/session` e `/api/cases` usati
/// dall'app, con le stesse regole essenziali del server reale: token,
/// intestazione `x-requested-with`, versione attesa e ruoli.
class FakePlatformServer {
  FakePlatformServer({this.role = 'patient'});

  String role;
  final cases = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  int _ids = 0;

  late final http.Client client = MockClient(_handle);

  String _id() =>
      '00000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}';

  /// Caso già inviato e analizzato, in attesa della valutazione del medico.
  Map<String, dynamic> addAnalyzedCase() {
    final caseId = _id(), imageId = _id(), runId = _id();
    final base = '/api/cases/$caseId/analyses/$runId/images/$imageId';
    return cases[caseId] = {
      'id': caseId,
      'code': 'TD-2026-ANALIZZ',
      'body_site': 'Dorso',
      'notes': '',
      'state': 'awaiting_review',
      'version': 3,
      'patient_code': 'paziente.uno',
      'created_at': '2026-11-14T10:00:00Z',
      'updated_at': '2026-11-14T10:05:00Z',
      'images': [
        {
          'id': imageId,
          'width': 100,
          'height': 80,
          'url': '/api/cases/$caseId/images/$imageId',
        },
      ],
      'reviews': <Map<String, dynamic>>[],
      'analyses': [
        {
          'id': runId,
          'state': 'completed',
          'failure_code': null,
          'images': [
            {
              'image_id': imageId,
              'classification': {
                'model_name': 'modello-di-prova',
                'model_version': 'test',
                'labels': [
                  {'label': 'NEV', 'score': 0.8},
                  {'label': 'MEL', 'score': 0.2},
                ],
              },
              'mask_url': '$base/mask',
              'overlay_url': '$base/overlay',
            },
          ],
        },
      ],
      'published_segmentations': <Map<String, dynamic>>[],
    };
  }

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  /// Come il server: il paziente non riceve il codice paziente né le analisi.
  Map<String, dynamic> _view(Map<String, dynamic> data) {
    final view = {...data, 'image_count': (data['images'] as List).length}
      ..remove('upload_body');
    if (role != 'doctor') {
      view
        ..remove('patient_code')
        ..remove('analyses');
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
      return _json({'detail': 'Accedi per continuare.'}, 401);
    }
    if (method != 'GET' && r.headers['x-requested-with'] != 'Telederm') {
      return _json({'detail': 'Richiesta non verificata.'}, 403);
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
      if (body['demo_confirmed'] != true) {
        return _json({'detail': 'Controlla i campi inseriti.'}, 422);
      }
      final caseId = _id();
      cases[caseId] = {
        'id': caseId,
        'code': 'TD-2026-${caseId.substring(30).toUpperCase()}',
        'body_site': body['body_site'],
        'notes': body['notes'],
        'state': 'draft',
        'version': 1,
        'created_at': '2026-11-14T10:00:00Z',
        'updated_at': '2026-11-14T10:00:00Z',
        'images': <Map<String, dynamic>>[],
        'reviews': <Map<String, dynamic>>[],
        'analyses': <Map<String, dynamic>>[],
        'published_segmentations': <Map<String, dynamic>>[],
      };
      return _json(_view(cases[caseId]!), 201);
    }
    final match = RegExp(r'^/api/cases/([^/]+)(/.*)?$').firstMatch(path);
    final data = match == null ? null : cases[match.group(1)];
    if (data == null) return _json({'detail': 'Caso non trovato.'}, 404);
    final rest = match!.group(2) ?? '';
    if (method == 'GET' && rest.isEmpty) return _json(_view(data));
    if (method == 'GET') {
      return http.Response.bytes(
        pngBytes,
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    // Il corpo multipart contiene i byte della foto: latin1 li conserva tutti.
    final multipart = r.headers['content-type']!.startsWith('multipart/');
    final raw = multipart ? latin1.decode(r.bodyBytes) : r.body;
    final expected = multipart
        ? int.parse(
            RegExp(r'name="expected_version"\r\n\r\n(\d+)')
                .firstMatch(raw)!
                .group(1)!,
          )
        : (jsonDecode(r.body) as Map<String, dynamic>)['expected_version']
              as int;
    if (expected != data['version']) {
      return _json({
        'detail': 'Il caso è stato aggiornato. Ricarica i dettagli prima di continuare.',
      }, 409);
    }
    final images = data['images'] as List<Map<String, dynamic>>;
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
      case ('POST', '/submit'):
        if (images.isEmpty) {
          return _json({
            'detail': 'Carica almeno una foto prima di inviare il caso.',
          }, 400);
        }
        data['state'] = 'queued';
      case ('POST', '/reanalyze'):
        data['state'] = 'queued';
      case ('POST', '/reviews'):
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        (data['reviews'] as List<Map<String, dynamic>>).add({
          'id': _id(),
          'decision': body['decision'],
          'final_label': body['final_label'],
          'patient_message': body['patient_message'],
          'share_segmentation': body['share_segmentation'],
          'doctor': 'medico.uno',
          'created_at': '2026-11-14T11:00:00Z',
        });
        data['state'] = body['decision'] == 'needs_images'
            ? 'needs_images'
            : 'released';
      default:
        return _json({'detail': 'Non trovato.'}, 404);
    }
    data['version'] = (data['version'] as int) + 1;
    return _json(
      _view(data),
      method == 'POST' && rest == '/images' ? 201 : 200,
    );
  }
}
