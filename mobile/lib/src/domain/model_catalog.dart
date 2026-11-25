import 'acquisition_mode.dart';
import 'analysis_task.dart';

String _text(Object? value) => value is String ? value : '';

String? _optional(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

class LabelScore {
  const LabelScore(this.label, this.score);

  final String label;
  final double score;
}

/// `classification` di un risultato (`/v1/submissions` o analisi di un caso).
///
/// I punteggi restano associati all'etichetta API originale: le righe si
/// ordinano per punteggio, senza assumere posizioni fisse o un numero di
/// classi. I campi `task`, `scope` e `class_names_it` mancano sui server
/// precedenti.
class Classification {
  const Classification({
    required this.labels,
    this.modelName = '',
    this.modelVersion = '',
    this.taskValue,
    this.scope,
    this.classNamesIt = const {},
  });

  factory Classification.fromJson(Object? json) {
    final info = json is Map<String, dynamic>
        ? json
        : const <String, dynamic>{};
    final rows = info['labels'];
    final labels = [
      if (rows is List)
        for (final row in rows.whereType<Map<String, dynamic>>())
          if (row['label'] case final String label when label.isNotEmpty)
            LabelScore(label, (row['score'] as num?)?.toDouble() ?? 0),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return Classification(
      labels: labels,
      modelName: _text(info['model_name']),
      modelVersion: _text(info['model_version']),
      taskValue: _optional(info['task']),
      scope: _optional(info['scope']),
      classNamesIt: parseClassNames(info['class_names_it']),
    );
  }

  /// Dal punteggio più alto al più basso.
  final List<LabelScore> labels;
  final String modelName;
  final String modelVersion;
  final String? taskValue;
  final String? scope;
  final Map<String, String> classNamesIt;

  AnalysisTask? get task => AnalysisTask.parse(taskValue);
  bool get isWound => task == AnalysisTask.woundType;
  String? get topLabel => labels.isEmpty ? null : labels.first.label;

  String nameOf(String label) => classDisplayName(label, classNamesIt);
}

/// Modello del catalogo (`/api/models` o `/v1/models`), visibile solo al
/// medico. Sui server precedenti mancano `task`, `scope` e `class_names_it`.
class CatalogModel {
  const CatalogModel({
    required this.id,
    required this.name,
    required this.mode,
    required this.classes,
    this.isDefault = false,
    this.available = true,
    this.segmentation = false,
    this.taskValue,
    this.scope,
    this.classNamesIt = const {},
    this.explanation,
    this.intendedUse,
  });

  /// `null` per righe senza identificativo, che non si possono richiedere.
  static CatalogModel? tryParse(Map<String, dynamic> json) {
    final id = _optional(json['id']);
    if (id == null) return null;
    return CatalogModel(
      id: id,
      name: _optional(json['name']) ?? id,
      mode: AcquisitionMode.values
          .where((m) => m.apiValue == json['mode'])
          .firstOrNull,
      classes: (json['classes'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      isDefault: json['default'] == true,
      available: json['available'] != false,
      segmentation: json['segmentation'] == true,
      taskValue: _optional(json['task']),
      scope: _optional(json['scope']),
      classNamesIt: parseClassNames(json['class_names_it']),
      explanation: _optional(json['explanation']),
      intendedUse: _optional(json['intended_use']),
    );
  }

  static List<CatalogModel> parseList(Object? rows) => rows is List
      ? rows
            .whereType<Map<String, dynamic>>()
            .map(tryParse)
            .whereType<CatalogModel>()
            .toList()
      : const [];

  final String id;
  final String name;
  final AcquisitionMode? mode;
  final List<String> classes;
  final bool isDefault;
  final bool available;
  final bool segmentation;

  /// `task` dichiarato dal server; `null` sui server precedenti.
  final String? taskValue;
  final String? scope;
  final Map<String, String> classNamesIt;
  final String? explanation;
  final String? intendedUse;

  /// Tipo di analisi del modello. Senza `task` (server precedenti) vale il
  /// percorso delle lesioni della sua modalità; un task sconosciuto non
  /// corrisponde a nessun percorso.
  AnalysisTask? get task {
    final value = taskValue;
    if (value != null) return AnalysisTask.parse(value);
    final mode = this.mode;
    return mode == null ? null : AnalysisTask.defaultFor(mode);
  }

  /// Vero se il server ha dichiarato esplicitamente il task del modello:
  /// solo allora `analysis_task` si può inviare insieme al modello.
  bool get declaresTask => taskValue != null;

  String nameOf(String label) => classDisplayName(label, classNamesIt);
}

/// Tipi di analisi offerti dal catalogo per una modalità, nell'ordine
/// dell'enum. Un percorso compare anche se il suo modello non è disponibile,
/// così lo stato si mostra invece di sostituirlo con un altro modello.
List<AnalysisTask> catalogTasks(
  Iterable<CatalogModel> catalog,
  AcquisitionMode mode,
) {
  final tasks = {
    for (final model in catalog)
      if (model.mode == mode) ?model.task,
  };
  return AnalysisTask.forMode(mode).where(tasks.contains).toList();
}

/// Modelli disponibili per modalità e task.
List<CatalogModel> catalogModelsFor(
  Iterable<CatalogModel> catalog,
  AcquisitionMode mode,
  AnalysisTask task,
) => catalog
    .where((m) => m.available && m.mode == mode && m.task == task)
    .toList();

/// Modello del percorso ferite: `clinical-wounds-azh` se disponibile,
/// altrimenti un altro modello ferite disponibile; mai un modello PAD.
CatalogModel? woundModel(Iterable<CatalogModel> catalog) {
  final models = catalogModelsFor(
    catalog,
    AcquisitionMode.clinical,
    AnalysisTask.woundType,
  );
  return models.where((m) => m.id == woundModelId).firstOrNull ??
      models.firstOrNull;
}
