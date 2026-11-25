import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/analysis_task.dart';
import 'package:teledermatologia/src/domain/model_catalog.dart';
import 'package:teledermatologia/src/domain/patient_case.dart';

import '../support/fake_platform_server.dart';

void main() {
  group('tipo di analisi', () {
    test('combinazioni modalità/task e valori sconosciuti', () {
      expect(AnalysisTask.forMode(AcquisitionMode.clinical), [
        AnalysisTask.skinLesion,
        AnalysisTask.woundType,
      ]);
      expect(AnalysisTask.forMode(AcquisitionMode.dermoscopic), [
        AnalysisTask.dermoscopicLesion,
      ]);
      expect(AnalysisTask.parse('wound_type'), AnalysisTask.woundType);
      // Nessun percorso inventato per valori assenti o sconosciuti.
      expect(AnalysisTask.parse('wound'), isNull);
      expect(AnalysisTask.parse(null), isNull);
    });

    test('stato del server: estensione presente o assente', () {
      final current = ServerStatus.fromJson({
        'case_contract_version': 2,
        'acquisition_modes': ['clinical', 'dermoscopic'],
        'analysis_task_contract_version': 1,
        'analysis_tasks': ['skin_lesion', 'wound_type', 'dermoscopic_lesion'],
      });
      expect(current.supportsAnalysisTasks, isTrue);
      expect(current.tasksFor(AcquisitionMode.clinical), [
        AnalysisTask.skinLesion,
        AnalysisTask.woundType,
      ]);
      expect(current.tasksFor(AcquisitionMode.dermoscopic), [
        AnalysisTask.dermoscopicLesion,
      ]);

      final previous = ServerStatus.fromJson({
        'case_contract_version': 2,
        'acquisition_modes': ['clinical', 'dermoscopic'],
        'analysis_tasks': null,
      });
      expect(previous.supportsAcquisitionModes, isTrue);
      expect(previous.supportsAnalysisTasks, isFalse);
      expect(previous.tasksFor(AcquisitionMode.clinical), isEmpty);
    });

    test('caso e analisi: analysis_task facoltativo', () {
      final data = CaseDetails.fromJson({
        'id': 'c1',
        'code': 'TD-1',
        'state': 'draft',
        'version': 1,
        'mode': 'clinical',
        'analysis_task': 'wound_type',
        'analyses': [
          {'id': 'r1', 'state': 'completed', 'analysis_task': 'wound_type'},
          {'id': 'r0', 'state': 'completed', 'analysis_task': null},
        ],
      });
      expect(data.analysisTask, AnalysisTask.woundType);
      expect(data.analyses.first.analysisTask, AnalysisTask.woundType);
      expect(data.analyses.last.analysisTask, isNull);
      expect(
        CaseSummary.fromJson({
          'id': 'c2',
          'state': 'draft',
          'version': 1,
          'mode': 'clinical',
        }).analysisTask,
        isNull,
      );
    });
  });

  group('catalogo', () {
    final wounds = CatalogModel.tryParse({
      'id': 'clinical-wounds-azh',
      'name': 'DINOv2 ferite',
      'mode': 'clinical',
      'task': 'wound_type',
      'scope': 'four_known_wound_types_only',
      'classes': woundClasses,
      'class_names_it': woundNamesIt,
      'available': true,
      'default': false,
      'segmentation': false,
      'explanation': 'gradcam',
      'intended_use': 'research',
    })!;
    final pad = CatalogModel.tryParse({
      'id': 'clinical-convnextv2-tiny',
      'name': 'ConvNeXt V2',
      'mode': 'clinical',
      'default': true,
      'classes': clinicalClasses,
    })!;

    test('campi del modello ferite', () {
      expect(wounds.task, AnalysisTask.woundType);
      expect(wounds.declaresTask, isTrue);
      expect(wounds.scope, 'four_known_wound_types_only');
      expect(wounds.isDefault, isFalse);
      expect(wounds.segmentation, isFalse);
      expect(wounds.explanation, 'gradcam');
      expect(wounds.nameOf('pressure'), 'Lesione da pressione');
    });

    test('server precedente: campi mancanti o nulli', () {
      // Senza task il modello segue il percorso delle lesioni della modalità.
      expect(pad.task, AnalysisTask.skinLesion);
      expect(pad.declaresTask, isFalse);
      expect(pad.classNamesIt, isEmpty);
      final sparse = CatalogModel.tryParse({
        'id': 'x',
        'name': null,
        'mode': 'dermoscopic',
        'classes': null,
        'class_names_it': null,
        'task': null,
      })!;
      expect(sparse.name, 'x');
      expect(sparse.classes, isEmpty);
      expect(sparse.task, AnalysisTask.dermoscopicLesion);
      expect(CatalogModel.tryParse({'name': 'senza id'}), isNull);
      expect(
        CatalogModel.tryParse({'id': 'futuro', 'mode': 'clinical', 'task': 'burns'})!
            .task,
        isNull,
      );
    });

    test('il percorso ferite non ripiega mai sul modello PAD', () {
      final disabled = CatalogModel.tryParse({
        'id': 'clinical-wounds-azh',
        'mode': 'clinical',
        'task': 'wound_type',
        'available': false,
      })!;
      expect(catalogTasks([pad, disabled], AcquisitionMode.clinical), [
        AnalysisTask.skinLesion,
        AnalysisTask.woundType,
      ]);
      expect(woundModel([pad, disabled]), isNull);
      expect(
        catalogModelsFor(
          [pad, disabled],
          AcquisitionMode.clinical,
          AnalysisTask.woundType,
        ),
        isEmpty,
      );
      expect(woundModel([pad, wounds])?.id, 'clinical-wounds-azh');
      // Catalogo precedente: nessun percorso ferite da proporre.
      expect(catalogTasks([pad], AcquisitionMode.clinical), [
        AnalysisTask.skinLesion,
      ]);
    });
  });

  group('classificazione', () {
    test('punteggi associati per etichetta, in qualsiasi ordine', () {
      final result = Classification.fromJson({
        'task': 'wound_type',
        'scope': 'four_known_wound_types_only',
        'class_names_it': woundNamesIt,
        'model_name': 'DINOv2 ferite',
        'labels': [
          {'label': 'surgical', 'score': 0.05},
          {'label': 'venous', 'score': 0.15},
          {'label': 'pressure', 'score': 0.62},
          {'label': 'diabetic', 'score': 0.18},
        ],
      });
      expect(result.isWound, isTrue);
      expect(result.topLabel, 'pressure');
      expect(result.labels.map((l) => l.label), [
        'pressure',
        'diabetic',
        'venous',
        'surgical',
      ]);
      expect(result.labels.first.score, 0.62);
      expect(result.nameOf('venous'), 'Ulcera venosa');
    });

    test('etichette sconosciute e campi mancanti non scartano il risultato', () {
      final result = Classification.fromJson({
        'labels': [
          {'label': 'nuova_classe', 'score': 0.4},
          {'label': 'SEK', 'score': 0.5},
          {'label': 'BKL'},
          {'score': 0.1},
        ],
      });
      expect(result.task, isNull);
      expect(result.labels.map((l) => l.label), ['SEK', 'nuova_classe', 'BKL']);
      expect(result.nameOf('nuova_classe'), 'nuova_classe');
      // Le sigle PAD e FTN restano distinte.
      expect(result.nameOf('SEK'), 'SEK');
      expect(result.nameOf('BKL'), 'BKL');
      expect(classDisplayName('NEV'), 'NEV');
      expect(classDisplayName('NV'), 'NV');
      // Senza class_names_it (paziente) restano i nomi italiani delle ferite.
      expect(classDisplayName('diabetic'), 'Ulcera diabetica');
      expect(Classification.fromJson(null).labels, isEmpty);
    });
  });
}
