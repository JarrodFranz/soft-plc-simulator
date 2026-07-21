import 'package:flutter/material.dart';
import '../models/tag_resolver.dart';

/// One reusable value input for a SCALAR tag, rendering the right control per
/// [dataType] and emitting a COERCED value (via [coerceScalarValue] for the
/// text types). BOOL -> a Switch; INT/FLOAT -> a numeric TextField; STRING ->
/// a text TextField. A composite/array/unknown type shows a disabled note
/// (its default is edited structurally in the struct editor, not here).
class ScalarValueField extends StatelessWidget {
  const ScalarValueField({
    super.key,
    required this.dataType,
    required this.value,
    required this.onChanged,
  });

  final String dataType;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  static const _scalarTypes = {'BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING'};

  @override
  Widget build(BuildContext context) {
    if (dataType == 'BOOL') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Value', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(width: 8),
          Switch(
            key: const Key('scalar_value_bool_switch'),
            value: value == true,
            onChanged: (v) => onChanged(v),
          ),
        ],
      );
    }
    if (!_scalarTypes.contains(dataType)) {
      return const Text(
        'Structured default — edit fields in the struct editor.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      );
    }
    final numeric = dataType != 'STRING';
    return TextField(
      key: const Key('scalar_value_text_field'),
      controller: TextEditingController(text: value == null ? '' : '$value'),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      style: const TextStyle(fontSize: 12, color: Colors.white),
      decoration: const InputDecoration(
        isDense: true,
        labelText: 'Default value',
        border: OutlineInputBorder(),
      ),
      onChanged: (raw) => onChanged(coerceScalarValue(dataType, raw)),
    );
  }
}
