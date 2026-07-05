import 'project_model.dart';
import 'tag_resolver.dart';

/// Minimal ST expression/assignment subset used by SFC charts (and the seed
/// of the future full ST interpreter): tag-path identifiers, TRUE/FALSE,
/// int/double literals, AND/OR/XOR/NOT, comparators (= <> < > <= >=),
/// + - * /, parentheses, `(* *)` and `//` comments, `path := expr;`
/// statements. Malformed input yields null / is skipped — never throws.

String _stripComments(String src) {
  final sb = StringBuffer();
  int i = 0;
  while (i < src.length) {
    if (i + 1 < src.length && src[i] == '(' && src[i + 1] == '*') {
      final end = src.indexOf('*)', i + 2);
      if (end == -1) {
        break; // unterminated block comment: drop the rest
      }
      i = end + 2;
    } else if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
      final nl = src.indexOf('\n', i);
      if (nl == -1) {
        break;
      }
      i = nl;
    } else {
      sb.write(src[i]);
      i++;
    }
  }
  return sb.toString();
}

/// Strips `(* *)` block and `// ` line comments (shared with the ST interpreter).
String stripStComments(String src) => _stripComments(src);

class _Tok {
  final String kind; // 'num','ident','op','kw'
  final String text;
  final num? number;
  _Tok(this.kind, this.text, [this.number]);
}

const Set<String> _keywords = {'TRUE', 'FALSE', 'AND', 'OR', 'XOR', 'NOT'};

List<_Tok>? _lex(String src) {
  final toks = <_Tok>[];
  int i = 0;
  bool isIdentStart(String c) => RegExp(r'[A-Za-z_]').hasMatch(c);
  bool isIdentPart(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      i++;
      continue;
    }
    if (RegExp(r'[0-9]').hasMatch(c)) {
      int j = i;
      bool isDouble = false;
      while (j < src.length && RegExp(r'[0-9]').hasMatch(src[j])) {
        j++;
      }
      if (j < src.length && src[j] == '.' && j + 1 < src.length &&
          RegExp(r'[0-9]').hasMatch(src[j + 1])) {
        isDouble = true;
        j++;
        while (j < src.length && RegExp(r'[0-9]').hasMatch(src[j])) {
          j++;
        }
      }
      final text = src.substring(i, j);
      toks.add(_Tok('num', text, isDouble ? double.parse(text) : int.parse(text)));
      i = j;
      continue;
    }
    if (isIdentStart(c)) {
      int j = i;
      final sb = StringBuffer();
      // A path identifier: word, then any run of .word / .digits / [digits]
      while (j < src.length && isIdentPart(src[j])) {
        sb.write(src[j]);
        j++;
      }
      while (j < src.length) {
        if (src[j] == '.' && j + 1 < src.length &&
            RegExp(r'[A-Za-z0-9_]').hasMatch(src[j + 1])) {
          sb.write('.');
          j++;
          while (j < src.length && isIdentPart(src[j])) {
            sb.write(src[j]);
            j++;
          }
        } else if (src[j] == '[') {
          final close = src.indexOf(']', j);
          if (close == -1) {
            return null;
          }
          sb.write(src.substring(j, close + 1));
          j = close + 1;
        } else {
          break;
        }
      }
      final word = sb.toString();
      final upper = word.toUpperCase();
      if (_keywords.contains(upper) && !word.contains('.') && !word.contains('[')) {
        toks.add(_Tok('kw', upper));
      } else {
        toks.add(_Tok('ident', word));
      }
      i = j;
      continue;
    }
    // multi-char operators first
    if (i + 1 < src.length) {
      final two = src.substring(i, i + 2);
      if (two == ':=' || two == '<>' || two == '<=' || two == '>=') {
        toks.add(_Tok('op', two));
        i += 2;
        continue;
      }
    }
    if ('=<>+-*/();'.contains(c)) {
      toks.add(_Tok('op', c));
      i++;
      continue;
    }
    return null; // unknown character -> lex failure
  }
  return toks;
}

class _Parser {
  final PlcProject p;
  final List<_Tok> toks;
  final Map<String, dynamic> vars;
  int pos = 0;
  bool failed = false;
  _Parser(this.p, this.toks, this.vars);

  _Tok? get _peek => pos < toks.length ? toks[pos] : null;
  _Tok? _take() => pos < toks.length ? toks[pos++] : null;
  bool _isOp(String t) => _peek != null && _peek!.kind == 'op' && _peek!.text == t;
  bool _isKw(String t) => _peek != null && _peek!.kind == 'kw' && _peek!.text == t;

  bool? _truthy(dynamic v) {
    if (v is bool) {
      return v;
    }
    if (v is num) {
      return v != 0;
    }
    return null;
  }

  dynamic parseExpr() => _or();

  dynamic _or() {
    var left = _xor();
    while (_isKw('OR')) {
      _take();
      final right = _xor();
      final l = _truthy(left), r = _truthy(right);
      left = (l == null || r == null) ? null : (l || r);
    }
    return left;
  }

  dynamic _xor() {
    var left = _and();
    while (_isKw('XOR')) {
      _take();
      final right = _and();
      final l = _truthy(left), r = _truthy(right);
      left = (l == null || r == null) ? null : (l ^ r);
    }
    return left;
  }

  dynamic _and() {
    var left = _not();
    while (_isKw('AND')) {
      _take();
      final right = _not();
      final l = _truthy(left), r = _truthy(right);
      left = (l == null || r == null) ? null : (l && r);
    }
    return left;
  }

  dynamic _not() {
    if (_isKw('NOT')) {
      _take();
      final v = _truthy(_not());
      return v == null ? null : !v;
    }
    return _cmp();
  }

  dynamic _cmp() {
    final left = _add();
    if (_peek != null && _peek!.kind == 'op' &&
        ['=', '<>', '<', '>', '<=', '>='].contains(_peek!.text)) {
      final op = _take()!.text;
      final right = _add();
      if (left is num && right is num) {
        switch (op) {
          case '=':
            return left == right;
          case '<>':
            return left != right;
          case '<':
            return left < right;
          case '>':
            return left > right;
          case '<=':
            return left <= right;
          case '>=':
            return left >= right;
        }
      }
      if (left is bool && right is bool) {
        if (op == '=') {
          return left == right;
        }
        if (op == '<>') {
          return left != right;
        }
      }
      return null;
    }
    return left;
  }

  dynamic _add() {
    var left = _mul();
    while (_isOp('+') || _isOp('-')) {
      final op = _take()!.text;
      final right = _mul();
      if (left is num && right is num) {
        left = op == '+' ? left + right : left - right;
      } else {
        left = null;
      }
    }
    return left;
  }

  dynamic _mul() {
    var left = _unary();
    while (_isOp('*') || _isOp('/')) {
      final op = _take()!.text;
      final right = _unary();
      if (left is num && right is num) {
        if (op == '*') {
          left = left * right;
        } else {
          left = right == 0 ? null : left / right;
        }
      } else {
        left = null;
      }
    }
    return left;
  }

  dynamic _unary() {
    if (_isOp('-')) {
      _take();
      final v = _unary();
      return v is num ? -v : null;
    }
    return _primary();
  }

  dynamic _primary() {
    final t = _take();
    if (t == null) {
      failed = true;
      return null;
    }
    if (t.kind == 'num') {
      return t.number;
    }
    if (t.kind == 'kw') {
      if (t.text == 'TRUE') {
        return true;
      }
      if (t.text == 'FALSE') {
        return false;
      }
      failed = true;
      return null;
    }
    if (t.kind == 'ident') {
      if (vars.containsKey(t.text)) {
        return vars[t.text];
      }
      return readPath(p, t.text);
    }
    if (t.kind == 'op' && t.text == '(') {
      final v = parseExpr();
      if (_isOp(')')) {
        _take();
        return v;
      }
      failed = true;
      return null;
    }
    failed = true;
    return null;
  }
}

/// Evaluates an ST expression; null on any lex/parse/type error.
dynamic evalExpr(PlcProject p, String source, {Map<String, dynamic> extraVars = const {}}) {
  final toks = _lex(_stripComments(source));
  if (toks == null || toks.isEmpty) {
    return null;
  }
  final parser = _Parser(p, toks, extraVars);
  final v = parser.parseExpr();
  if (parser.failed || parser.pos != toks.length) {
    return null;
  }
  return v;
}

/// True when the expression evaluates truthy (true, or a non-zero number).
bool evalStCondition(PlcProject p, String source, {Map<String, dynamic> extraVars = const {}}) {
  final v = evalExpr(p, source, extraVars: extraVars);
  if (v is bool) {
    return v;
  }
  if (v is num) {
    return v != 0;
  }
  return false;
}

/// Runs a `;`-separated list of `path := expr` assignments through [write].
/// Comments/blank statements are skipped; malformed statements are skipped.
void runStatements(PlcProject p, String source,
    void Function(String path, dynamic value) write,
    {Map<String, dynamic> extraVars = const {}}) {
  final clean = _stripComments(source);
  for (final raw in clean.split(';')) {
    final stmt = raw.trim();
    if (stmt.isEmpty) {
      continue;
    }
    final idx = stmt.indexOf(':=');
    if (idx <= 0) {
      continue;
    }
    final path = stmt.substring(0, idx).trim();
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_\.\[\]]*$').hasMatch(path)) {
      continue;
    }
    final value = evalExpr(p, stmt.substring(idx + 2), extraVars: extraVars);
    if (value != null) {
      write(path, value);
    }
  }
}
