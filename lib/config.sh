# shellcheck shell=bash
# Configuration helpers shared by the CLI tools.  All writers go through an
# atomic replace so the QML panel can never observe half-written JSON.

# The plugin was renamed from omarchy-tts. Move its config, data and cache
# directories to the new name once, before anything creates the new ones, so
# installed engines and voices are kept. A destination that already exists is
# never merged into or replaced; rename(2) keeps this safe when two tools race.
# speak-setup and speak-bindings do the same in Python.
tts_migrate_legacy_dirs() {
  local base
  for base in "${XDG_CONFIG_HOME:-$HOME/.config}" "${XDG_DATA_HOME:-$HOME/.local/share}" \
              "${XDG_CACHE_HOME:-$HOME/.cache}"; do
    if [[ ( -e "$base/omarchy-tts" || -L "$base/omarchy-tts" ) &&
          ! -e "$base/omarchy-tts-local" && ! -L "$base/omarchy-tts-local" ]]; then
      mv -T -n -- "$base/omarchy-tts" "$base/omarchy-tts-local" 2>/dev/null || true
    fi
  done
}

tts_config_file() {
  # Atomic replacement of a symlink path severs dotfile-manager links. Resolve
  # an existing link and replace its target instead; ordinary paths are left
  # untouched. A dangling link is unsafe to guess at and is rejected.
  if [[ -L "$CONFIG" ]]; then
    [[ -e "$CONFIG" && -f "$CONFIG" ]] || return 1
    local target
    target="$(readlink -f -- "$CONFIG")" || return 1
    [[ -n "$target" && -f "$target" ]] || return 1
    printf '%s' "$target"
  else
    [[ ! -e "$CONFIG" || -f "$CONFIG" ]] || return 1
    printf '%s' "$CONFIG"
  fi
}

tts_with_config_lock() { # function [args...]
  local lock_fd rc config_file
  config_file="$(tts_config_file)" || return 1
  [[ -n "$config_file" ]] || return 1
  mkdir -p "$(dirname "$config_file")"
  exec {lock_fd}>>"${config_file}.lock" || return 1
  flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  "$@"; rc=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$rc"
}

tts_config_init() {
  tts_with_config_lock tts_config_init_unlocked
}

tts_config_init_unlocked() {
  local config_file invalid tmp
  config_file="$(tts_config_file)" || return 1
  [[ -n "$config_file" ]] || return 1

  if [[ -e "$config_file" ]] &&
      { [[ "$(stat -c%s "$config_file" 2>/dev/null || printf 1048577)" -gt 1048576 ]] ||
        ! jq -e 'type == "object"' "$config_file" >/dev/null 2>&1; }; then
    invalid="${config_file}.invalid.$(date +%Y%m%dT%H%M%S).$$"
    mv -T -- "$config_file" "$invalid" || return 1
    chmod 600 "$invalid" || return 1
    printf 'speak: preserved invalid configuration as %s\n' "$invalid" >&2
  fi
  if [[ ! -s "$config_file" ]]; then
    tmp="$(mktemp "${config_file}.XXXXXX")" || return 1
    if ! cat >"$tmp" <<'JSON'
{
  "schemaVersion": 6,
  "provider": "kokoro_onnx",
  "rate": 1.0,
  "maxChars": 0,
  "piper": { "voice": "en_US-amy-medium" },
  "kokoro": { "voice": "af_heart", "device": "cpu" },
  "kokoro_onnx": { "voice": "af_heart", "device": "cpu", "keepWarm": 10 },
  "ocr": { "engine": "tesseract", "langs": "eng", "minConfidence": 60 },
  "sanitizer": {
    "urls": "domain",
    "inlineCode": true,
    "announceCodeBlocks": true,
    "stripMarkdown": true,
    "expandUnits": true
  },
  "ui": {
    "lastTab": 0,
    "sampleText": "Highlight any text and press the key. This is how it sounds right now."
  }
}
JSON
    then
      rm -f "$tmp"
      return 1
    fi
    if ! chmod 600 "$tmp" || ! mv -T -- "$tmp" "$config_file"; then
      rm -f "$tmp"
      return 1
    fi
  fi

  # Preserve syntactically valid but structurally unsafe input before repairing
  # it. This includes the nested scalar/array shapes that used to make every
  # command, including --stop, fail during migration.
  if ! jq -e '
      type == "object"
      and ([.piper,.kokoro,.kokoro_onnx,.ocr,.sanitizer,.ui]
           | all(. == null or type == "object"))
      and (.ocr == null or (.ocr.tesseract == null or (.ocr.tesseract|type) == "object"))
      and (.ocr == null or (.ocr.easyocr == null or (.ocr.easyocr|type) == "object"))
      and (.ocr == null or (.ocr.engine|type) != "string"
           or .ocr[.ocr.engine] == null or (.ocr[.ocr.engine]|type) == "object")
    ' "$config_file" >/dev/null 2>&1; then
    invalid="${config_file}.invalid.$(date +%Y%m%dT%H%M%S).$$"
    cp -- "$config_file" "$invalid" || return 1
    chmod 600 "$invalid" || return 1
    printf 'speak: preserved structurally invalid configuration as %s\n' "$invalid" >&2
  fi

  # Additive, type-safe migration. Valid user values win; malformed leaves are
  # normalized individually instead of taking the entire control plane down.
  # Providers and OCR engines that no longer exist (the retired cloud services
  # and espeak/spd) fall back to the local defaults, and their settings go.
  tmp="$(mktemp "${config_file}.XXXXXX")" || return 1
  if jq '
    (if (.schemaVersion|type) == "number" then .schemaVersion else 0 end) as $schema
    | .schemaVersion = 6
    | .provider = (if (.provider|type) == "string" and (.provider|test("^[A-Za-z0-9._-]+$")) then .provider else "piper" end)
    | .provider = (if .provider | IN("espeak-ng", "spd", "openai", "elevenlabs", "gemini", "google") then "piper" else .provider end)
    | del(.openai, .elevenlabs, .gemini, .google)
    | .piper = (if (.piper|type) == "object" then .piper else {} end)
    | .kokoro = (if (.kokoro|type) == "object" then .kokoro else {} end)
    | .kokoro_onnx = (if (.kokoro_onnx|type) == "object" then .kokoro_onnx else {} end)
    | .ocr = (if (.ocr|type) == "object" then .ocr else {} end)
    | .sanitizer = (if (.sanitizer|type) == "object" then .sanitizer else {} end)
    | .ui = (if (.ui|type) == "object" then .ui else {} end)
    | .piper.voice = (if (.piper.voice|type) == "string" and (.piper.voice|test("^[A-Za-z0-9._+-]+$")) then .piper.voice else "en_US-amy-medium" end)
    | .kokoro.voice = (if (.kokoro.voice|type) == "string" and (.kokoro.voice|test("^[A-Za-z0-9._+-]+$")) then .kokoro.voice else "af_heart" end)
    | .kokoro.device = (if .kokoro.device == "gpu" then "gpu" else "cpu" end)
    | .kokoro_onnx.voice = (if (.kokoro_onnx.voice|type) == "string" and (.kokoro_onnx.voice|test("^[a-z]{2}_[a-z]+$")) then .kokoro_onnx.voice else "af_heart" end)
    | .kokoro_onnx.device = (if .kokoro_onnx.device == "gpu" then "gpu" else "cpu" end)
    | .kokoro_onnx.keepWarm = (if (.kokoro_onnx.keepWarm|type)=="number" and .kokoro_onnx.keepWarm>=0 and .kokoro_onnx.keepWarm<=240 then (.kokoro_onnx.keepWarm|floor) else 10 end)
    | .ocr.engine = (if (.ocr.engine|type) == "string" and (.ocr.engine|test("^[A-Za-z0-9._-]+$")) then .ocr.engine else "tesseract" end)
    | .ocr.engine = (if .ocr.engine == "openai" or .ocr.engine == "google" then "tesseract" else .ocr.engine end)
    | del(.ocr.openai, .ocr.google)
    | .ocr.engine as $ocrEngine
    | .ocr[$ocrEngine] = (if (.ocr[$ocrEngine]|type) == "object" then .ocr[$ocrEngine] else {} end)
    | .ocr.langs = (if (.ocr.langs|type) == "string" and (.ocr.langs|test("^[A-Za-z0-9_+.-]+$")) then .ocr.langs else "eng" end)
    | .ocr.tesseract = (if (.ocr.tesseract|type) == "object" then .ocr.tesseract else {} end)
    | .ocr.tesseract.langs = (if (.ocr.tesseract.langs|type) == "string" and (.ocr.tesseract.langs|test("^[A-Za-z0-9_+.-]+$")) then .ocr.tesseract.langs else .ocr.langs end)
    | .ocr.easyocr = (if (.ocr.easyocr|type) == "object" then .ocr.easyocr else {} end)
    | .ocr.easyocr.langs = (if (.ocr.easyocr.langs|type) == "string" and (.ocr.easyocr.langs|test("^[A-Za-z0-9_+.-]+$")) then .ocr.easyocr.langs else "eng" end)
    | .sanitizer.urls = (if .sanitizer.urls == "link" then "link" else "domain" end)
    | .sanitizer.inlineCode = (if (.sanitizer.inlineCode|type) == "boolean" then .sanitizer.inlineCode else true end)
    | .sanitizer.announceCodeBlocks = (if (.sanitizer.announceCodeBlocks|type) == "boolean" then .sanitizer.announceCodeBlocks else true end)
    | .sanitizer.stripMarkdown = (if (.sanitizer.stripMarkdown|type) == "boolean" then .sanitizer.stripMarkdown else true end)
    | .sanitizer.expandUnits = (if (.sanitizer.expandUnits|type) == "boolean" then .sanitizer.expandUnits else true end)
    | del(.ui.collapsed)
    | .ui.sampleText = (if (.ui.sampleText|type) == "string" then .ui.sampleText[0:4096] else "Highlight any text and press the key. This is how it sounds right now." end)
    | .rate = (if (.rate|type)=="number" and .rate>=0.25 and .rate<=4 then .rate else 1.0 end)
    | .maxChars = (if (.maxChars|type)=="number" and .maxChars>=0 and .maxChars<=1048576 then (.maxChars|floor) else 0 end)
    | .ocr.minConfidence = (if (.ocr.minConfidence|type)=="number" and .ocr.minConfidence>=0 and .ocr.minConfidence<=100 then (.ocr.minConfidence|floor) else 60 end)
    | .ui.lastTab = (if (.ui.lastTab|type)=="number" and .ui.lastTab>=0 and .ui.lastTab<=5 then (.ui.lastTab|floor) else 0 end)
    # Schema 6 merged the Provider and Screen tabs into Providers. Map the old
    # six-tab index so the panel reopens on the same content.
    | .ui.lastTab = (if $schema < 6 then [0, 1, 2, 0, 3, 4][.ui.lastTab] else .ui.lastTab end)
    | .ui.lastTab = (if .ui.lastTab <= 4 then .ui.lastTab else 0 end)
  ' "$config_file" >"$tmp"; then
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if cmp -s -- "$tmp" "$config_file"; then
      rm -f "$tmp"
    else
      mv -T -- "$tmp" "$config_file" || { rm -f "$tmp"; return 1; }
    fi
    chmod 600 "$config_file" || return 1
    return 0
  fi
  rm -f "$tmp"
  return 1
}

tts_config_set() { # jq path, JSON-or-string value
  tts_with_config_lock tts_config_set_unlocked "$@"
}

tts_config_set_unlocked() { # jq path, JSON-or-string value
  local path="$1" value="$2" tmp engine="" config_file
  config_file="$(tts_config_file)" || return 1
  [[ -n "$config_file" ]] || return 1
  if [[ "$path" =~ ^\.ocr\.([A-Za-z0-9._-]+)\.langs$ ]]; then
    engine="${BASH_REMATCH[1]}"
  fi
  case "$path" in
    .provider|.rate|.maxChars|.piper.voice|.kokoro.voice|\
    .kokoro.device|.kokoro_onnx.voice|.kokoro_onnx.device|.kokoro_onnx.keepWarm|\
    .ocr.engine|.ocr.langs|.ocr.tesseract.langs|.ocr.easyocr.langs|.ocr.minConfidence|\
    .sanitizer.urls|.sanitizer.inlineCode|.sanitizer.announceCodeBlocks|\
    .sanitizer.stripMarkdown|.sanitizer.expandUnits|.ui.lastTab|.ui.sampleText) ;;
    *) [[ -n "$engine" ]] || return 2 ;;
  esac
  case "$path" in
    .provider) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 3 ;;
    .piper.voice|.kokoro.voice)
      [[ "$value" =~ ^[A-Za-z0-9._+-]+$ ]] || return 3 ;;
    .kokoro_onnx.voice) [[ "$value" =~ ^[a-z]{2}_[a-z]+$ ]] || return 3 ;;
    .kokoro.device|.kokoro_onnx.device) [[ "$value" == cpu || "$value" == gpu ]] || return 3 ;;
    .kokoro_onnx.keepWarm) [[ "$value" =~ ^[0-9]{1,3}$ ]] && [[ "$value" -le 240 ]] || return 3 ;;
    .rate)
      [[ "$value" =~ ^(0?[.][0-9]+|[1-3]([.][0-9]+)?|4([.]0+)?)$ ]] || return 3
      awk -v value="$value" 'BEGIN { exit !(value >= 0.25 && value <= 4.0) }' || return 3 ;;
    .maxChars)
      [[ "$value" =~ ^[0-9]+$ && ${#value} -le 7 ]] || return 3
      awk -v value="$value" 'BEGIN { exit !(value <= 1048576) }' || return 3 ;;
    .ocr.minConfidence)
      [[ "$value" =~ ^[0-9]+$ ]] &&
        awk -v value="$value" 'BEGIN { exit !(value <= 100) }' || return 3 ;;
    .ocr.engine) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 3 ;;
    .ocr.langs|*.langs) [[ "$value" =~ ^[A-Za-z0-9_+.-]+$ ]] || return 3 ;;
    .sanitizer.urls) [[ "$value" == domain || "$value" == link ]] || return 3 ;;
    .sanitizer.inlineCode|.sanitizer.announceCodeBlocks|.sanitizer.stripMarkdown|.sanitizer.expandUnits)
      [[ "$value" == true || "$value" == false ]] || return 3 ;;
    .ui.lastTab) [[ "$value" =~ ^[0-4]$ ]] || return 3 ;;
    .ui.sampleText) [[ ${#value} -le 4096 ]] || return 3 ;;
  esac
  tmp="$(mktemp "${config_file}.XXXXXX")" || return 1
  if [[ -n "$engine" ]]; then
    jq --arg engine "$engine" --arg value "$value" \
      '.ocr[$engine] = (if (.ocr[$engine]|type) == "object" then .ocr[$engine] else {} end)
       | .ocr[$engine].langs = $value' "$config_file" >"$tmp"
  elif [[ "$path" == .rate || "$path" == .maxChars || "$path" == .ocr.minConfidence ||
          "$path" == .kokoro_onnx.keepWarm ||
          "$path" == .ui.lastTab || "$path" == .sanitizer.inlineCode ||
          "$path" == .sanitizer.announceCodeBlocks || "$path" == .sanitizer.stripMarkdown ||
          "$path" == .sanitizer.expandUnits ]]; then
    jq --argjson value "$value" "$path = \$value" "$config_file" >"$tmp"
  else
    jq --arg value "$value" "$path = \$value" "$config_file" >"$tmp"
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s -- "$tmp" "$config_file"; then
    rm -f "$tmp"
  else
    mv -T -- "$tmp" "$config_file" || { rm -f "$tmp"; return 1; }
  fi
}
