# CoddOnboarding

The first-launch wizard of CODD Desktop (docs/M5-PLAN.md D5–D13, §2.3–§2.5; the frozen
`design/artboards-src/Onboarding.src.html`). The App (integration step I2) owns the window, the probes,
the import and `onboarding.json`; this package holds the data rules and the views.

| Target | What it is |
|---|---|
| `CoddOnboarding` (Foundation only) | `OnboardingStep` / `StepProgress` / `OnboardingFlow`; `EnvironmentFacts` → `EnvironmentReport` (the boot block, D11) and `DetectItem`; the step models; `ProjectCatalogReader` (read-only `~/.claude.json` + transcript folders, D8), `NamePrefixRule` (D10), `PathText` (standardize, `~`, front elision), `LastUsedFormat`; `GroupSuggester` (D9), `ImportSelection`, `ImportPlan`, `ImportStepModel`; `OnboardingGate` (D5), `OnboardingState` / `OnboardingStateStore` (§2.3); `OnboardingSamples` (the artboard's data). |
| `CoddOnboardingUI` (AppKit + CoddUI) | `OnboardingView` + `OnboardingActions` (§2.4b): the 260 px stepper, the boot block, the step head, the six step bodies (step 2's table with the overlay group menu), the 60 px footer. Hand laid out in `layout()` through `dz` / `UIZoom.pt`; fonts through `Typeface`; the blinking `_` on `UITicker`; no scanlines (the App adds them). |
| `codd-onboarding-demo` | Offscreen PNGs of every step and state. |

```sh
swift build --package-path Packages/CoddOnboarding --scratch-path .build-onboarding
swift test  --package-path Packages/CoddOnboarding --scratch-path .build-onboarding
swift run   --package-path Packages/CoddOnboarding --scratch-path .build-onboarding codd-onboarding-demo \
    --fonts App/Fonts --snapshot <dir>      # step1…step6, step1-problems, step2-menu, step2-hidden,
                                            # step5-nocswap, step6-granted; each also as <name>-min (1011 × 640)
```

The demo never orders a window in and never activates (`--snapshot`); without `--snapshot` it opens a
window for people only. `scripts/m5-fixtures/make-import-fixture.sh` writes a made-up import source that
`CoddOnboardingTests/FixtureTests` reads back.
