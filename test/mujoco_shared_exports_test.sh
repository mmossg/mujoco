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

# Checks that the shared MuJoCo library exports exactly MuJoCo's API: every
# function and variable mujoco.h declares with MJAPI, plus the private
# _mjPRIVATE_* functions used by the Python bindings, so that engine internals
# and the bundled third-party libraries stay hidden.
#
# Usage: mujoco_shared_exports_test.sh [--exclude=REGEX] <exports> <header>...
#
# <exports> lists the library's exported symbols, one per line. The headers
# must include mujoco.h. --exclude skips API names matching REGEX that the
# library isn't expected to export.

set -euo pipefail

exclude=""
positional=()
for arg in "$@"; do
  case "${arg}" in
    --exclude=*) exclude="${arg#--exclude=}" ;;
    *) positional+=("${arg}") ;;
  esac
done
exports="${positional[0]}"
headers=("${positional[@]:1}")
mujoco_h=""
for header in "${headers[@]}"; do
  [[ "$(basename "${header}")" == "mujoco.h" ]] && mujoco_h="${header}"
done
if [[ -z "${mujoco_h}" ]]; then
  echo "FAIL: mujoco.h isn't among the headers: ${headers[*]}"
  exit 1
fi

symbols="$(sort -u "${exports}")"

# Prints the names declared with MJAPI, e.g. "MJAPI void mj_step(...);" or
# "MJAPI extern void* (*mju_user_malloc)(size_t);". With max_depth=1, only those
# outside conditional blocks (other than the include guard).
mjapi_names() {
  local max_depth="$1"
  shift
  awk -v max_depth="${max_depth}" '
    /^#[ \t]*if/ { depth++ }
    /^#[ \t]*endif/ { depth-- }
    depth <= max_depth && /^MJAPI/ {
      s = $0
      sub(/^MJAPI[ \t]+/, "", s)
      if (match(s, /\(\*[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
        name = substr(s, RSTART + 2, RLENGTH - 2)
        gsub(/[ \t]/, "", name)
      } else {
        sub(/[(\[;].*/, "", s)
        name = s
        sub(/.*[^A-Za-z0-9_]/, "", name)
      }
      print name
    }' "$@" | sort -u
}

# Anything declared with MJAPI may be exported, including names that depend on
# the build (e.g. the stack functions with AddressSanitizer).
allowed="$(mjapi_names 1000 "${headers[@]}")"

# Ignore the __start_*/__stop_* section bounds the linker itself adds for named
# sections in linked-in code (e.g. malloc hooks); they aren't part of the API.
# Also allow C++ symbols in MuJoCo's own namespace (_ZN6mujoco..., _ZZN6mujoco...):
# some toolchains can't hide inline and thread-local statics with a linker
# script (GCC 13 on Ubuntu 24.04 exports two), and unlike third-party symbols
# they can't clash with other libraries.
unexpected="$(comm -23 <(echo "${symbols}") <(echo "${allowed}") |
  grep -v -E '^_mjPRIVATE_' |
  grep -v -E '^__(start|stop)_' |
  grep -v -E '^_ZZ?N6mujoco' || true)"
if [[ -n "${unexpected}" ]]; then
  echo "FAIL: the library exports symbols that aren't MJAPI or _mjPRIVATE_*:"
  echo "${unexpected}" | head -50
  exit 1
fi

# Every unconditional MJAPI name in mujoco.h must be exported.
api="$(mjapi_names 1 "${mujoco_h}")"
if [[ -n "${exclude}" ]]; then
  api="$(grep -v -E "${exclude}" <<< "${api}" || true)"
fi

# Guard against a broken header parse.
if [[ "$(wc -l <<< "${api}")" -lt 100 ]]; then
  echo "FAIL: found only $(wc -l <<< "${api}") MJAPI names in ${mujoco_h}"
  exit 1
fi

missing="$(comm -23 <(echo "${api}") <(echo "${symbols}"))"
if [[ -n "${missing}" ]]; then
  echo "FAIL: the library doesn't export these MJAPI names from mujoco.h:"
  echo "${missing}" | head -50
  exit 1
fi

echo "PASS: the library exports $(wc -l <<< "${symbols}") symbols, all MJAPI or" \
  "_mjPRIVATE_*, including all $(wc -l <<< "${api}") MJAPI names checked from mujoco.h"
