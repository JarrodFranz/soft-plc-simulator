import 'package:flutter/material.dart';

import '../import/import_ir.dart';
import '../import/ir_to_project.dart';

/// Post-import review screen for the PLCopen XML import flow (Task 5 of the
/// import feature). Shown after detect→parse→map has already produced a
/// mapped [ImportResult] — this screen never talks to the parser/mapper
/// itself. It lets the operator rename the project before it's created and
/// shows the at-a-glance counts + every warning collected while mapping, so
/// fidelity loss (e.g. a graphical body captured as a stub) is visible
/// before committing.
///
/// Creating is always additive: [onCreate] is expected to build a brand-new
/// project from [result.project] (with the possibly-edited name) — this
/// widget never mutates the currently active project. See
/// `_importProgramXml`/the XML-import wiring in workspace_shell.dart.
class ImportXmlPreview extends StatefulWidget {
  const ImportXmlPreview({super.key, required this.result, required this.onCreate});

  final ImportResult result;
  final void Function(String finalName) onCreate;

  @override
  State<ImportXmlPreview> createState() => _ImportXmlPreviewState();
}

class _ImportXmlPreviewState extends State<ImportXmlPreview> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.result.project.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.result.report;
    final totalPrograms = report.stProgramCount + report.graphicalStubCount;
    final countsLine = '${report.tagCount} tags · ${report.structCount} structs · '
        '$totalPrograms programs (${report.graphicalStubCount} graphical stubs)';

    return Scaffold(
      key: const Key('import_xml_preview'),
      appBar: AppBar(
        title: const Text('Import PLC Program'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      // Everything lives inside one scroll view so this screen never
      // overflows at narrow widths (320/360) regardless of how many
      // warnings the import produced.
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('PROJECT NAME',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Colors.grey,
                      letterSpacing: 0.5)),
              const SizedBox(height: 6),
              TextField(
                key: const Key('import_xml_name_field'),
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Text(countsLine,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              if (report.stubbedRungCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${report.stubbedRungCount} rung(s) not translated'
                  '${report.unsupportedLdBlockTypes.isNotEmpty ? ' — unsupported blocks: ${report.unsupportedLdBlockTypes.join(', ')}' : ''}',
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              const Text('WARNINGS',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Colors.grey,
                      letterSpacing: 0.5)),
              const SizedBox(height: 6),
              if (report.warnings.isEmpty)
                const Text('No warnings — the import mapped cleanly.',
                    style: TextStyle(color: Colors.white70, fontSize: 12))
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in report.warnings)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              w.severity == WarningSeverity.warning
                                  ? Icons.warning_amber_rounded
                                  : Icons.info_outline,
                              size: 14,
                              color: w.severity == WarningSeverity.warning
                                  ? Colors.amber
                                  : Colors.white70,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                w.message,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: w.severity == WarningSeverity.warning
                                      ? Colors.amber
                                      : Colors.white70,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    key: const Key('import_xml_create_button'),
                    onPressed: () => widget.onCreate(_nameController.text),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
