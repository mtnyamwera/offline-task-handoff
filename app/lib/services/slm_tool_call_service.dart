import 'dart:convert';
import 'package:http/http.dart' as http;

/// Calls a locally-running Ollama server for real model inference.
///
/// This is deliberately NOT a cloud LLM API — Ollama runs entirely on the
/// laptop, on the LAN, with no internet required once the model is
/// downloaded. Both the phone (Source) and the laptop (Target) call the
/// SAME Ollama instance, over the LAN, using its LAN IP address — never
/// "localhost", since the phone calling its own localhost would hit
/// nothing at all.
///
/// Like RealToolCallService before it, this class does NOT protect
/// against duplicate calls — that safety still comes entirely from the
/// AgentSimulator's idempotency-key logic. Running this twice for the
/// same key just costs extra compute time and produces two (possibly
/// slightly different, since LLM output isn't perfectly deterministic)
/// responses — a much cheaper mistake than a duplicated email, but worth
/// noticing as a real difference from Step 1's version of this class.
class SlmToolCallService {
  // Matches the phone's on-device model family (Gemma 3 1B) so a step re-run
  // on the other device is comparable. Outputs still won't be identical
  // (different runtime and quantization), but divergence flags then reflect
  // sampling/runtime differences, not two different models.
  // One-time setup on the laptop:  ollama pull gemma3:1b
  static const String defaultModel = 'gemma3:1b';

  /// Sends one real prompt to Ollama and returns the model's response
  /// text. Throws on failure/timeout — same "unknown outcome" contract
  /// as RealToolCallService: a thrown error here does not mean the
  /// request never reached Ollama, only that this device didn't get a
  /// clean response back in time.
  static Future<String> dispatch({
    required String endpoint, // e.g. http://192.168.1.227:11434
    required String prompt, // built by buildSummaryPrompt (shared w/ phone)
    String model = defaultModel,
  }) async {
    final url0 = Uri.parse('${_normalize(endpoint)}/api/generate');
    final body = jsonEncode({
      'model': model,
      'prompt': prompt,
      'stream': false,
      // Cap output length so a summary can't grow without bound.
      'options': {'num_predict': 260},
    });

    // dart:io does not auto-follow a 307/308 for a POST, so a redirect
    // surfaces here as a "failure". Follow it manually (bounded), keeping
    // the same method and body — that's what 307/308 mean. A redirect to
    // the SAME url would loop forever, so stop and report it instead.
    var url = url0;
    late http.Response response;
    for (var hop = 0;; hop++) {
      response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          // Real inference is slower and more variable than a webhook
          // ping — give it room, esp. the first call after model load.
          .timeout(const Duration(seconds: 60));

      final isRedirect = response.statusCode == 307 || response.statusCode == 308;
      final loc = response.headers['location'];
      if (!isRedirect || loc == null || hop >= 3) break;
      final next = url.resolve(loc);
      if (next == url) break; // self-redirect: following would loop
      url = next;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final location = response.headers['location'];
      // Include the EXACT url we posted to — for a redirect, comparing it
      // with the Location header shows what the server objected to.
      throw Exception(
          'Ollama returned ${response.statusCode} for POST $url'
          '${location != null ? " (Location: $location)" : ""}: '
          '${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final text = json['response'] as String?;
    if (text == null || text.trim().isEmpty) {
      throw Exception('Ollama returned an empty response');
    }
    return text.trim();
  }

  /// Cleans up what a person typed in the endpoint field: adds http://
  /// if missing, strips trailing slashes (a trailing slash makes the
  /// final URL contain "//api/generate", which servers often redirect),
  /// and strips a pasted-in "/api" or "/api/generate" suffix.
  static String _normalize(String endpoint) {
    var e = endpoint.trim();
    e = e.replaceAll(RegExp(r'/+$'), '');
    e = e.replaceAll(RegExp(r'/api(/generate)?$'), '');
    e = e.replaceAll(RegExp(r'/+$'), '');
    if (!e.startsWith('http://') && !e.startsWith('https://')) {
      e = 'http://$e';
    }
    return e;
  }
}
