import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/http_submission_api.dart';
import 'package:teledermatologia/src/api/simulated_server.dart';
import 'package:teledermatologia/src/domain/submission.dart';

import '../support/fakes.dart';

void main() {
  final request = sampleRequest();

  HttpSubmissionApi apiFor(SimulatedServerClient client) => HttpSubmissionApi(
    client: client,
    baseUrl: Uri.parse('https://server-simulato.invalid'),
    isSimulated: true,
    wait: (_) async {},
  );

  SimulatedServerClient server(SimulatedScenario scenario) => SimulatedServerClient(
    scenario: scenario,
    bytesPerSecond: 0,
    responseDelay: Duration.zero,
  );

  test('le conferme simulate sono riconoscibili e idempotenti', () async {
    final api = apiFor(server(SimulatedScenario.success));

    final first = await api.submit(request);
    final replay = await api.submit(request);

    expect(first.simulated, isTrue);
    expect(first.serverReference, startsWith('SIMULATO-'));
    expect(first.submissionId, request.submissionId);
    expect(first.caseCode, request.caseCode);
    expect(first.mode, request.mode);
    expect(replay.serverReference, first.serverReference);
  });

  test('lo scenario flaky riesce al ritentativo automatico', () async {
    final progress = <SubmissionProgress>[];
    final receipt = await apiFor(server(SimulatedScenario.flaky)).submit(request, onProgress: progress.add);
    expect(receipt.simulated, isTrue);
    expect(progress.where((p) => p.phase == SubmissionPhase.waitingToRetry), hasLength(1));
  });

  test('gli scenari di errore producono gli errori previsti', () async {
    Future<SubmissionFailureKind> kindFor(SimulatedScenario scenario) async {
      try {
        await apiFor(server(scenario)).submit(request);
      } on SubmissionFailure catch (failure) {
        return failure.kind;
      }
      fail('Era atteso un errore per ${scenario.name}');
    }

    expect(await kindFor(SimulatedScenario.offline), SubmissionFailureKind.network);
    expect(await kindFor(SimulatedScenario.rejected), SubmissionFailureKind.rejected);
    expect(await kindFor(SimulatedScenario.serverError), SubmissionFailureKind.serverError);
  });

  test('gli scenari corrispondono ai valori di configurazione', () {
    for (final scenario in SimulatedScenario.values) {
      expect(SimulatedScenario.fromConfigValue(scenario.configValue), scenario);
    }
    expect(SimulatedScenario.fromConfigValue('altro'), isNull);
  });
}
