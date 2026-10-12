import 'dart:math';

import '../models/task_state.dart';

/// Step 5: a REAL task. A document is split into chunks; each agent step
/// folds one chunk into a running summary. The running summary lives in
/// TaskState, so it travels with the task through a handoff.

/// Used when the Source's document box is left empty, so the demo always
/// works out of the box. Plain paragraphs separated by blank lines.
const String kSampleDocument = '''
Software that works without a network connection is usually called offline-first. Instead of treating the internet as always available, an offline-first application keeps its data and its logic on the device and treats connectivity as a bonus. Users can keep working on a bus, in a basement, or in a village with no signal, and anything that needs to be shared is sent later.

Artificial intelligence has mostly gone the other way. The most capable models run in large data centers, and an application sends each request over the internet and waits for the answer. That works well when the connection is fast and cheap, but it fails when the connection is slow, expensive, or missing, and it means every prompt and every document leaves the device.

Small language models change this picture. Models with roughly one billion parameters can now run on an ordinary laptop and, with compression, on a mid-range phone. They are less capable than the largest cloud models, but they are good enough for focused jobs such as summarizing a page, rewriting a note, or pulling facts out of a form.

Running a model locally brings a different problem. A phone has a small battery and can be switched off, carried out of range, or put in a pocket at any moment. A long task, such as reading a hundred-page report, may take longer than the device can stay alive. If the task lives only in the memory of that one device, the work is lost when it stops.

One answer is to let another nearby device continue the task. A laptop on the same network could take over where the phone left off, as long as it receives everything needed to continue: which step was reached, what has been produced so far, and what was in progress when the handoff happened.

The hard part is the step that was running at the moment of handoff. The new device cannot always tell whether that step finished. If it simply repeats the step, the work may be done twice, and because a language model does not give identical answers every time, the two results can differ. A careful system notices this and records it instead of hiding it.

Finally, the person who started the task may no longer be connected when it finishes. The result needs a mailbox: it is stored by the device that completed the work and delivered when the original device returns to the network, even if that happens hours later.
''';

/// Splits [text] into chunks of at most [maxChars] characters, preferring
/// paragraph and sentence boundaries. Small chunks matter here: the phone's
/// model has a short context window, and the prompt also has to hold the
/// running summary and the instructions.
List<String> chunkText(String text, {int maxChars = 500}) {
  final normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return [];

  // Break into "units" no longer than maxChars: whole paragraphs where
  // they fit, otherwise sentences, otherwise a hard split.
  final units = <String>[];
  for (final para in normalized.split(RegExp(r'\n\s*\n'))) {
    final p = para.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (p.isEmpty) continue;
    if (p.length <= maxChars) {
      units.add(p);
      continue;
    }
    final sentences = RegExp(r'[^.!?]+[.!?]*\s*')
        .allMatches(p)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty);
    for (final s in sentences) {
      if (s.length <= maxChars) {
        units.add(s);
      } else {
        for (var i = 0; i < s.length; i += maxChars) {
          units.add(s.substring(i, min(i + maxChars, s.length)));
        }
      }
    }
  }

  // Pack units greedily into chunks up to maxChars.
  final chunks = <String>[];
  var current = '';
  for (final u in units) {
    if (current.isEmpty) {
      current = u;
    } else if (current.length + 1 + u.length <= maxChars) {
      current = '$current $u';
    } else {
      chunks.add(current);
      current = u;
    }
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// Safety cap on how much of the running summary goes back into the prompt.
/// The model is asked to stay under ~80 words, but small models overshoot,
/// and an unbounded summary would eventually overflow the context window.
const int kMaxSummaryChars = 1500;

/// The prompt for step [step] (1-based). BOTH devices call this, so a step
/// re-run on the other device sees the exact same instructions and inputs.
/// [runningSummary] must be the summary as of step-1 — it only changes when
/// a step COMPLETES, which is what makes a mid-step handoff safe to resume.
String buildSummaryPrompt({
  required int step,
  required int totalSteps,
  required String chunk,
  required String runningSummary,
}) {
  final trimmed = runningSummary.trim();
  final summary = trimmed.isEmpty
      ? '(none yet - this is the first section)'
      : (trimmed.length > kMaxSummaryChars
          ? trimmed.substring(0, kMaxSummaryChars)
          : trimmed);

  return 'You are summarizing a document one section at a time.\n\n'
      'Summary so far:\n$summary\n\n'
      'New section ($step of $totalSteps):\n$chunk\n\n'
      'Write an updated summary that covers everything so far, including '
      'this new section. Keep the important points from the earlier '
      'sections; do not drop them to make room. Use only information from '
      'the text above. Use at most 150 words. Start directly with the '
      'summary, with no introduction.';
}

/// Small models often open with "Here's an updated summary:" or a label such
/// as "**Summary:**". If that text is stored, it is fed back into every later
/// prompt and pollutes the result. Strip, in order: (1) a leading "Here's
/// ...:" line, (2) a leading label ("Summary:", "**Updated Summary:**",
/// "## Summary") that either sits on its own line or is followed by a colon
/// and then text. If nothing is left, keep the original text.
///
/// The three patterns below are mirrored character for character in
/// receiver.py (_PREAMBLE, _LABEL_LINE, _LABEL_INLINE). Change them together.
const String kPreamblePattern =
    r"^(?:here(?:['’]s| is| are)|sure|okay|certainly)\b[^\n:]{0,100}:\s*";
const String kLabelLinePattern =
    r"^(?:#{1,6}[ \t]*)?(?:\*\*|__)?(?:(?:updated|final|new|revised|running|consolidated)[ \t]+)?summary(?:[ \t]+so[ \t]+far)?[ \t]*(?:\*\*|__)?[ \t]*:?[ \t]*(?:\*\*|__)?[ \t]*(?:\r?\n[ \t\r\n]*|$)";
const String kLabelInlinePattern =
    r"^(?:#{1,6}[ \t]*)?(?:\*\*|__)?(?:(?:updated|final|new|revised|running|consolidated)[ \t]+)?summary(?:[ \t]+so[ \t]+far)?[ \t]*(?:\*\*|__)?[ \t]*:[ \t]*(?:\*\*|__)?[ \t]+(?=[^ \t\r\n])";

final RegExp _preamble = RegExp(kPreamblePattern, caseSensitive: false);
final RegExp _labelLine = RegExp(kLabelLinePattern, caseSensitive: false);
final RegExp _labelInline = RegExp(kLabelInlinePattern, caseSensitive: false);

String cleanSummary(String raw) {
  final t = raw.trim();
  var out = t.replaceFirst(_preamble, '').trim();
  out = out.replaceFirst(_labelLine, '').trim();
  out = out.replaceFirst(_labelInline, '').trim();
  return out.isEmpty ? t : out;
}


// =====================================================================
// The summarization task, expressed in the generic task format.
//
// Nothing here is known to the handoff harness. The harness carries
// TaskState.data untouched; only these helpers know that, for the
// 'summarize' task type, data holds the document chunks and the running
// summary. A different agent would define its own data and its own
// helpers like these, and the harness would not change.
// =====================================================================

const String kSummarizeTask = 'summarize';

/// Creates a new summarization task: one step per chunk.
TaskState newSummaryTask({
  required String taskId,
  required String originatorId,
  required List<String> chunks,
}) =>
    TaskState(
      taskId: taskId,
      originatorId: originatorId,
      taskType: kSummarizeTask,
      stepIndex: 0,
      targetStep: chunks.length,
      status: 'running',
      log: [],
      data: {'chunks': chunks, 'runningSummary': ''},
    );

List<String> summaryChunks(TaskState s) =>
    ((s.data['chunks'] as List?) ?? const []).map((e) => e as String).toList();

String summaryText(TaskState s) => (s.data['runningSummary'] as String?) ?? '';

/// The prompt for step [step], built only from the task's own data.
/// Both devices call this, so a re-run on the other device is identical.
String summaryPromptForStep(int step, TaskState s) {
  final chunks = summaryChunks(s);
  return buildSummaryPrompt(
    step: step,
    totalSteps: s.targetStep,
    chunk: chunks.length >= step ? chunks[step - 1] : '',
    runningSummary: summaryText(s),
  );
}

/// Folds a COMPLETED step's output into the task: the new text replaces
/// the running summary. Passed to AgentSimulator as `applyResult`.
void applySummaryResult(int step, String result, TaskState s) {
  s.data['runningSummary'] = result;
}
