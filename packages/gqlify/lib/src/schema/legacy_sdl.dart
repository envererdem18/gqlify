/// Rewrites legacy `implements A, B` / `implements A B` lists (pre-2018 SDL,
/// still used by large real-world schemas such as Magento's) to the current
/// `implements A & B` syntax, which is all `package:gql` parses.
///
/// Every separator is replaced by a single `&` *in place*: the separator's
/// first character becomes `&` and nothing is inserted or removed, so line
/// and column positions of every token, and hence of diagnostics, are
/// unchanged. Strings, block strings and comments are never modified.
String normalizeLegacyImplements(String sdl) {
  final out = sdl.codeUnits.toList();
  var changed = false;
  var i = 0;
  final n = out.length;

  bool isNameStart(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
  bool isName(int c) => isNameStart(c) || (c >= 0x30 && c <= 0x39);
  bool isIgnored(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0x2C ||
      c == 0xFEFF;

  int skipIgnored(int j) {
    while (j < n) {
      final c = out[j];
      if (isIgnored(c)) {
        j++;
      } else if (c == 0x23) {
        while (j < n && out[j] != 0x0A && out[j] != 0x0D) {
          j++;
        }
      } else {
        break;
      }
    }
    return j;
  }

  while (i < n) {
    final c = out[i];
    if (c == 0x23) {
      // Comment.
      while (i < n && out[i] != 0x0A && out[i] != 0x0D) {
        i++;
      }
    } else if (c == 0x22) {
      // String or block string.
      if (i + 2 < n && out[i + 1] == 0x22 && out[i + 2] == 0x22) {
        i += 3;
        while (i < n &&
            !(out[i] == 0x22 &&
                i + 2 < n &&
                out[i + 1] == 0x22 &&
                out[i + 2] == 0x22)) {
          if (out[i] == 0x5C &&
              i + 3 < n &&
              out[i + 1] == 0x22 &&
              out[i + 2] == 0x22 &&
              out[i + 3] == 0x22) {
            i += 4;
          } else {
            i++;
          }
        }
        i += 3;
      } else {
        i++;
        while (i < n && out[i] != 0x22 && out[i] != 0x0A) {
          i += out[i] == 0x5C ? 2 : 1;
        }
        i++;
      }
    } else if (isNameStart(c)) {
      final start = i;
      while (i < n && isName(out[i])) {
        i++;
      }
      if (String.fromCharCodes(out, start, i) != 'implements') continue;
      // implements [&] Name (sep Name)*
      var j = skipIgnored(i);
      if (j < n && out[j] == 0x26) j = skipIgnored(j + 1);
      if (j >= n || !isNameStart(out[j])) continue;
      while (true) {
        while (j < n && isName(out[j])) {
          j++;
        }
        final sepStart = j;
        var hasAmp = false;
        while (j < n &&
            (isIgnored(out[j]) || out[j] == 0x26 || out[j] == 0x23)) {
          if (out[j] == 0x26) hasAmp = true;
          if (out[j] == 0x23) {
            j = skipIgnored(j);
          } else {
            j++;
          }
        }
        if (j >= n || !isNameStart(out[j])) break;
        // The next name continues the list only if it is not a keyword-less
        // following definition, which cannot happen inside an implements
        // clause: the clause ends at `{`, `@` or a description/definition.
        if (sepStart == j) break; // Names are always separated.
        final nextStart = j;
        var k = j;
        while (k < n && isName(out[k])) {
          k++;
        }
        final next = String.fromCharCodes(out, nextStart, k);
        if (const {
          'type',
          'interface',
          'union',
          'enum',
          'input',
          'scalar',
          'schema',
          'extend',
          'directive',
        }.contains(next)) {
          break;
        }
        if (!hasAmp) {
          // Replace the first separator character with `&`; a comment's `#`
          // is never first because a separator starting with `#` is invalid.
          out[sepStart] = 0x26;
          changed = true;
        }
      }
      i = j;
    } else {
      i++;
    }
  }
  return changed ? String.fromCharCodes(out) : sdl;
}
