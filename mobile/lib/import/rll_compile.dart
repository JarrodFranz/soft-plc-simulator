// ignore_for_file: unused_import
// TODO(task-3): these are consumed by the RLL compiler landing in Task 3;
// remove the ignore once that code is added to this file.
import '../models/project_model.dart';
import '../models/ld_graph.dart';
import 'import_ir.dart';

/// One element of a parsed RLL rung: an instruction or a parallel branch group.
sealed class RllElement {}

class RllInstruction extends RllElement {
  final String mnemonic;
  final List<String> operands;
  RllInstruction(this.mnemonic, this.operands);
}

class RllBranch extends RllElement {
  final List<List<RllElement>> legs;
  RllBranch(this.legs);
}

/// Thrown by [parseRllText] on malformed neutral text. Always caught inside
/// [compileRllRungs] (a parse error degrades that rung to a placeholder).
class RllParseException implements Exception {
  final String message;
  RllParseException(this.message);
  @override
  String toString() => 'RllParseException: $message';
}

class _Cursor {
  final String s;
  int i = 0;
  _Cursor(this.s);
}

bool _isIdent(String ch) =>
    RegExp(r'[A-Za-z0-9_]').hasMatch(ch);

void _skipWs(_Cursor c) {
  while (c.i < c.s.length && (c.s[c.i] == ' ' || c.s[c.i] == '\t' ||
      c.s[c.i] == '\n' || c.s[c.i] == '\r')) {
    c.i++;
  }
}

/// Tokenizes a rung's neutral text into a top-level element sequence. A trailing
/// `;` and inter-instruction whitespace are tolerated. Throws
/// [RllParseException] on unbalanced brackets or a missing/empty instruction.
List<RllElement> parseRllText(String text) {
  var t = text.trim();
  if (t.endsWith(';')) t = t.substring(0, t.length - 1);
  final c = _Cursor(t);
  final els = _parseSeq(c);
  _skipWs(c);
  if (c.i != c.s.length) {
    throw RllParseException('unexpected "${c.s[c.i]}" at ${c.i}');
  }
  return els;
}

/// Parses a sequence of elements, stopping at a top-level ',' or ']'.
List<RllElement> _parseSeq(_Cursor c) {
  final out = <RllElement>[];
  while (c.i < c.s.length) {
    _skipWs(c);
    if (c.i >= c.s.length) break;
    final ch = c.s[c.i];
    if (ch == ',' || ch == ']') break;
    if (ch == '[') {
      out.add(_parseBranch(c));
    } else {
      out.add(_parseInstr(c));
    }
  }
  return out;
}

RllBranch _parseBranch(_Cursor c) {
  c.i++; // consume '['
  final legs = <List<RllElement>>[_parseSeq(c)];
  while (c.i < c.s.length && c.s[c.i] == ',') {
    c.i++; // consume ','
    legs.add(_parseSeq(c));
  }
  if (c.i >= c.s.length || c.s[c.i] != ']') {
    throw RllParseException('unclosed branch "["');
  }
  c.i++; // consume ']'
  return RllBranch(legs);
}

RllInstruction _parseInstr(_Cursor c) {
  final start = c.i;
  while (c.i < c.s.length && _isIdent(c.s[c.i])) {
    c.i++;
  }
  final mnemonic = c.s.substring(start, c.i);
  if (mnemonic.isEmpty) {
    throw RllParseException('expected an instruction at ${c.i}');
  }
  _skipWs(c);
  if (c.i >= c.s.length || c.s[c.i] != '(') {
    throw RllParseException('expected "(" after "$mnemonic"');
  }
  c.i++; // consume '('
  final operands = _parseArgs(c);
  return RllInstruction(mnemonic, operands);
}

/// Reads to the matching ')', splitting on top-level ',' (respecting nested
/// () and []). '(' must have been consumed by the caller.
List<String> _parseArgs(_Cursor c) {
  final args = <String>[];
  final buf = StringBuffer();
  var paren = 0, brack = 0;
  var closed = false;
  while (c.i < c.s.length) {
    final ch = c.s[c.i];
    if (ch == ')' && paren == 0 && brack == 0) {
      c.i++;
      closed = true;
      break;
    }
    if (ch == ',' && paren == 0 && brack == 0) {
      args.add(buf.toString().trim());
      buf.clear();
      c.i++;
      continue;
    }
    if (ch == '(') paren++;
    if (ch == ')') paren--;
    if (ch == '[') brack++;
    if (ch == ']') brack--;
    buf.write(ch);
    c.i++;
  }
  if (!closed) throw RllParseException('unclosed "("');
  final last = buf.toString().trim();
  if (last.isNotEmpty || args.isNotEmpty) args.add(last);
  return args;
}
