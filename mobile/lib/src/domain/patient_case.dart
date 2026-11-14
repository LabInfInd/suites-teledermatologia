import 'acquisition_mode.dart';

/// Caso di teledermatologia del paziente, come restituito da `/api/cases`
/// (contratto 2, `server/docs/CASE_GRADCAM.md`).
///
/// Le regole (chi vede cosa, quando si può modificare) sono del server:
/// qui ci sono solo i dati e le etichette per l'interfaccia.
enum CaseState {
  draft('draft', 'In preparazione'),
  queued('queued', 'Analisi in coda'),
  waitingModel('waiting_model', 'In attesa del modello'),
  analysisFailed('analysis_failed', 'Analisi da ripetere'),
  awaitingReview('awaiting_review', 'In valutazione medica'),
  needsImages('needs_images', 'Nuove foto richieste'),
  released('released', 'Risposta disponibile'),
  unknown('', 'Stato sconosciuto');

  const CaseState(this.apiValue, this.label);

  final String apiValue;

  /// Stesse etichette dell'interfaccia web.
  final String label;

  static CaseState parse(Object? value) =>
      values.firstWhere((s) => s.apiValue == value, orElse: () => unknown);

  /// Il paziente può aggiungere foto e inviare il caso.
  bool get acceptsPatientPhotos => this == draft || this == needsImages;

  /// Il medico può chiedere una nuova analisi (anche dopo la pubblicazione).
  bool get canReanalyze =>
      this == waitingModel ||
      this == analysisFailed ||
      this == awaitingReview ||
      this == released;

  /// Analisi in corso: il dettaglio va ricaricato finché non cambia.
  bool get isAnalyzing => this == queued;
}

/// Modalità dichiarata, `null` per i casi storici senza modalità o per un
/// valore non riconosciuto: in quel caso va confermata, mai dedotta.
AcquisitionMode? parseAcquisitionMode(Object? value) =>
    AcquisitionMode.values.where((m) => m.apiValue == value).firstOrNull;

/// Massimo di foto per caso, come sul server.
const maxCaseImages = 4;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

String _text(Object? value) => value is String ? value : '';

String? _optional(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

List<Map<String, dynamic>> _rows(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

class CaseSummary {
  const CaseSummary({
    required this.id,
    required this.code,
    required this.bodySite,
    required this.state,
    required this.version,
    required this.imageCount,
    this.mode,
    this.patientCode,
    this.updatedAt,
  });

  factory CaseSummary.fromJson(Map<String, dynamic> json) => CaseSummary(
    id: json['id'] as String,
    code: _text(json['code']),
    bodySite: _text(json['body_site']),
    state: CaseState.parse(json['state']),
    version: json['version'] as int,
    imageCount: json['image_count'] as int? ?? 0,
    mode: parseAcquisitionMode(json['mode']),
    patientCode: json['patient_code'] as String?,
    updatedAt: _date(json['updated_at']),
  );

  final String id;
  final String code;
  final String bodySite;
  final CaseState state;
  final int version;
  final int imageCount;

  /// `null` nei casi storici: va confermata prima dell'analisi.
  final AcquisitionMode? mode;

  /// Presente solo per il medico.
  final String? patientCode;
  final DateTime? updatedAt;
}

class CaseList {
  const CaseList({required this.items, required this.total});

  factory CaseList.fromJson(Map<String, dynamic> json) => CaseList(
    items: _rows(json['items']).map(CaseSummary.fromJson).toList(),
    total: json['total'] as int? ?? 0,
  );

  final List<CaseSummary> items;
  final int total;
}

class CaseImage {
  const CaseImage({
    required this.id,
    required this.url,
    required this.width,
    required this.height,
  });

  factory CaseImage.fromJson(Map<String, dynamic> json) => CaseImage(
    id: json['id'] as String,
    url: json['url'] as String,
    width: json['width'] as int? ?? 0,
    height: json['height'] as int? ?? 0,
  );

  final String id;
  final String url;
  final int width;
  final int height;

  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;
}

enum ReviewDecision {
  approved('approved', 'Classificazione confermata'),
  corrected('corrected', 'Classificazione corretta'),
  needsImages('needs_images', 'Nuove foto richieste');

  const ReviewDecision(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static ReviewDecision? parse(Object? value) =>
      values.where((d) => d.apiValue == value).firstOrNull;
}

class CaseReview {
  const CaseReview({
    required this.decision,
    required this.finalLabel,
    required this.patientMessage,
    required this.doctor,
    this.id,
    this.analysisId,
    this.shareSegmentation = false,
    this.shareExplanation = false,
    this.createdAt,
  });

  factory CaseReview.fromJson(Map<String, dynamic> json) => CaseReview(
    id: json['id'] as String?,
    decision: ReviewDecision.parse(json['decision']),
    finalLabel: json['final_label'] as String?,
    patientMessage: _text(json['patient_message']),
    doctor: _text(json['doctor']),
    analysisId: json['analysis_id'] as String?,
    shareSegmentation: json['share_segmentation'] == true,
    shareExplanation: json['share_explanation'] == true,
    createdAt: _date(json['created_at']),
  );

  final String? id;
  final ReviewDecision? decision;
  final String? finalLabel;
  final String patientMessage;
  final String doctor;
  final String? analysisId;
  final bool shareSegmentation;
  final bool shareExplanation;
  final DateTime? createdAt;
}

class LabelScore {
  const LabelScore(this.label, this.score);

  final String label;
  final double score;
}

/// Metadati Grad-CAM di una foto analizzata.
class ExplanationInfo {
  const ExplanationInfo({required this.status, this.method, this.targetClass});

  factory ExplanationInfo.fromJson(Object? json) => json is Map<String, dynamic>
      ? ExplanationInfo(
          method: _optional(json['method']),
          targetClass: _optional(json['target_class']),
          status: _optional(json['status']) ?? 'not_available',
        )
      : const ExplanationInfo(status: 'not_available');

  final String? method;
  final String? targetClass;

  /// `available`, `no_positive_signal` (mappa nulla, non assenza di lesione)
  /// oppure un altro stato senza mappa.
  final String status;

  bool get hasSignal => status == 'available';
  bool get isUsable => status == 'available' || status == 'no_positive_signal';
}

/// Risultato del modello per una foto. Visibile solo al medico.
class AnalysisImage {
  const AnalysisImage({
    required this.imageId,
    required this.labels,
    required this.modelName,
    this.modelVersion = '',
    this.segmentationAvailable = false,
    this.maskUrl,
    this.overlayUrl,
    this.explanation = const ExplanationInfo(status: 'not_available'),
    this.heatmapUrl,
    this.heatmapOverlayUrl,
    this.heatmapCompositeUrl,
  });

  factory AnalysisImage.fromJson(Map<String, dynamic> json) {
    final classification = json['classification'];
    final info = classification is Map<String, dynamic>
        ? classification
        : const <String, dynamic>{};
    return AnalysisImage(
      imageId: json['image_id'] as String,
      labels: _rows(info['labels'])
          .map(
            (r) =>
                LabelScore(_text(r['label']), (r['score'] as num).toDouble()),
          )
          .toList(),
      modelName: _text(info['model_name']),
      modelVersion: _text(info['model_version']),
      segmentationAvailable: json['segmentation_available'] == true,
      maskUrl: _optional(json['mask_url']),
      overlayUrl: _optional(json['overlay_url']),
      explanation: ExplanationInfo.fromJson(json['explanation']),
      heatmapUrl: _optional(json['heatmap_url']),
      heatmapOverlayUrl: _optional(json['heatmap_overlay_url']),
      heatmapCompositeUrl: _optional(json['heatmap_composite_url']),
    );
  }

  final String imageId;
  final List<LabelScore> labels;
  final String modelName;
  final String modelVersion;

  /// Segmentazione (solo FTN): separata da Grad-CAM.
  final bool segmentationAvailable;
  final String? maskUrl;
  final String? overlayUrl;

  final ExplanationInfo explanation;
  final String? heatmapUrl;

  /// RGBA trasparente da sovrapporre una sola volta alla foto.
  final String? heatmapOverlayUrl;

  /// Foto già composta con Grad-CAM: non va sovrapposta di nuovo.
  final String? heatmapCompositeUrl;

  String? get topLabel => labels.isEmpty ? null : labels.first.label;

  bool get hasSegmentation =>
      segmentationAvailable && overlayUrl != null && maskUrl != null;

  /// Stessa condizione del server per condividere Grad-CAM su questa foto.
  bool explanationReadyFor(String? label) =>
      label != null &&
      explanation.method == 'gradcam' &&
      explanation.targetClass == label &&
      explanation.isUsable &&
      heatmapUrl != null &&
      heatmapOverlayUrl != null &&
      heatmapCompositeUrl != null;
}

class CaseAnalysis {
  const CaseAnalysis({
    required this.id,
    required this.state,
    required this.images,
    this.mode,
    this.modelId,
    this.explanationTarget,
    this.failureCode,
  });

  factory CaseAnalysis.fromJson(Map<String, dynamic> json) => CaseAnalysis(
    id: json['id'] as String,
    state: _text(json['state']),
    mode: parseAcquisitionMode(json['mode']),
    modelId: _optional(json['model_id']),
    explanationTarget: _optional(json['explanation_target']),
    failureCode: json['failure_code'] as String?,
    images: _rows(json['images']).map(AnalysisImage.fromJson).toList(),
  );

  final String id;
  final String state;

  /// `null` per le analisi storiche senza modalità.
  final AcquisitionMode? mode;
  final String? modelId;

  /// Classe richiesta per Grad-CAM; `null` = classe predetta per ogni foto.
  final String? explanationTarget;
  final String? failureCode;
  final List<AnalysisImage> images;

  bool get completed => state == 'completed';
  bool get isRunning => state == 'queued' || state == 'running';

  bool get hasSegmentation =>
      images.isNotEmpty && images.every((i) => i.hasSegmentation);

  bool explanationReadyFor(String? label) =>
      images.isNotEmpty && images.every((i) => i.explanationReadyFor(label));
}

/// Segmentazione che il medico ha scelto di condividere con il paziente.
class PublishedSegmentation {
  const PublishedSegmentation({
    required this.imageId,
    required this.overlayUrl,
  });

  factory PublishedSegmentation.fromJson(Map<String, dynamic> json) =>
      PublishedSegmentation(
        imageId: json['image_id'] as String,
        overlayUrl: json['overlay_url'] as String,
      );

  final String imageId;
  final String overlayUrl;
}

/// Grad-CAM che il medico ha scelto di condividere con il paziente.
class PublishedExplanation {
  const PublishedExplanation({
    required this.imageId,
    required this.reviewId,
    required this.targetClass,
    required this.status,
    required this.compositeUrl,
    required this.warning,
    this.analysisId,
    this.method = 'gradcam',
    this.heatmapUrl,
    this.overlayUrl,
  });

  factory PublishedExplanation.fromJson(Map<String, dynamic> json) =>
      PublishedExplanation(
        imageId: json['image_id'] as String,
        analysisId: json['analysis_id'] as String?,
        reviewId: _text(json['review_id']),
        method: _optional(json['method']) ?? 'gradcam',
        targetClass: _text(json['target_class']),
        status: _optional(json['status']) ?? 'available',
        heatmapUrl: _optional(json['heatmap_url']),
        overlayUrl: _optional(json['overlay_url']),
        compositeUrl: json['composite_url'] as String,
        warning: _text(json['warning']),
      );

  final String imageId;
  final String? analysisId;
  final String reviewId;
  final String method;
  final String targetClass;
  final String status;
  final String? heatmapUrl;
  final String? overlayUrl;

  /// Foto già composta con la mappa: si mostra e si scarica così com'è.
  final String compositeUrl;

  /// Avvertenza del server, da mostrare sempre accanto alla mappa.
  final String warning;
}

class CaseDetails extends CaseSummary {
  const CaseDetails({
    required super.id,
    required super.code,
    required super.bodySite,
    required super.state,
    required super.version,
    required super.imageCount,
    super.mode,
    super.patientCode,
    super.updatedAt,
    this.createdAt,
    required this.notes,
    required this.images,
    required this.reviews,
    required this.analyses,
    required this.publishedSegmentations,
    this.publishedExplanations = const [],
  });

  factory CaseDetails.fromJson(Map<String, dynamic> json) {
    final summary = CaseSummary.fromJson(json);
    return CaseDetails(
      id: summary.id,
      code: summary.code,
      bodySite: summary.bodySite,
      state: summary.state,
      version: summary.version,
      imageCount: summary.imageCount,
      mode: summary.mode,
      patientCode: summary.patientCode,
      updatedAt: summary.updatedAt,
      createdAt: _date(json['created_at']),
      notes: _text(json['notes']),
      images: _rows(json['images']).map(CaseImage.fromJson).toList(),
      reviews: _rows(json['reviews']).map(CaseReview.fromJson).toList(),
      analyses: _rows(json['analyses']).map(CaseAnalysis.fromJson).toList(),
      publishedSegmentations: _rows(json['published_segmentations'])
          .map(PublishedSegmentation.fromJson)
          .toList(),
      publishedExplanations: _rows(json['published_explanations'])
          .map(PublishedExplanation.fromJson)
          .toList(),
    );
  }

  final DateTime? createdAt;
  final String notes;
  final List<CaseImage> images;

  /// In ordine cronologico, come dal server.
  final List<CaseReview> reviews;

  /// Solo per il medico, dalla più recente.
  final List<CaseAnalysis> analyses;

  /// Solo per il paziente.
  final List<PublishedSegmentation> publishedSegmentations;

  /// Solo per il paziente; vuoto finché il medico non dà il consenso.
  final List<PublishedExplanation> publishedExplanations;

  CaseReview? get latestReview => reviews.isEmpty ? null : reviews.last;
  CaseAnalysis? get latestAnalysis => analyses.isEmpty ? null : analyses.first;

  CaseImage? imageById(String id) =>
      images.where((i) => i.id == id).firstOrNull;
}

/// Catalogo di `/api/models` (solo medico).
class CatalogModel {
  const CatalogModel({
    required this.id,
    required this.name,
    required this.mode,
    required this.classes,
    this.isDefault = false,
    this.available = true,
    this.segmentation = false,
  });

  factory CatalogModel.fromJson(Map<String, dynamic> json) => CatalogModel(
    id: json['id'] as String,
    name: _text(json['name']),
    mode: parseAcquisitionMode(json['mode']),
    classes: (json['classes'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    isDefault: json['default'] == true,
    available: json['available'] != false,
    segmentation: json['segmentation'] == true,
  );

  final String id;
  final String name;
  final AcquisitionMode? mode;
  final List<String> classes;
  final bool isDefault;
  final bool available;
  final bool segmentation;
}

/// `GET /api/status`: serve a rifiutare server senza il contratto 2.
class ServerStatus {
  const ServerStatus({
    required this.caseContractVersion,
    required this.acquisitionModes,
    required this.maxImages,
  });

  factory ServerStatus.fromJson(Map<String, dynamic> json) => ServerStatus(
    caseContractVersion: json['case_contract_version'] as int? ?? 1,
    acquisitionModes: (json['acquisition_modes'] as List? ?? const [])
        .map(parseAcquisitionMode)
        .whereType<AcquisitionMode>()
        .toList(),
    maxImages: json['max_images'] as int? ?? maxCaseImages,
  );

  static const requiredContract = 2;

  final int caseContractVersion;
  final List<AcquisitionMode> acquisitionModes;
  final int maxImages;

  bool get supportsAcquisitionModes =>
      caseContractVersion >= requiredContract && acquisitionModes.isNotEmpty;
}
