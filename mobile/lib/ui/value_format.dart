/// Shared, display-only formatting for a tag's live value as printed in a
/// list/table/inspector widget.
///
/// QA sweep item A2 (#15): the Tags & Structs Live Value column showed full
/// double precision (e.g. `80.83999999999966`) and inconsistent `0` vs `0.0`
/// zero formatting across rows — the latter because a REAL-typed tag's
/// current value is sometimes a plain `int` zero (its default/uninitialized
/// representation survives a JSON round-trip as `0`, not `0.0`) rather than
/// a `double`.
///
/// [formatLiveValue] fixes a REAL/FLOAT64 value at up to 3 decimal places,
/// trims trailing zeros, but always keeps at least one decimal digit — so
/// `0.0`, not `0`, and `80.84`, not `80.83999999999966`. This is a display
/// helper only: it must never be used to alter a stored/written value, an
/// editing field's contents, or a protocol encoding.
String formatLiveValue(double value) {
  if (value.isNaN || value.isInfinite) return value.toString();
  var text = value.toStringAsFixed(3);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = '${text}0';
  }
  return text;
}
