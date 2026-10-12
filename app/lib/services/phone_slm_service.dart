import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';

class PhoneSlmService {
  static InferenceModel? _model;
  static InferenceModelSession? _session;

  static Future<void> ensureModelLoaded({
    required void Function(String log) onLog,
    required String huggingFaceToken,
    void Function(double progress)? onProgress,
  }) async {
    if (_model != null) return;

    // flutter_gemma 1.x ships NO inference engine in the core package.
    // A .task model (what we download below) needs the MediaPipe engine
    // registered here, or install fails with "No inference engine can
    // handle this model (ModelFileType.task)".
    await FlutterGemma.initialize(
      huggingFaceToken: huggingFaceToken,
      inferenceEngines: [MediaPipeEngine()],
    );

    onLog(
      'Downloading/loading on-device model (first run only)...',
    );

    const primaryModelUrl =
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4.task';

    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
    ).fromNetwork(primaryModelUrl).withProgress((progress) {
      onProgress?.call(progress.toDouble());

      if (progress % 20 < 1) {
        onLog(
          'Model download: ${progress.toStringAsFixed(0)}%',
        );
      }
    }).install();

    _model = await FlutterGemma.getActiveModel(
      maxTokens: 1024, // prompt (summary+chunk) + answer must fit
    );


    onLog('On-device model loaded and ready.');
  }

  static Future<String> dispatch({
    required String prompt, // built by buildSummaryPrompt (shared w/ laptop)
  }) async {
    if (_model == null) {
      throw Exception(
        'Model not loaded yet — call ensureModelLoaded() first.',
      );
    }

    final message = Message(
      text: prompt,
    );

    // A FRESH session per step, closed afterwards. A reused session keeps
    // every earlier prompt+answer in its context: with maxTokens 512 that
    // budget runs out after a few steps (answers get cut short), and the
    // phone's answer would depend on history the laptop's Ollama calls
    // (stateless) never see. State belongs in TaskState, not in a hidden
    // model session.
    final session = await _model!.createSession();
    final String response;
    try {
      await session.addQueryChunk(message);
      response = await session.getResponse();
    } finally {
      await session.close();
    }

    if (response.trim().isEmpty) {
      throw Exception(
        'On-device model returned an empty response',
      );
    }

    return response.trim();
  }

  /* static Future<String> dispatch({
    required int step,
    required String idempotencyKey,
  }) async {
    if (_session == null) {
      throw Exception(
        'Model not loaded yet — call ensureModelLoaded() first.',
      );
    }

    final prompt =
        'You are helping test a distributed offline AI agent handoff '
        'system built for low-connectivity regions like Malawi. '
        'This is step $step of a 10-step task. '
        'In one short sentence, explain one concrete benefit of '
        'running AI agents fully offline on local devices rather than '
        'depending on a cloud server. '
        '(request id: $idempotencyKey)';

   /* final message = Message(
      text: prompt,
      role: MessageRole.user,
    );*/
    final message = Message(
  text: prompt,
);

    await _session!.addQueryChunk(message);

    final response = await _session!.getResponse();

    if (response.trim().isEmpty) {
      throw Exception(
        'On-device model returned an empty response',
      );
    }

    return response.trim();
  }*/

  static Future<void> dispose() async {
    await _session?.close();
    _session = null;
    _model = null;
  }
}
