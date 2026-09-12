# thenarratorUK ReaScripts

Public REAPER scripts for audiobook, dialogue, and pickup workflows.

## Included extensions

- **Remote Recorder - Participant** — records the participant's selected
  microphone input with REAPER input monitoring off, keeps a local safety
  recording and transfers it directly to the engineer. Supports Apple Silicon
  Mac, Intel Mac and Windows x64.
- **Remote Recorder - Engineer** — creates pairing codes and receives the
  verified recording directly into the current REAPER project's configured
  media folder. Engineer access is individually password-controlled and can be
  revoked by the owner. Currently supports Apple Silicon Mac.

The [Remote Recorder guide](Extensions/Remote%20Recorder/README.md) contains the
complete setup and session instructions for both roles. The extension also
opens this guide from its **Open Guide** button.

## Included JSFX

- **Adaptive Phase Rotator** — a mono narration phase rotator with learned,
  adaptive, and learned-plus-adaptive modes. The package includes the companion
  time-selection learning action and requires SWS/S&M for that action. This is
  an early beta release intended for testing.
- **Adapterer** — a mono narration EQ that learns a
  fixed tonal baseline, continually corrects changes away from that baseline,
  and can optionally match one of 14 embedded reference profiles. Adaptivity
  scales the live consistency correction, while Auto Gain uses a fixed
  integrated-loudness trim derived during Learn. This is a beta release
  intended for testing.
- **AllAGater** — a linked-stereo dialogue gate with a continuously variable
  curved closed-state transfer between Threshold and Target. It shares
  Expanderer's finite RMS detector, signed hysteresis, linear-amplitude timing
  and configurable Pre-open, while Curve controls how strongly the closed path
  bends toward Target. This is an early beta release intended for testing.
- **TriLeveler Pro** — a long-form voice leveller with separately limited
  fast, medium and slow correction, optional lookahead, speech/room-tone
  learning, a room-tone threshold learner, and an ambience-preserving path.
  This is an early beta release intended for testing.
- **Compressorer** — two or three gentle, independently
  detected compressor stages in series, with linked threshold/knee spacing,
  staggered timing, per-stage lookahead and an optional manual stage mode.
  This is an early beta release intended for testing.
- **Expanderer** — a linked-stereo dialogue gate whose attenuation is greatest
  near threshold, progressively returns to unity toward a lower target, and
  leaves still-quieter room tone unchanged. It includes finite RMS detection,
  signed hysteresis, linear-amplitude gate timing and configurable Pre-open.
  This is an early beta release intended for testing.

## Install with ReaPack
1. Open ReaPack in REAPER.
2. Import the repository index from:
   `https://raw.githubusercontent.com/thenarratorUK/reascripts/main/index.xml`
3. Synchronize packages.

Open **Extensions > ReaPack > Browse packages**, search for the package you
want, select it, choose **Install**, and apply the transaction. Restart REAPER
after installing either Remote Recorder package, then open it from
**Extensions > Remote Recorder**. The JSFX packages will be available in the FX
browser with their corresponding **JS:** names.

## Notes
- Many scripts expect REAPER 7 and the SWS/S&M extension.
- Some scripts depend on companion scripts from this same repository or on specific folder and track conventions.
- See `DEPENDENCIES.md` for setup notes before using the more workflow-specific actions.
- See `SCRIPT_INDEX.md` for a quick summary of what each script does.

## Scope
This public repo intentionally excludes some highly personal or one-off workflow scripts, while keeping the broader narration toolkit and the scripts that are useful to teach or reuse.
