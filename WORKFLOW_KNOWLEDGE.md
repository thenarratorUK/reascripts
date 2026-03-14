# Workflow Knowledge Base (Derived from This ReaScripts Repository)

## Purpose
This document captures inferred workflow patterns, naming conventions, and operating assumptions from the scripts in this repo so future automation can align with your process.

## High-level workflow model
Your scripts suggest an audiobook/dialogue post-production workflow in REAPER with strong emphasis on:

1. **Punch-and-roll recording flow**
   - Start/end controls for ripple inserts and punch behaviors.
   - Silence-aware rewind and tail-tightening helpers.
2. **Breath and click management**
   - Dedicated detection, checking, marking, and reduction tools.
   - Recheck loops that support iterative QC.
3. **Take management and selection**
   - Color-based states, multitake triage, and extraction/reordering of preferred takes.
4. **Track architecture automation**
   - Character FX tracks/sends setup/reset plus validation scripts.
5. **Batch import/export + integration utilities**
   - Source build/update tools, pickup CSV conversion/import, render re-import.
6. **Proofing and reporting**
   - Checkpoint checks, marker movement, pay/reporting utilities, and region makers.

## Consistent operational assumptions
The scripts repeatedly imply these conventions:

- **Named tracks are semantic anchors** (for example: `Breaths`, `All FX`, `Dialogue Bus`, `Reverb Bus`, `Room Tone`).
- **Markers and regions encode progress and context** (proofing location, character references, tails checks).
- **Item color is a workflow state flag** (orange/green/red semantics and exclusion logic).
- **Idempotent setup scripts are preferred** for track/sends infrastructure.
- **Undo-safe workflow habits** appear common (many scripts use structured action blocks and constrained edits).

## Practical script families in this repo

### 1) Recording / punch / ripple control
Representative scripts:
- `Ripple Insert Start.lua`
- `Ripple Insert End.lua`
- `Ripple Punch-In.lua`
- `Smart Punch and Roll.eel`
- `Smart Ripple Insert Punch and Roll.eel`
- `Multicast Ripple Punch In.lua`
- `Multicast TIghten Tail before Punch.lua`

**Inferred intent:** minimize friction while punching pickups, preserving timing continuity and reducing manual transport/edit-state setup.

### 2) Breath pipeline
Representative scripts:
- `Breath Detection Advanced.lua`
- `Breath Reduction.lua`
- `Breath Reduction (Single Item).lua`
- `Start or Recheck Breath.lua`
- `Check Next Breath.lua`
- `Mark Breath.lua`
- `Rename Track to Breaths.lua`

**Inferred intent:** iterative detect → review → mark → reduce loop, typically around a dedicated breaths track.

### 3) Click pipeline
Representative scripts:
- `Click Detection.lua`
- `Start or Recheck Click.lua`
- `Check Next Click.lua`
- `Click Double-Checker.lua`
- `Click Double-Checker (Click Found).lua`
- `Click Reduction (Mid-Dialogue).lua`
- `Click Reduction (Silence).lua`

**Inferred intent:** two-pass click QC with fast navigation and branch-specific fix strategies.

### 4) Takes, comping, and color-state helpers
Representative scripts:
- `Turn All Multitake Items Red.lua`
- `Toggle Item Colours.lua`
- `FInd Next Multitake Item.lua`
- `Colour Best Takes Based On Files Remaining.lua`
- `Extract Best Takes from Tracks 1&2 to Tracks 3&4.lua`
- `Re-Order Audition Takes.lua`

**Inferred intent:** use color + structure to accelerate comp decisions and navigation.

### 5) Track routing / FX topology
Representative scripts:
- `Build Character FX Tracks and Sends.lua`
- `Reset Character FX Tracks and Sends.lua`
- `Simultaneous Speaker FX Baking.lua`
- `Disable ReaGate.lua`
- `Reduce Reagate Threshold.lua`

**Inferred intent:** maintain predictable routing template and quickly apply/adjust processing per character context.

### 6) Source/build/import/export operations
Representative scripts:
- `Build_and_Update_from_Sources.lua`
- `Game Build_and_Update_from_Sources.lua`
- `Re-Import Rendered Files.lua`
- `Bulk Convert Streamlit to Pozotron Pickups.lua`
- `Bulk Import Pozotron Pickups.lua`

**Inferred intent:** synchronize DAW timeline with external assets/QC tools and reduce repetitive ingest/export work.

### 7) QC, proofing, regions, and business/reporting
Representative scripts:
- `Play-Pause when Proofing.lua`
- `Check for Empty Tracks in 15-Minute Checkpoint.lua`
- `Validate Items on Correct Tracks.lua`
- `Chapter Region Maker.eel`
- `Line Region Maker.eel`
- `Character Take Report.lua`
- `Pay Calculator.lua`

**Inferred intent:** formalize milestone checks and preserve operational visibility for long-form narration projects.

## Behavioral profile (how to best assist you going forward)

To match your workflow, automation should generally:

- Prefer **single-purpose scripts** that can be chained in custom actions.
- Respect **track-name and marker-name contracts** instead of relying only on index positions.
- Preserve edit-state safety: capture/restore ripple, selection, cursor, and transport state where possible.
- Support **recheck loops** instead of one-shot destructive passes.
- Expose user-tunable constants (thresholds, margins, target tracks) near the top of scripts.
- Keep scripts deterministic and robust for very large session timelines.

## Codification status

Completed in this repository:

1. `CONVENTIONS.md` now documents canonical track names, color meanings, and marker vocabulary.
2. `workflow_profile.json` now provides a machine-readable profile for validating script compatibility.

Still recommended:

3. Add shared helper functions (state save/restore, track lookup by name, marker lookup) to reduce duplicated logic.
4. Add script header standardization (`@description`, `@version`, assumptions, side effects).
5. Add a small smoke-test checklist for high-risk scripts (ripple/punch/import) before release.
