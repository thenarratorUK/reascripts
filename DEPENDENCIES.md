# Dependencies and Setup Notes

## External Requirements
- Many scripts in this repo expect REAPER 7.
- Several scripts require the SWS/S&M extension, especially those using `BR_*`, `NF_*`, `SNM_*`, or project-startup actions.

## Companion Script Dependencies

### Chapter Region Maker.eel
Depends on these companion scripts being installed and available as actions:
- `Close Gaps in Room Tone.lua`
- `Copy Automation from First Item in Solo or Child Tracks to Later Items.lua`
- `Reset Character FX Tracks and Sends.lua`

Also requires SWS for `BR_SetItemEdges`.

### Create Voice Reference Placeholders.lua
Optional workflow dependency:
- `Close Gaps in Room Tone.lua`

The script is configured to call that companion action when `RUN_ROOMTONE_CLOSE_GAPS = true`.

### Ripple Punch-In.lua
Depends on:
- `Ripple Insert Start.lua`
- `Ripple Insert End.lua`

### Smart Ripple Insert Punch and Roll.eel
Depends on:
- `Ripple Insert Start.lua`
- `Ripple Insert End.lua`

Also uses SWS `SNM_GetDoubleConfigVar` / `SNM_SetDoubleConfigVar` for preroll handling.

### Multicast Ripple Punch In.lua
Depends on:
- `Ripple Insert Start.lua`
- `Ripple Insert End.lua`
- `Multicast TIghten Tail before Punch.lua`

In some flows it also calls:
- `Reset Character FX Tracks and Sends.lua`

Also uses SWS preroll helpers when available.

### Multicast Ripple Punch In (Sends Version).lua
Depends on:
- `Ripple Insert Start.lua`
- `Ripple Insert End.lua`
- `Multicast TIghten Tail before Punch.lua`

### Index Track GUIDs.lua
Intended to be used as an SWS project startup action.

## Important Note About Action IDs
Several workflow scripts call companion scripts via `reaper.NamedCommandLookup("_RS...")` using action IDs from the author's setup.

If those lookups fail on your system:
1. Install the companion scripts from this repo.
2. Open the dependent script.
3. Update the `_RS...` IDs in its config section to match your local REAPER action IDs.

## Folder and Workflow Assumptions
These scripts are public, but some still assume a narration-oriented project layout:
- `ADR Script Import.lua` expects `../ADR/Import.csv` relative to the current project.
- `Build_and_Update_from_Sources.lua` expects a `../Sources` folder and a single CSV there.
- `Bulk Import Pozotron Pickups.lua` expects a `Pozotron` folder inside the project directory.
- `Pay Calculator.lua` expects a `../Sources` CSV layout.
- `Re-Import Rendered Files.lua` expects a `Breaths` track, a `00 Opening Credits` region, and a `Renders` folder.
- A number of cleanup/QC scripts assume track names such as `Room Tone`, `Breaths`, `Clicks`, and `Renders`.
