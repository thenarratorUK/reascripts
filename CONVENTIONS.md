# ReaScripts Workflow Conventions

This file codifies practical conventions inferred from the repository scripts so new scripts can safely integrate with existing sessions.

## 1) Canonical track names
Scripts should prefer name-based lookup before any index fallback.

### Core routing / utility tracks
- `All FX`
- `Dialogue Bus`
- `Reverb Bus`
- `Room Tone`

### Cleanup and review tracks
- `Breaths`
- `Clicks` (inferred from click workflow scripts)
- `Renders` (inferred from copy/re-import workflows)

## 2) Color-state conventions (items)
Item color appears to be used as workflow state.

- **No custom color**: untreated/default state
- **Orange**: intermediate state requiring attention/review
- **Green**: approved/best/selected state
- **Red**: multitake attention flag (explicitly used by multitake helper)

When adding scripts:
- Avoid silently overwriting colors unless the script purpose is state labeling.
- Document exact color semantics in script headers.

## 3) Marker and region vocabulary
Markers and regions are used for navigation, proofing, and handoff.

Common semantics:
- `Proofed up to here`: progress marker while proofing.
- `Click` markers: click detection/check outcomes.
- Character/line/chapter regions: structure and reporting boundaries.
- Placeholder-driven voice reference names: map placeholders to region lookup.

When adding scripts:
- Reuse existing marker names where possible to preserve interoperability.
- If introducing a new marker keyword, define it in script `@about` and here.

## 4) Script design conventions
- **Single responsibility**: one focused operation per script.
- **Composable behavior**: safe to chain into custom actions.
- **State safety**: preserve/restore ripple mode, cursor, selection, and transport state when practical.
- **Idempotent setup**: track/send/template builders should be rerunnable without duplicating structures.
- **Top-loaded configuration**: thresholds/margins/target names near top of file.

## 5) Validation checklist for new scripts
Before adopting a new script in production:
1. Confirm it behaves correctly with named-track lookup.
2. Confirm it does not break color-state conventions.
3. Confirm it preserves key edit/transport state (or explicitly documents side effects).
4. Confirm reruns are safe (or side effects are intentional and documented).
5. Confirm marker/region names match existing vocabulary.

## 6) Source of truth relationship
- Human-readable conventions: `CONVENTIONS.md` (this file)
- Machine-readable profile: `workflow_profile.json`

When updating one, update the other in the same change where possible.
