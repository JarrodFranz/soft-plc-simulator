import 'package:flutter/material.dart';

/// A reusable, dark-themed type-ahead text field for picking a PLC tag name
/// or path.
///
/// As the user types, `options` are filtered by a case-insensitive substring
/// match against the current text and shown in a phone-safe (width-clamped)
/// overlay list. Selecting an option sets the field text and calls
/// [onChanged]. When [allowFreeText] is true (the default), any edit to the
/// text — including a value that matches nothing in `options` — also calls
/// [onChanged], so callers can type a path/tag that isn't listed yet.
class TagAutocompleteField extends StatefulWidget {
  /// Tag names or paths to suggest.
  final List<String> options;

  /// Seed value for the text controller.
  final String initialValue;

  /// Invoked with the selected option, or (when [allowFreeText]) the raw
  /// typed text on every edit.
  final ValueChanged<String> onChanged;

  /// Optional field label.
  final String? label;

  /// When true (default), free-text edits that don't match any option still
  /// invoke [onChanged]. When false, [onChanged] only fires on selection.
  final bool allowFreeText;

  const TagAutocompleteField({
    super.key,
    required this.options,
    required this.initialValue,
    required this.onChanged,
    this.label,
    this.allowFreeText = true,
  });

  @override
  State<TagAutocompleteField> createState() => _TagAutocompleteFieldState();
}

class _TagAutocompleteFieldState extends State<TagAutocompleteField> {
  final LayerLink _layerLink = LayerLink();
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _overlayEntry;
  List<String> _matches = const [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _removeOverlay();
    }
  }

  List<String> _filter(String query) {
    if (query.isEmpty) {
      return widget.options;
    }
    final lower = query.toLowerCase();
    return widget.options.where((o) => o.toLowerCase().contains(lower)).toList();
  }

  void _onTextChanged(String value) {
    _matches = _filter(value);
    if (widget.allowFreeText) {
      widget.onChanged(value);
    }
    if (_matches.isEmpty || !_focusNode.hasFocus) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _onSelect(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged(value);
    _removeOverlay();
    _focusNode.unfocus();
  }

  void _showOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    final width = renderBox?.size.width ?? 200.0;

    _overlayEntry = OverlayEntry(
      builder: (ctx) {
        final maxWidth = MediaQuery.sizeOf(ctx).width - 16;
        final overlayWidth = width.clamp(0.0, maxWidth);
        return Positioned(
          width: overlayWidth,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: const Offset(0, 44),
            child: Material(
              elevation: 4,
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: _matches.length,
                  itemBuilder: (context, i) {
                    final option = _matches[i];
                    return InkWell(
                      onTap: () => _onSelect(option),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Text(
                          option,
                          style: const TextStyle(fontSize: 12, color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        style: const TextStyle(fontSize: 12, color: Colors.white),
        decoration: InputDecoration(
          isDense: true,
          labelText: widget.label,
          filled: true,
          fillColor: const Color(0xFF0F172A),
          border: const OutlineInputBorder(),
        ),
        onChanged: _onTextChanged,
        onTap: () {
          _matches = _filter(_controller.text);
          if (_matches.isNotEmpty) {
            _showOverlay();
          }
        },
      ),
    );
  }
}
