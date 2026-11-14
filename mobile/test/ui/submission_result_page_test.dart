import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/operator_session.dart';
import 'package:teledermatologia/src/ui/submission_result_page.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'mostra la classificazione e la spiegazione senza inventare segmentazione',
    (tester) async {
      const id = '0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b';
      final session = OperatorSession(
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
}
