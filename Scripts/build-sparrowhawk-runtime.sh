#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT/.build"
SRC="$BUILD_ROOT/sparrowhawk-src"
INSTALL="$BUILD_ROOT/sparrowhawk-install"
RUNTIME="$BUILD_ROOT/sparrowhawk-runtime"
NEMO_PYTHON="${NEMO_TN_PYTHON:-}"

if [[ -z "${CPLUS_INCLUDE_PATH:-}" ]]; then
  sdk_path="$(xcrun -sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "$sdk_path" && -d "$sdk_path/usr/include/c++/v1" ]]; then
    export CPLUS_INCLUDE_PATH="$sdk_path/usr/include/c++/v1"
  fi
fi

if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
else
  BREW_PREFIX="/opt/homebrew"
fi

if [[ ! -d "$BREW_PREFIX/include/thrax" || ! -d "$BREW_PREFIX/include/fst" ]]; then
  echo "Skipping Sparrowhawk runtime: install Homebrew thrax/openfst/protobuf/re2 first." >&2
  exit 0
fi

if [[ -z "$NEMO_PYTHON" ]]; then
  if [[ -x "$BUILD_ROOT/nemo-tn-venv/bin/python" ]]; then
    NEMO_PYTHON="$BUILD_ROOT/nemo-tn-venv/bin/python"
  elif python3 - <<'PY' >/dev/null 2>&1
import nemo_text_processing
import pynini
PY
  then
    NEMO_PYTHON="python3"
  else
    echo "Skipping Sparrowhawk runtime: NeMo text processing and Pynini are not available." >&2
    exit 0
  fi
fi

if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$BUILD_ROOT"
  git clone --depth 1 https://github.com/google/sparrowhawk.git "$SRC"
fi

mkdir -p "$SRC/src/include/sparrowhawk"
cat > "$SRC/src/include/sparrowhawk/port_compat.h" <<'EOF'
#ifndef SPARROWHAWK_PORT_COMPAT_H_
#define SPARROWHAWK_PORT_COMPAT_H_

#include <cstdint>
#include <iostream>
#include <string>

using int32 = int32_t;
using int64 = int64_t;
using std::string;

#ifndef DISALLOW_COPY_AND_ASSIGN
#define DISALLOW_COPY_AND_ASSIGN(TypeName) \
  TypeName(const TypeName&) = delete;      \
  void operator=(const TypeName&) = delete
#endif

namespace speech {
namespace sparrowhawk {

class CompatLogMessage {
 public:
  CompatLogMessage() = default;
  ~CompatLogMessage() { std::cerr << std::endl; }

  template <typename T>
  CompatLogMessage& operator<<(const T& value) {
    std::cerr << value;
    return *this;
  }
};

}  // namespace sparrowhawk
}  // namespace speech

#ifndef LOG
#define LOG(level) ::speech::sparrowhawk::CompatLogMessage()
#endif

#endif
EOF

perl -0pi -e 's/-std=c\+\+11/-std=c++17/g' "$SRC/configure" 2>/dev/null || true
perl -0pi -e 's/fst::StringTokenType::BYTE/fst::TokenType::BYTE/g' \
  "$SRC/src/include/sparrowhawk/spec_serializer.h" \
  "$SRC/src/lib/rule_system.cc" \
  "$SRC/src/lib/normalizer.cc" \
  "$SRC/src/lib/record_serializer.cc" 2>/dev/null || true
perl -0pi -e 's/fst::PROJECT_OUTPUT/fst::ProjectType::OUTPUT/g' "$SRC/src/lib/rule_system.cc"
perl -0pi -e 's/field->label\(\) == FieldDescriptor::LABEL_REPEATED/field->is_repeated()/g' \
  "$SRC/src/lib/record_serializer.cc" \
  "$SRC/src/lib/style_serializer.cc"
perl -0pi -e 's/matched_pieces\[(\d+)\]\.as_string\(\)/string(matched_pieces[$1])/g' \
  "$SRC/src/lib/regexp.cc"
perl -0pi -e 's/candidate_class\.first->name\(\) \+ kClassSeparator/std::string(candidate_class.first->name()) + kClassSeparator/g' \
  "$SRC/src/lib/spec_serializer.cc"
perl -0pi -e 's/field->name\(\) \+ " \{ "/std::string(field->name()) + " { "/g; s/const string name = field->name\(\);/const string name(field->name());/g' \
  "$SRC/src/lib/protobuf_serializer.cc"
perl -0pi -e 's/(?:FST_)+FLAGS_/FST_FLAGS_/g; s/(?<!FST_)FLAGS_config/FST_FLAGS_config/g; s/(?<!FST_)FLAGS_path_prefix/FST_FLAGS_path_prefix/g; s/(?<!FST_)FLAGS_multi_line_text/FST_FLAGS_multi_line_text/g' \
  "$SRC/src/bin/normalizer_main.cc"

if ! grep -q '#include <string>' "$SRC/src/lib/spec_serializer.cc"; then
  perl -0pi -e 's/#include <memory>/#include <memory>\n#include <string>/' "$SRC/src/lib/spec_serializer.cc"
fi
if ! grep -q '#include <string>' "$SRC/src/lib/protobuf_serializer.cc"; then
  perl -0pi -e 's/#include <map>/#include <map>\n#include <string>/' "$SRC/src/lib/protobuf_serializer.cc"
fi

touch \
  "$SRC/aclocal.m4" \
  "$SRC/configure" \
  "$SRC/Makefile.in" \
  "$SRC/src/Makefile.in" \
  "$SRC/src/include/Makefile.in" \
  "$SRC/src/lib/Makefile.in" \
  "$SRC/src/proto/Makefile.in" \
  "$SRC/src/bin/Makefile.in"

(
  cd "$SRC"
  ./configure \
    --prefix="$INSTALL" \
    CPPFLAGS="-I$BREW_PREFIX/include -funsigned-char" \
    CXXFLAGS="-funsigned-char -std=c++17" \
    LDFLAGS="-L$BREW_PREFIX/lib -Wl,-headerpad_max_install_names"
  make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    CXXFLAGS="-funsigned-char -std=c++17 -include $SRC/src/include/sparrowhawk/port_compat.h"
  make install
)

rm -rf "$RUNTIME"
mkdir -p "$RUNTIME/bin" "$RUNTIME/lib" "$RUNTIME/share/classify" "$RUNTIME/share/verbalize"

"$NEMO_PYTHON" - "$RUNTIME/share" <<'PY'
from pathlib import Path
import sys

from nemo_text_processing.text_normalization.en.taggers.tokenize_and_classify import ClassifyFst
from nemo_text_processing.text_normalization.en.verbalizers.verbalize_final import VerbalizeFinalFst
from pynini.export import export

out = Path(sys.argv[1])
(out / "classify").mkdir(parents=True, exist_ok=True)
(out / "verbalize").mkdir(parents=True, exist_ok=True)

classifier = ClassifyFst(input_case="cased", deterministic=True)
sink = export.Exporter(out / "classify" / "tokenize_and_classify.far")
sink["TOKENIZE_AND_CLASSIFY"] = classifier.fst
sink.close()

verbalizer = VerbalizeFinalFst(deterministic=True)
sink = export.Exporter(out / "verbalize" / "verbalize_final.far")
sink["VERBALIZE"] = verbalizer.fst
sink.close()
PY

cat > "$RUNTIME/share/tokenizer.ascii_proto" <<'EOF'
grammar_file: "classify/tokenize_and_classify.far"
grammar_name: "NeMoTokenizerClassifier"
rules { main: "TOKENIZE_AND_CLASSIFY" }
EOF

cat > "$RUNTIME/share/verbalizer_final.ascii_proto" <<'EOF'
grammar_file: "verbalize/verbalize_final.far"
grammar_name: "NeMoFinalVerbalizer"
rules { main: "VERBALIZE" }
EOF

g++ \
  -std=c++17 \
  -funsigned-char \
  -I"$SRC/src/include" \
  -I"$SRC/src/include/sparrowhawk" \
  -I"$BREW_PREFIX/include" \
  -L"$INSTALL/lib" \
  -L"$BREW_PREFIX/lib" \
  -Wl,-headerpad_max_install_names \
  "$ROOT/Native/Sparrowhawk/nemo_normalizer_main.cc" \
  -lsparrowhawk \
  -lthrax \
  -lfstfar \
  -lfst \
  -lprotobuf \
  -lre2 \
  -o "$RUNTIME/bin/nemo_normalizer_main"

cp "$INSTALL/lib/libsparrowhawk.0.dylib" "$RUNTIME/lib/"
echo "$RUNTIME"
