# Layer checker: the awk program behind check-layers.sh (read that file first).
#
# Variables: root (folder with the layers), list (file holding one .swift path per line), exceptions (accepted
# exceptions, may be /dev/null), strict (1 = exit 1 when anything is reported).
#
# Written for the awk that ships with macOS (BWK awk 20200816): no gensub, no \b, no length(array).

BEGIN {
    # Which layers may a layer name? A type counts as belonging to the layer whose folder declares it.
    may["App"] = "*"
    may["Composition"] = "*"
    may["Presentation"] = "Presentation,Domain,Shared"
    may["Data"] = "Data,Domain,Shared"
    may["Domain"] = "Domain"
    may["Shared"] = "Shared"

    load_exceptions()

    files = 0
    while ((getline path < list) > 0) {
        layer = layer_of(path)
        if (layer == "") continue
        files++
        file[files] = path
        fileLayer[files] = layer
        read_file(files, path, layer)
    }
    close(list)

    for (f = 1; f <= files; f++) check_file(f)
    report_unused_exceptions()

    exit ((strict + 0) > 0 && findings > 0) ? 1 : 0
}

function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
}

# How many times a regular expression, given as a string, matches in a string.
function count_of(s, re) {
    return gsub(re, "&", s)
}

function may_name(from, to,    allowed) {
    allowed = may[from]
    if (allowed == "*") return 1
    return index("," allowed ",", "," to ",") > 0
}

# The layer a path belongs to: its first folder under root, when that folder is one of the layers.
function layer_of(path,    rel, slash, first) {
    rel = substr(path, length(root) + 2)
    slash = index(rel, "/")
    if (slash == 0) return ""
    first = substr(rel, 1, slash - 1)
    return (first in may) ? first : ""
}

# --- exceptions ------------------------------------------------------------------------------------------------------
# One per line: "<path under root>: <what>  # reason", where <what> is a type name or "import <Module>".

function load_exceptions(    line, text, colon, path, what, key) {
    exceptionLines = 0
    while ((getline line < exceptions) > 0) {
        exceptionLines++
        text = line
        sub(/[ \t]+#.*$/, "", text)
        text = trim(text)
        if (text == "" || text ~ /^#/) continue
        colon = index(text, ": ")
        if (colon == 0) {
            printf "%s:%d: warning: [layer] malformed exception line; expected '<path>: <name>  # reason'\n", exceptions, exceptionLines
            findings++
            continue
        }
        key = trim(substr(text, 1, colon - 1)) ": " trim(substr(text, colon + 2))
        exception[key] = exceptionLines
        exceptionAt[exceptionLines] = key
    }
    close(exceptions)
}

function report_unused_exceptions(    n, key) {
    for (n = 1; n <= exceptionLines; n++) {
        key = exceptionAt[n]
        if (key == "" || (key in exceptionUsed)) continue
        printf "%s:%d: warning: [layer] unused exception '%s'; remove it\n", exceptions, n, key
        findings++
    }
}

# --- reading ---------------------------------------------------------------------------------------------------------

# The line without string literals and comments. inblock carries an open /* ... */ comment to the next line.
function clean(line,    out, i, j) {
    if (inblock) {
        i = index(line, "*/")
        if (i == 0) return ""
        line = substr(line, i + 2)
        inblock = 0
    }
    gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
    sub(/\/\/.*$/, "", line)
    out = ""
    while ((i = index(line, "/*")) > 0) {
        out = out substr(line, 1, i - 1) " "
        line = substr(line, i + 2)
        j = index(line, "*/")
        if (j == 0) {
            inblock = 1
            line = ""
            break
        }
        line = substr(line, j + 2)
    }
    return out line
}

# Pass 1 for one file: keeps its cleaned lines and records the types it declares at the top level. A declaration is
# top level when its indentation is four spaces for every enclosing top-level #if (swift-format indents #if bodies);
# nested types, private and fileprivate types are not visible to other files and never count.
function read_file(f, path, layer,    line, code, text, n, indent, depth, preview, k, words, i, word, name) {
    inblock = 0
    depth = 0
    preview = -1
    n = 0
    while ((getline line < path) > 0) {
        n++
        code = clean(line)
        text = trim(code)
        match(code, /^ */)
        indent = RLENGTH
        # A #Preview block may wire anything, as the rules table says: its lines are not kept for checking. The block
        # ends at the first line that starts with } at the indentation of the #Preview line.
        if (preview >= 0) {
            if (text ~ /^\}/ && indent == preview) preview = -1
            lines[f, n] = ""
            continue
        }
        if (text ~ /^#Preview/) {
            if (count_of(text, "\\{") > count_of(text, "\\}")) preview = indent
            lines[f, n] = ""
            continue
        }
        lines[f, n] = code
        if (text == "") continue
        if (text ~ /^#if([ \t(]|$)/) {
            if (indent == 4 * depth) depth++
            continue
        }
        if (text ~ /^#endif/) {
            if (depth > 0 && indent == 4 * (depth - 1)) depth--
            continue
        }
        if (text ~ /^#else/) continue
        if (indent != 4 * depth) continue

        k = split(text, words, /[ \t]+/)
        name = ""
        for (i = 1; i <= k; i++) {
            word = words[i]
            if (word == "private" || word == "fileprivate") break
            if (word ~ /^@/ || word == "public" || word == "internal" || word == "open" || word == "package" || word == "final" || word == "nonisolated" || word == "indirect") continue
            if (word == "struct" || word == "class" || word == "enum" || word == "protocol" || word == "actor") name = words[i + 1]
            break
        }
        if (name == "") continue
        sub(/[<:{(].*$/, "", name)
        if (name !~ /^[A-Z][A-Za-z0-9_]*$/) continue
        if (name in declared) {
            if (declared[name] != layer) ambiguous[name] = 1
        } else {
            declared[name] = layer
        }
    }
    close(path)
    count[f] = n
}

# --- checking --------------------------------------------------------------------------------------------------------

# Pass 2 for one file: its imports, then every type it names that another layer declares.
function check_file(f,    path, layer, rel, base, isView, n, code, tmp, k, tokens, t, name, to) {
    path = file[f]
    layer = fileLayer[f]
    rel = substr(path, length(root) + 2)
    base = rel
    sub(/^.*\//, "", base)
    isView = (layer == "Presentation" && base ~ /View\.swift$/)

    for (n = 1; n <= count[f]; n++) {
        code = lines[f, n]
        if (code ~ /^[ \t]*(@[A-Za-z]+[ \t]+)*import[ \t]/) {
            check_import(rel, path, n, code, layer)
            continue
        }
        tmp = code
        gsub(/[^A-Za-z0-9_]+/, " ", tmp)
        k = split(tmp, tokens, " ")
        for (t = 1; t <= k; t++) {
            name = tokens[t]
            if (!(name in declared) || (name in ambiguous)) continue
            to = declared[name]
            if (to == layer) continue
            if (!may_name(layer, to)) {
                report(rel, path, n, name, layer " names " to " type '" name "'; " layer " must not depend on " to)
            } else if (isView && to == "Domain" && name ~ /(UseCase|Repository)$/) {
                report(rel, path, n, name, "View names Domain use case or repository '" name "'; Views talk to ViewModels")
            }
        }
    }
}

function check_import(rel, path, n, code, layer,    rest, module, message) {
    rest = code
    sub(/^[ \t]*(@[A-Za-z]+[ \t]+)*import[ \t]+/, "", rest)
    if (rest ~ /^(struct|class|enum|protocol|typealias|func|var|let)[ \t]+/) sub(/^[A-Za-z]+[ \t]+/, "", rest)
    sub(/[^A-Za-z0-9_].*$/, "", rest)
    module = rest
    message = ""
    if (layer == "Domain" && module != "Foundation") {
        message = "Domain imports '" module "'; Domain may import Foundation only"
    } else if (layer == "Data" && module == "SwiftUI") {
        message = "Data imports 'SwiftUI'; Data must not import SwiftUI"
    } else if (layer == "Shared" && (module == "SwiftUI" || module == "UIKit")) {
        message = "Shared imports '" module "'; Shared must not import UI frameworks"
    }
    if (message != "") report(rel, path, n, "import " module, message)
}

# One finding per file and name (the first line that has it), unless the exceptions list accepts it.
function report(rel, path, n, what, message,    key) {
    if ((path SUBSEP what) in reported) return
    reported[path SUBSEP what] = 1
    key = rel ": " what
    if (key in exception) {
        exceptionUsed[key] = 1
        return
    }
    printf "%s:%d: warning: [layer] %s\n", path, n, message
    findings++
}
