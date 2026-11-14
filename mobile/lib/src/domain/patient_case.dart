/// Caso di teledermatologia del paziente, come restituito da `/api/cases`.
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

  /// Il medico può chiedere una nuova analisi.
  bool get canReanalyze =>
      this == waitingModel || this == analysisFailed || this == awaitingReview;
}

/// Massimo di foto per caso, come sul server.
const maxCaseImages = 4;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

String _text(Object? value) => value is String ? value : '';

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
    patientCode: json['patient_code'] as String?,
    updatedAt: _date(json['updated_at']),
  );

  final String id;
  final String code;
  final String bodySite;
  final CaseState state;
  final int version;
  final int imageCount;

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
    this.createdAt,
  });

  factory CaseReview.fromJson(Map<String, dynamic> json) => CaseReview(
    decision: ReviewDecision.parse(json['decision']),
    finalLabel: json['final_label'] as String?,
    patientMessage: _text(json['patient_message']),
    doctor: _text(json['doctor']),
    createdAt: _date(json['created_at']),
  );

  final ReviewDecision? decision;
  final String? finalLabel;
  final String patientMessage;
  final String doctor;
  final DateTime? createdAt;
}

class LabelScore {
  const LabelScore(this.label, this.score);

  final String label;
  final double score;
}

/// Risultato del modello per una foto. Visibile solo al medico.
class AnalysisImage {
  const AnalysisImage({
    required this.imageId,
    required this.labels,
    required this.modelName,
    this.overlayUrl,
  });

  factory AnalysisImage.fromJson(Map<String, dynamic> json) {
    final classification = json['classification'];
    final labels = classification is Map<String, dynamic>
        ? _rows(classification['labels'])
              .map(
                (r) => LabelScore(
                  _text(r['label']),
                  (r['score'] as num).toDouble(),
                ),
              )
              .toList()
        : <LabelScore>[];
    return AnalysisImage(
      imageId: json['image_id'] as String,
      labels: labels,
      modelName: classification is Map<String, dynamic>
          ? _text(classification['model_name'])
          : '',
      overlayUrl: json['overlay_url'] as String?,
    );
  }

  final String imageId;
  final List<LabelScore> labels;
  final String modelName;
  final String? overlayUrl;

  String? get topLabel => labels.isEmpty ? null : labels.first.label;
}

class CaseAnalysis {
  const CaseAnalysis({
    required this.id,
    required this.state,
    required this.images,
    this.failureCode,
  });

  factory CaseAnalysis.fromJson(Map<String, dynamic> json) => CaseAnalysis(
    id: json['id'] as String,
    state: _text(json['state']),
    failureCode: json['failure_code'] as String?,
    images: _rows(json['images']).map(AnalysisImage.fromJson).toList(),
  );

  final String id;
  final String state;
  final String? failureCode;
  final List<AnalysisImage> images;

  bool get completed => state == 'completed';
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

class CaseDetails extends CaseSummary {
  const CaseDetails({
    required super.id,
    required super.code,
    required super.bodySite,
    required super.state,
    required super.version,
    required super.imageCount,
    super.patientCode,
    super.updatedAt,
    this.createdAt,
    required this.notes,
    required this.images,
    required this.reviews,
    required this.analyses,
    required this.publishedSegmentations,
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

  CaseReview? get latestReview => reviews.isEmpty ? null : reviews.last;
  CaseAnalysis? get latestAnalysis => analyses.isEmpty ? null : analyses.first;
}
