import 'acquisition_mode.dart';

/// Tipo di analisi richiesto, distinto dalla modalità di acquisizione
/// (`server/docs/WOUNDS.md`). Lo sceglie sempre l'utente: non viene mai
/// dedotto dall'immagine.
enum AnalysisTask {
  /// Lesioni cutanee in foto cliniche (modelli PAD).
  skinLesion('skin_lesion', AcquisitionMode.clinical),

  /// Ferite e ulcere in foto cliniche, per ricerca.
  woundType('wound_type', AcquisitionMode.clinical),

  /// Lesioni cutanee in dermatoscopia (FTN).
  dermoscopicLesion('dermoscopic_lesion', AcquisitionMode.dermoscopic);

  const AnalysisTask(this.apiValue, this.mode);

  /// Valore del campo `analysis_task` dei casi e del campo `task` del catalogo.
  final String apiValue;

  /// Unica modalità di acquisizione compatibile.
  final AcquisitionMode mode;

  /// `null` per valori assenti o sconosciuti: non si sostituiscono con un
  /// percorso diverso.
  static AnalysisTask? parse(Object? value) =>
      values.where((t) => t.apiValue == value).firstOrNull;

  static List<AnalysisTask> forMode(AcquisitionMode mode) =>
      values.where((t) => t.mode == mode).toList();

  /// Percorso che il server assegna quando il campo è omesso.
  static AnalysisTask defaultFor(AcquisitionMode mode) => switch (mode) {
    AcquisitionMode.clinical => skinLesion,
    AcquisitionMode.dermoscopic => dermoscopicLesion,
  };
}

/// Modello del percorso ferite: si invia sempre esplicitamente negli invii
/// rapidi e non viene mai sostituito dal modello predefinito PAD.
const woundModelId = 'clinical-wounds-azh';

/// Nomi italiani delle etichette ferite, usati solo se il server non
/// fornisce `class_names_it` (per esempio al paziente, che non vede il
/// catalogo). Le richieste usano sempre le etichette API originali.
const woundClassNamesIt = {
  'diabetic': 'Ulcera diabetica',
  'pressure': 'Lesione da pressione',
  'surgical': 'Ferita chirurgica',
  'venous': 'Ulcera venosa',
};

/// Avviso mostrato accanto ai punteggi del modello ferite.
const woundResearchNotice =
    'Classificazione sperimentale per ricerca su quattro tipi di ferita. '
    'Richiede valutazione medica.';

/// Nome leggibile di un'etichetta: prima i nomi del server, poi quelli noti
/// delle ferite; un'etichetta sconosciuta resta com'è, senza essere scartata.
/// Le sigle PAD e FTN (per esempio SEK/BKL, NEV/NV) restano distinte.
String classDisplayName(String label, [Map<String, String>? namesIt]) {
  final name = namesIt?[label] ?? woundClassNamesIt[label];
  if (name != null && name.isNotEmpty) return name;
  return label.isEmpty ? 'Etichetta non indicata' : label;
}

/// Mappa `class_names_it` del server; voci non testuali ignorate.
Map<String, String> parseClassNames(Object? value) => value is Map
    ? {
        for (final MapEntry(:key, :value) in value.entries)
          if (key is String && value is String && value.isNotEmpty) key: value,
      }
    : const {};
