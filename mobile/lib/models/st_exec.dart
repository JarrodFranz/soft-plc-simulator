import 'project_model.dart';
import 'st_expr.dart';
import 'tag_resolver.dart';

/// Reserved for future stateful ST (in-body timers/counters); unused today.
class StRuntime {
  void clear() {}
}

PlcTag? _rootTagOf(PlcProject p, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in p.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

void _forceAwareWrite(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins
  }
  writePath(p, path, value);
}

// ── Tokens ────────────────────────────────────────────────────────────────
class _Tok {
  final String kind; // 'kw' | 'assign' | 'semi' | 'expr'
  final String text; // uppercased keyword for 'kw', else raw
  final int start;
  final int end;
  _Tok(this.kind, this.text, this.start, this.end);
}

const Set<String> _stKeywords = {'IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF'};

bool _idStart(String c) => RegExp(r'[A-Za-z_]').hasMatch(c);
bool _idPart(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);
bool _digit(String c) => RegExp(r'[0-9]').hasMatch(c);

List<_Tok> _tokenize(String src) {
  final toks = <_Tok>[];
  int i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      i++;
      continue;
    }
    if (i + 1 < src.length && src[i] == ':' && src[i + 1] == '=') {
      toks.add(_Tok('assign', ':=', i, i + 2));
      i += 2;
      continue;
    }
    if (c == ';') {
      toks.add(_Tok('semi', ';', i, i + 1));
      i++;
      continue;
    }
    if (_idStart(c)) {
      final start = i;
      while (i < src.length && _idPart(src[i])) {
        i++;
      }
      // dotted / indexed path runs stay in one token
      while (i < src.length) {
        if (src[i] == '.' && i + 1 < src.length && _idPart(src[i + 1])) {
          i++;
          while (i < src.length && _idPart(src[i])) {
            i++;
          }
        } else if (src[i] == '[') {
          final close = src.indexOf(']', i);
          if (close == -1) {
            i = src.length;
            break;
          }
          i = close + 1;
        } else {
          break;
        }
      }
      final text = src.substring(start, i);
      final up = text.toUpperCase();
      if (_stKeywords.contains(up) && !text.contains('.') && !text.contains('[')) {
        toks.add(_Tok('kw', up, start, i));
      } else {
        toks.add(_Tok('expr', text, start, i));
      }
      continue;
    }
    if (_digit(c)) {
      final start = i;
      while (i < src.length && (_digit(src[i]) || src[i] == '.')) {
        i++;
      }
      toks.add(_Tok('expr', src.substring(start, i), start, i));
      continue;
    }
    // operators / parens: two-char first
    if (i + 1 < src.length) {
      final two = src.substring(i, i + 2);
      if (two == '<=' || two == '>=' || two == '<>') {
        toks.add(_Tok('expr', two, i, i + 2));
        i += 2;
        continue;
      }
    }
    if ('=<>+-*/()'.contains(c)) {
      toks.add(_Tok('expr', c, i, i + 1));
      i++;
      continue;
    }
    // unknown char: emit as an expr atom so a bad statement is skippable, advance
    toks.add(_Tok('expr', c, i, i + 1));
    i++;
  }
  return toks;
}

// ── Statement AST ───────────────────────────────────────────────────────────
abstract class _Stmt {}

class _Assign extends _Stmt {
  final String path;
  final int rhsStart;
  final int rhsEnd;
  _Assign(this.path, this.rhsStart, this.rhsEnd);
}

class _Branch {
  final int condStart;
  final int condEnd;
  final List<_Stmt> body;
  _Branch(this.condStart, this.condEnd, this.body);
}

class _If extends _Stmt {
  final List<_Branch> branches; // IF + ELSIF...
  final List<_Stmt>? elseBody;
  _If(this.branches, this.elseBody);
}

// ── Parser ──────────────────────────────────────────────────────────────────
class _Parser {
  final List<_Tok> toks;
  int pos = 0;
  _Parser(this.toks);

  _Tok? get _peek => pos < toks.length ? toks[pos] : null;
  bool _isKw(String k) => _peek != null && _peek!.kind == 'kw' && _peek!.text == k;

  /// Parses statements until a block terminator (ELSIF/ELSE/END_IF) or EOF.
  List<_Stmt> parseBlock() {
    final out = <_Stmt>[];
    while (_peek != null) {
      if (_isKw('ELSIF') || _isKw('ELSE') || _isKw('END_IF')) {
        break;
      }
      final s = _parseStatement();
      if (s != null) {
        out.add(s);
      }
    }
    return out;
  }

  _Stmt? _parseStatement() {
    final t = _peek!;
    if (t.kind == 'kw' && t.text == 'IF') {
      return _parseIf();
    }
    if (t.kind == 'expr') {
      // assignment: expr(path) := ... ;
      final pathTok = t;
      if (pos + 1 < toks.length && toks[pos + 1].kind == 'assign') {
        pos += 2; // past path and ':='
        final rhsStart = _peek?.start ?? pathTok.end;
        int rhsEnd = rhsStart;
        while (_peek != null && _peek!.kind != 'semi' &&
            !(_peek!.kind == 'kw')) {
          rhsEnd = _peek!.end;
          pos++;
        }
        if (_peek != null && _peek!.kind == 'semi') {
          pos++; // consume ';'
        }
        if (_validPath(pathTok.text) && rhsEnd > rhsStart) {
          return _Assign(pathTok.text, rhsStart, rhsEnd);
        }
        return null;
      }
    }
    // Unrecognized/misplaced token (a bare expression, or a stray keyword such
    // as a duplicated THEN reaching statement position): consume at least one
    // token to guarantee forward progress, then skip to the next statement
    // boundary. Without the unconditional advance, a stray keyword would spin
    // parseBlock forever (_skipToStatementEnd stops on any keyword). Terminators
    // (ELSIF/ELSE/END_IF) are handled by parseBlock before reaching here, so
    // this never consumes a token another parser level still needs.
    pos++;
    _skipToStatementEnd();
    return null;
  }

  _Stmt _parseIf() {
    pos++; // past IF
    final branches = <_Branch>[];
    branches.add(_parseBranch());
    while (_isKw('ELSIF')) {
      pos++;
      branches.add(_parseBranch());
    }
    List<_Stmt>? elseBody;
    if (_isKw('ELSE')) {
      pos++;
      elseBody = parseBlock();
    }
    if (_isKw('END_IF')) {
      pos++;
    }
    if (_peek != null && _peek!.kind == 'semi') {
      pos++; // optional ';' after END_IF
    }
    return _If(branches, elseBody);
  }

  _Branch _parseBranch() {
    final condStart = _peek?.start ?? 0;
    int condEnd = condStart;
    while (_peek != null && !_isKw('THEN')) {
      condEnd = _peek!.end;
      pos++;
    }
    if (_isKw('THEN')) {
      pos++;
    }
    final body = parseBlock();
    return _Branch(condStart, condEnd, body);
  }

  void _skipToStatementEnd() {
    while (_peek != null && _peek!.kind != 'semi' && _peek!.kind != 'kw') {
      pos++;
    }
    if (_peek != null && _peek!.kind == 'semi') {
      pos++;
    }
  }

  bool _validPath(String s) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_\.\[\]]*$').hasMatch(s);
}

// ── Executor ────────────────────────────────────────────────────────────────
void _execBlock(PlcProject p, String src, List<_Stmt> stmts) {
  for (final s in stmts) {
    if (s is _Assign) {
      final v = evalExpr(p, src.substring(s.rhsStart, s.rhsEnd));
      if (v != null) {
        _forceAwareWrite(p, s.path, v);
      }
    } else if (s is _If) {
      bool taken = false;
      for (final b in s.branches) {
        if (evalStCondition(p, src.substring(b.condStart, b.condEnd))) {
          _execBlock(p, src, b.body);
          taken = true;
          break;
        }
      }
      if (!taken && s.elseBody != null) {
        _execBlock(p, src, s.elseBody!);
      }
    }
  }
}

/// Executes every StructuredText program's `stSource` each scan: IF/ELSIF/ELSE
/// control flow plus `path := expr;` assignments, with all expressions
/// evaluated by `st_expr` and writes made force-aware. Never throws.
void executeStPrograms(PlcProject p, int dtMs, StRuntime rt, {Set<String>? only}) {
  for (final prog in p.programs) {
    if (prog.language != 'StructuredText' || prog.stSource.trim().isEmpty) {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    final src = stripStComments(prog.stSource);
    final toks = _tokenize(src);
    if (toks.isEmpty) {
      continue;
    }
    final stmts = _Parser(toks).parseBlock();
    _execBlock(p, src, stmts);
  }
}
