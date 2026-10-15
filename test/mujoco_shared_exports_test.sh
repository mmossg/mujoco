#!/bin/bash
# Copyright 2026 DeepMind Technologies Limited
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Checks that the shared MuJoCo library exports MuJoCo's API and nothing else:
# only mj* symbols (and the private _mj* functions used by the Python bindings),
# so that engine internals and the bundled third-party libraries stay hidden.
#
# Usage: mujoco_shared_exports_test.sh <path to libmujoco.so or .dylib>

set -euo pipefail

lib="$1"

if [[ "$(uname)" == "Darwin" ]]; then
  # Mach-O symbol names have an extra leading underscore.
  symbols="$(nm -g --defined-only "${lib}" | awk '{print $NF}' | sed 's/^_//')"
else
  symbols="$(nm -D --defined-only "${lib}" 2>/dev/null | awk '{print $NF}' | sed 's/@.*$//')"
fi

# Ignore the __start_*/__stop_* section bounds the linker itself adds for named
# sections in linked-in code (e.g. malloc hooks); they aren't part of the API.
unexpected="$(grep -v -E '^_?mj' <<< "${symbols}" | grep -v -E '^__(start|stop)_' || true)"
if [[ -n "${unexpected}" ]]; then
  echo "FAIL: ${lib} exports symbols other than mj* and _mj*:"
  echo "${unexpected}" | head -50
  exit 1
fi

# Guard against an empty or truncated export list, e.g. a broken linker script.
for expected in mj_step mj_forward mju_error _mjPRIVATE_setTlsLogHandler; do
  if ! grep -q -x "${expected}" <<< "${symbols}"; then
    echo "FAIL: ${lib} doesn't export ${expected}"
    exit 1
  fi
done

echo "PASS: ${lib} exports $(wc -l <<< "${symbols}") symbols, all mj* or _mj*"
