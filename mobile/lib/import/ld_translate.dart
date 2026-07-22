import '../models/project_model.dart';
import 'import_ir.dart';

/// Result of translating one LD `GraphBody`. `rungs` includes placeholder
/// rungs (for untranslatable components) so program rung numbering matches the
/// source. `translatedRungCount > 0` is the mapper's real-program-vs-stub
/// decision. `instanceTags` are TIMER/COUNTER-typed tags the mapper must add so
/// translated timer/counter blocks have backing state.
class LdTranslation {
  final List<LdRung> rungs;
  final List<ImportWarning> warnings;
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<PlcTag> instanceTags;
  LdTranslation({
    required this.rungs,
    required this.warnings,
    required this.translatedRungCount,
    required this.stubbedRungCount,
    required this.unsupportedBlockTypes,
    required this.stubReasons,
    required this.instanceTags,
  });
}

/// Parses an IEC 61131 duration literal (`T#5s`, `TIME#500ms`, `T#1m30s`,
/// `T#1.5s`) to milliseconds. Case-insensitive. Returns null if [literal] is
/// not a duration. Supported units: d, h, m, s, ms.
int? parseIecDuration(String literal) {
  var s = literal.trim().toLowerCase();
  if (s.startsWith('time#')) {
    s = s.substring(5);
  } else if (s.startsWith('t#')) {
    s = s.substring(2);
  } else {
    return null;
  }
  if (s.isEmpty) return null;
  // Ordered so 'ms' is matched before 'm'.
  final re = RegExp(r'(\d+(?:\.\d+)?)(ms|d|h|m|s)');
  const unitMs = {'d': 86400000.0, 'h': 3600000.0, 'm': 60000.0, 's': 1000.0, 'ms': 1.0};
  double total = 0;
  var matchedLen = 0;
  for (final m in re.allMatches(s)) {
    matchedLen += m.group(0)!.length;
    total += double.parse(m.group(1)!) * unitMs[m.group(2)]!;
  }
  if (matchedLen != s.length || matchedLen == 0) {
    return null; // stray characters -> not a clean duration
  }
  return total.round();
}
