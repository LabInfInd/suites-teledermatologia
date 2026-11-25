import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/patient_case.dart';

const caseId = '00000000-0000-4000-8000-000000000001';
const imageId = '00000000-0000-4000-8000-000000000002';
const runId = '00000000-0000-4000-8000-000000000003';
const base = '/api/cases/$caseId/analyses/$runId/images/$imageId';

Map<String, dynamic> caseJson(Map<String, dynamic> extra) => {
  'id': caseId,
  'code': 'TD-2026-00000001',
  'body_site': '',
  'state': 'awaiting_review',
  'version': 4,
  'image_count': 1,
  'images': [
    {
      'id': imageId,
      'width': 300,
      'height': 200,
      'url': '/api/cases/$caseId/images/$imageId',
    },
  ],
  'reviews': <Object>[],
  ...extra,
};

Map<String, dynamic> imageResult({
  Object? explanation,
  bool maps = true,
  bool segmentation = false,
}) => {
  'image_id': imageId,
  'input_sha256': 'a' * 64,
  'classification': {
    'model_name': 'ConvNeXt',
    'model_version': '1.0',
    'labels': [
      {'label': 'NEV', 'score': 0.7},
      {'label': 'MEL', 'score': 0.3},
    ],
  },
  'segmentation_available': segmentation,
  'mask_url': segmentation ? '$base/mask' : null,
  'overlay_url': segmentation ? '$base/overlay' : null,
  'explanation': explanation,
  'heatmap_url': maps ? '$base/heatmap' : null,
  'heatmap_overlay_url': maps ? '$base/heatmap_overlay' : null,
  'heatmap_composite_url': maps ? '$base/heatmap_composite' : null,
};

void main() {
  test('caso storico: modalità nulla o sconosciuta non viene dedotta', () {
    expect(CaseDetails.fromJson(caseJson({'mode': null})).mode, isNull);
    expect(CaseDetails.fromJson(caseJson({})).mode, isNull);
    expect(CaseDetails.fromJson(caseJson({'mode': 'macro'})).mode, isNull);
    expect(
      CaseDetails.fromJson(caseJson({'mode': 'dermoscopic'})).mode,
      AcquisitionMode.dermoscopic,
    );
  });

  test('analisi con campi nulli e spiegazione assente', () {
    final data = CaseDetails.fromJson(
      caseJson({
        'mode': 'clinical',
        'analyses': [
          {
            'id': runId,
            'state': 'completed',
            'mode': null,
            'model_id': null,
            'explanation_target': null,
            'failure_code': null,
            'images': [imageResult(explanation: null, maps: false)],
          },
        ],
      }),
    );
    final run = data.latestAnalysis!;
    expect(run.mode, isNull);
    expect(run.modelId, isNull);
    expect(run.explanationTarget, isNull);
    final result = run.images.single;
    expect(result.explanation.status, 'not_available');
    expect(result.heatmapCompositeUrl, isNull);
    expect(result.hasSegmentation, isFalse);
    expect(run.explanationReadyFor('NEV'), isFalse);
  });

  test('Grad-CAM pronta solo per la classe spiegata, anche senza segnale', () {
    AnalysisImage parse(Object explanation) =>
        AnalysisImage.fromJson(imageResult(explanation: explanation));
    final available = parse({
      'method': 'gradcam',
      'target_class': 'NEV',
      'status': 'available',
    });
    expect(available.explanationReadyFor('NEV'), isTrue);
    expect(available.explanationReadyFor('MEL'), isFalse);
    expect(
      available.explanationReadyFor('NV'),
      isFalse,
      reason: 'nessuna equivalenza NEV/NV',
    );
    final empty = parse({
      'method': 'gradcam',
      'target_class': 'NEV',
      'status': 'no_positive_signal',
    });
    expect(empty.explanationReadyFor('NEV'), isTrue);
    expect(empty.explanation.hasSignal, isFalse);
    final failed = parse({
      'method': 'gradcam',
      'target_class': 'NEV',
      'status': 'failed',
    });
    expect(failed.explanationReadyFor('NEV'), isFalse);
  });

  test('segmentazione separata da Grad-CAM', () {
    final result = AnalysisImage.fromJson(
      imageResult(
        explanation: {
          'method': 'gradcam',
          'target_class': 'NV',
          'status': 'available',
        },
        segmentation: true,
      ),
    );
    expect(result.hasSegmentation, isTrue);
    expect(result.overlayUrl, '$base/overlay');
    expect(result.heatmapOverlayUrl, '$base/heatmap_overlay');
    expect(result.overlayUrl, isNot(result.heatmapOverlayUrl));
  });

  test('mappe pubblicate e consensi della revisione', () {
    final data = CaseDetails.fromJson(
      caseJson({
        'mode': 'clinical',
        'state': 'released',
        'reviews': [
          {
            'id': 'r1',
            'decision': 'corrected',
            'final_label': 'MEL',
            'patient_message': 'Messaggio.',
            'share_segmentation': false,
            'share_explanation': true,
            'analysis_id': runId,
            'doctor': 'medico',
          },
        ],
        'published_segmentations': <Object>[],
        'published_explanations': [
          {
            'image_id': imageId,
            'analysis_id': runId,
            'review_id': 'r1',
            'method': 'gradcam',
            'target_class': 'MEL',
            'status': 'available',
            'heatmap_url': '$base/heatmap',
            'overlay_url': '$base/heatmap_overlay',
            'composite_url': '$base/heatmap_composite',
            'warning': 'Mappa sperimentale.',
          },
        ],
      }),
    );
    expect(data.latestReview!.shareExplanation, isTrue);
    expect(data.latestReview!.shareSegmentation, isFalse);
    final map = data.publishedExplanations.single;
    expect(map.reviewId, data.latestReview!.id);
    expect(map.compositeUrl, '$base/heatmap_composite');
    expect(map.warning, 'Mappa sperimentale.');
    expect(data.imageById(map.imageId)!.aspectRatio, 1.5);
  });

  test('stato del server e catalogo', () {
    expect(
      ServerStatus.fromJson({
        'case_contract_version': 2,
        'acquisition_modes': ['clinical', 'dermoscopic'],
        'max_images': 4,
      }).supportsAcquisitionModes,
      isTrue,
    );
    expect(
      ServerStatus.fromJson({'max_images': 4}).supportsAcquisitionModes,
      isFalse,
    );
    final model = CatalogModel.tryParse({
      'id': 'dermoscopic-ftn',
      'name': 'FTN',
      'mode': 'dermoscopic',
      'default': true,
      'available': true,
      'classes': ['AK', 'NV'],
      'segmentation': true,
    });
    expect(model!.mode, AcquisitionMode.dermoscopic);
    expect(model.classes, ['AK', 'NV']);
    expect(model.segmentation, isTrue);
  });
}
