import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import 'import_ir.dart';

const Map<String, String> _elementary = {
  'BOOL': 'BOOL',
  'SINT': 'INT16', 'INT': 'INT16', 'USINT': 'INT16', 'UINT': 'INT16',
  'BYTE': 'INT16', 'WORD': 'INT16',
  'DINT': 'INT32', 'UDINT': 'INT32', 'DWORD': 'INT32',
  'LINT': 'INT64', 'ULINT': 'INT64', 'LWORD': 'INT64',
  'REAL': 'FLOAT64', 'LREAL': 'FLOAT64',
  'STRING': 'STRING', 'WSTRING': 'STRING', 'CHAR': 'STRING', 'WCHAR': 'STRING',
  'TIME': 'TIMER', 'TON': 'TIMER', 'TOF': 'TIMER', 'TP': 'TIMER',
};

/// Maps an IEC/PLCopen type name to the app's data-type set. A name in
/// [knownDutNames] maps to itself (a struct reference); an unrecognized name
/// falls back to `INT16`. Case-insensitive.
String normalizeType(String iecType, {required Set<String> knownDutNames}) {
  final upper = iecType.trim().toUpperCase();
  final mapped = _elementary[upper];
  if (mapped != null) {
    return mapped;
  }
  if (knownDutNames.contains(iecType.trim())) {
    return iecType.trim();
  }
  return 'INT16';
}

/// Coerces a PLCopen `<initialValue>` raw scalar text into the runtime value
/// for an app tag/field of [appType]. Scalar only: an array/composite target
/// (arrayLength > 0 or a composite type) yields the structural default via
/// [defaultValueFor] and appends an info warning to [sink]. A null [rawText]
/// yields the type default silently. Never throws.
dynamic coerceInitialValue(PlcProject p, String appType, int arrayLength,
    String? rawText, List<ImportWarning> sink) {
  if (arrayLength > 0 || defaultValueFor(p, appType, 0) is Map) {
    if (rawText != null) {
      sink.add(ImportWarning(
          severity: WarningSeverity.info,
          message: 'Initial value for a $appType'
              '${arrayLength > 0 ? '[$arrayLength]' : ''} was not imported '
              '(only scalar initial values are supported).'));
    }
    return defaultValueFor(p, appType, arrayLength);
  }
  if (rawText == null) {
    return defaultValueFor(p, appType, 0);
  }
  return coerceScalarValue(appType, rawText);
}
