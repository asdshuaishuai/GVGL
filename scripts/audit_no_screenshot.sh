#!/usr/bin/env bash
# Fail if any source file can capture pixels or run OCR.
#
# GVGL's whole premise is that the accessibility tree is enough to perceive and
# operate a desktop. That premise decays the moment someone adds "just a small
# screenshot fallback": the daemon would gain a screen-recording permission, the
# frame pipeline would start carrying images, and the read-only audit would stop
# meaning anything. This gate makes the constraint mechanical instead of a
# comment nobody reads.
#
# Run in CI and before release:
#   scripts/audit_no_screenshot.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Capture / OCR entry points. Each one is enough on its own to violate the
# guarantee; none of them has a legitimate use in this repository today.
PATTERNS=(
  'CGWindowListCreateImage'
  'CGWindowListCreateImageFromArray'
  'CGDisplayCreateImage'
  'CGDisplayStream'
  'SCScreenshotManager'
  'SCShareableContent'
  'SCStream'
  'screencapture'
  'CGWindowListCreateImageFromArray'
  'import Vision'
  'VNRecognizeTextRequest'
  'VNImageRequestHandler'
  'ImageGrab'
  'pyautogui'
  'mss\.'
  'PIL\.Image'
)

SCAN_DIRS=(Sources client Tests scripts)
FAILED=0

for pattern in "${PATTERNS[@]}"; do
  # -I skips binaries; -n keeps line numbers; --include keeps the scan tight.
  hits=$(grep -rInE --include='*.swift' --include='*.py' --include='*.sh' \
    -- "$pattern" "${SCAN_DIRS[@]}" 2>/dev/null \
    | grep -v 'audit_no_screenshot.sh' || true)
  if [ -n "$hits" ]; then
    echo "✗ forbidden screenshot/OCR API: $pattern" >&2
    echo "$hits" >&2
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo >&2
  echo "GVGL must stay screenshot-free: use the AX tree (gvglact transcript/find)" >&2
  echo "instead of capturing pixels. See DESIGN.md §V6." >&2
  exit 1
fi

echo "✓ no screenshot or OCR APIs in Sources/, client/, Tests/, scripts/"
echo "  perception is accessibility-tree only (gvglact find / transcript)"
