import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/ui/submission_result_page.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'mostra la classificazione e la spiegazione senza inventare segmentazione',
    (tester) async {
      const id = '0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b';
      final session = UserSession(
        baseUrl: Uri.parse('https://example.org'),
        client: MockClient((r) async {
          if (r.url.path.contains('/artifacts/')) {
            return http.Response.bytes(
              pngBytes,
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          return http.Response(
            jsonEncode({
              'state': 'completed',
              'result': {
                'classification': {
                  'model_name': 'DINOv2',
                  'labels': [
                    {'label': 'MEL', 'score': .7},
                  ],
                },
                'image': {'width': 120, 'height': 80},
                'explanation': {'status': 'available'},
                'artifacts': {
                  'normalized_image':
                      '/v1/submissions/$id/artifacts/normalized_image',
                  'heatmap_overlay':
                      '/v1/submissions/$id/artifacts/heatmap_overlay',
                },
              },
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SubmissionResultPage(session: session, submissionId: id),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Analisi completata'), findsOneWidget);
      expect(find.text('MEL: 70.0%'), findsOneWidget);
      expect(
        find.text('Questo modello non produce una segmentazione.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ferite: nomi italiani per etichetta, avviso sperimentale, Grad-CAM senza segmentazione',
    (tester) async {
      const id = '1b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b';
      final requests = <http.Request>[];
      final session = UserSession(
        baseUrl: Uri.parse('https://example.org'),
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.contains('/artifacts/')) {
            return http.Response.bytes(
              pngBytes,
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          return http.Response(
            jsonEncode({
              'state': 'completed',
              'mode': 'clinical',
              'model_id': 'clinical-wounds-azh',
              'result': {
                'classification': {
                  'task': 'wound_type',
                  'scope': 'four_known_wound_types_only',
                  'class_names_it': {
                    'diabetic': 'Ulcera diabetica',
                    'pressure': 'Lesione da pressione',
                    'surgical': 'Ferita chirurgica',
                    'venous': 'Ulcera venosa',
                  },
                  'model_name': 'DINOv2 ferite',
                  'labels': [
                    {'label': 'venous', 'score': .1},
                    {'label': 'diabetic', 'score': .7},
                    {'label': 'etichetta_futura', 'score': .05},
                    {'label': 'pressure', 'score': .15},
                  ],
                },
                'image': {'width': 120, 'height': 80},
                'segmentation': {'available': false},
                'explanation': {
                  'method': 'gradcam',
                  'target_class': 'diabetic',
                  'status': 'available',
                },
                'artifacts': {
                  'normalized_image':
                      '/v1/submissions/$id/artifacts/normalized_image',
                  'heatmap_overlay':
                      '/v1/submissions/$id/artifacts/heatmap_overlay',
                  'segmentation_overlay': null,
                },
              },
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SubmissionResultPage(session: session, submissionId: id),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wound-notice')), findsOneWidget);
      final lines = [
        'Ulcera diabetica: 70.0%',
        'Lesione da pressione: 15.0%',
        'Ulcera venosa: 10.0%',
        // Etichetta sconosciuta: mostrata, non scartata.
        'etichetta_futura: 5.0%',
      ];
      final tops = [
        for (final line in lines) tester.getTopLeft(find.text(line)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(find.text('Grad-CAM per: Ulcera diabetica'), findsOneWidget);
      expect(
        find.text('Questo modello non produce una segmentazione.'),
        findsOneWidget,
      );
      expect(find.text('Segmentazione separata'), findsNothing);
      expect(find.textContaining('rischio'), findsNothing);
      for (final r in requests) {
        expect(r.headers['authorization'], startsWith('Bearer'));
      }
      expect(tester.takeException(), isNull);
    },
  );
}
