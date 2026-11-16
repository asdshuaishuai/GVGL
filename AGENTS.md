<!-- OPENWIKI:START -->

## OpenWiki

This repository has a generated `openwiki/` evidence index. It is optional just-in-time context, not required startup reading.

- Treat source code and tests as authoritative. A brief's unknowns and review items are verification gaps, not automatic requirements.
- Prefer the narrowest quiet validation that proves the changed behavior. Preserve complete failure output.

The scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki. Do not hand-edit generated OpenWiki pages unless explicitly asked; prefer updating source code/docs and letting OpenWiki regenerate.

<!-- OPENWIKI:END -->

# Repository Guidelines

## Project Structure & Module Organization

- `Package.swift` defines SPM products: `GVGLCore`, `GVGLSync`, `GVGLServer`, `GVGLQuery`, `GVGLAction`, and executables `gvgl`, `gvglui`, `gvglact`.
- `Sources/` contains module code: `GVGLCore` (geometry/topology/ID stabilization), `GVGLSync` (workspace/observer/sync), `GVGLServer` (Unix socket API), `GVGLQuery` (client + parser), `GVGLAction` (computer-use executor: AX actions, synthetic input, verification), `gvgl` (read-only daemon), `gvglui` (SwiftUI review console), `gvglact` (executor CLI).
- `Tests/` mirrors source modules with XCTest suites.
- `scripts/` provides packaging, install/uninstall launchd, geometry/coverage audits, the zero-screenshot audit, and end-to-end smoke scripts.
- `client/` holds Python query client utilities.
- `docs/` and `DESIGN.md` are authoritative design references.
- 本项目目前仅针对 macOS；`gvglui` 为 SwiftUI 应用，守护进程依赖 macOS Accessibility API 与 launchd。动作由独立进程 `gvglact` 执行，守护进程保持只读。

## Build, Test, and Development Commands

```bash
swift build -c release        # Build all targets
swift test                   # Run full XCTest suite
scripts/package-apps.sh --install  # Build app bundle into /Applications/GVGL.app
python3 client/gvgl_query.py status # Quick client check against running daemon
python3 scripts/audit_geometry.py   # Runtime geometry invariant audit
scripts/audit_no_screenshot.sh      # Must stay green: no capture/OCR APIs
python3 scripts/act_smoke.py --socket /tmp/gvgl-act.sock  # End-to-end act loop
```

## Coding Style & Naming Conventions

- Swift 5 / tools-version 6.0, target macOS 14+.
- Follow Apple API design guidelines: types `UpperCamelCase`, methods/properties `lowerCamelCase`.
- Prefer small, focused types in module directories; avoid cross-module access beyond declared dependencies.
- Use 4-space indentation and keep line length reasonable for readability.

## Testing Guidelines

- Use XCTest; place tests in `Tests/<Module>Tests/`.
- Name test files after the behavior they cover, e.g., `SceneTreeTests.swift`, `GridIndexTests.swift`.
- Favor deterministic unit tests with synthetic fixtures; avoid flaky timing-based assertions.
- Run `swift test` before committing; preserve complete failure output if diagnosing.

## Commit & Pull Request Guidelines

- Use clear, imperative commit messages; describe behavior change and rationale.
- Keep commits scoped to one logical change per module.
- Pull requests should include a concise description, rationale, and any test evidence or runtime verification steps.

## Agent-Specific Instructions

- Follow Karpathy-style minimal changes: only edit what the task requires; do not refactor adjacent code.
- When uncertain about behavior or API usage, inspect `Sources/`, `Tests/`, and `DESIGN.md` rather than guessing.
- Treat `DESIGN.md` as the authoritative specification; code and tests must remain consistent with it.
