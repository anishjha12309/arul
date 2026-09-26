// Non-comment token stream of a Dart file, from the analyzer's own scanner.
// Comments hang off `precedingComments` and never enter the `next` chain.
//
//   dart run tokens_dart.dart <file>            one JSON-encoded lexeme per line
//   dart run tokens_dart.dart --json <files…>   {file: {tokens, comments}} for the .mjs tools
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/token.dart';

Map<String, Object> scan(String path) {
  final content = File(path).readAsStringSync();
  final result = parseString(
    content: content,
    path: path,
    throwIfDiagnostics: false,
  );
  if (result.errors.isNotEmpty) {
    throw FormatException('$path: ${result.errors.first.message}');
  }
  final tokens = <String>[];
  final comments = <Map<String, Object>>[];
  Token? t = result.unit.beginToken;
  while (t != null) {
    Token? c = t.precedingComments;
    while (c != null) {
      comments.add({'offset': c.offset, 'end': c.end, 'text': c.lexeme});
      c = c.next;
    }
    if (t.isEof) break;
    tokens.add(t.lexeme);
    t = t.next;
  }
  return {'tokens': tokens, 'comments': comments};
}

void main(List<String> args) {
  try {
    if (args.isNotEmpty && args.first == '--json') {
      stdout.write(jsonEncode({for (final p in args.skip(1)) p: scan(p)}));
    } else if (args.length == 1) {
      for (final lexeme in scan(args.single)['tokens'] as List<String>) {
        stdout.writeln(jsonEncode(lexeme));
      }
    } else {
      stderr.writeln('usage: tokens_dart.dart <file> | --json <files…>');
      exitCode = 64;
    }
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}
