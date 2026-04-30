#!/usr/bin/env python3
"""Prototype NeMo text normalization adapter for Local TTS.

Reads UTF-8 text on stdin and writes normalized text on stdout. This is a
development bridge for comparing NVIDIA NeMo TN/Sparrowhawk-style output with
the native app pipeline; it is not intended as the final native runtime.
"""

from __future__ import annotations

import re
import sys
import tempfile

from nemo_text_processing.text_normalization.normalize import Normalizer


OPERATOR_WHITELIST = """\
×	times
"""


def prepare_for_wfst(text: str) -> str:
    # NeMo English TN handles "20,000 ×" but not the attached "20,000×" form.
    text = re.sub(r"(?<=\d)([×])", r" \1", text)
    text = re.sub(r"([×])(?=\w)", r"\1 ", text)
    return text


def main() -> int:
    input_text = sys.stdin.read()
    if not input_text.strip():
        return 0

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".tsv") as whitelist:
        whitelist.write(OPERATOR_WHITELIST)
        whitelist.flush()
        normalizer = Normalizer(
            input_case="cased",
            lang="en",
            whitelist=whitelist.name,
        )
        output_lines: list[str] = []
        for line in input_text.splitlines():
            if not line.strip():
                output_lines.append("")
                continue
            output_lines.append(
                normalizer.normalize(
                    prepare_for_wfst(line),
                    verbose=False,
                    punct_post_process=True,
                )
            )
        normalized = "\n".join(output_lines)

    sys.stdout.write(normalized)
    if normalized and not normalized.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
