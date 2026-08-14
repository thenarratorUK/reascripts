# thenarratorUK ReaScripts

Public REAPER scripts for audiobook, dialogue, and pickup workflows.

## Included JSFX

- **Adaptive EQ with Reference Matching** — a mono narration EQ that learns a
  fixed tonal baseline, continually corrects changes away from that baseline,
  and can optionally match one of 14 embedded reference profiles. This is a
  beta release intended for testing.

## Install with ReaPack
1. Open ReaPack in REAPER.
2. Import the repository index from:
   `https://raw.githubusercontent.com/thenarratorUK/reascripts/main/index.xml`
3. Synchronize packages.

Open **Extensions > ReaPack > Browse packages**, search for **Adaptive
Reference Matcher**, select it, choose **Install**, and apply the transaction.
The effect will then be available in REAPER's FX browser as **JS: Adaptive
Reference Matcher**.

## Notes
- Many scripts expect REAPER 7 and the SWS/S&M extension.
- Some scripts depend on companion scripts from this same repository or on specific folder and track conventions.
- See `DEPENDENCIES.md` for setup notes before using the more workflow-specific actions.
- See `SCRIPT_INDEX.md` for a quick summary of what each script does.

## Scope
This public repo intentionally excludes some highly personal or one-off workflow scripts, while keeping the broader narration toolkit and the scripts that are useful to teach or reuse.
