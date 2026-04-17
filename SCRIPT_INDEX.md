# Script Index

Index of the scripts currently published in this repository. The ReaPack `index.xml` is the install manifest; this file is the plain-language reference.

Total public scripts indexed: 78

## Breath workflow

| Script | What it does | Notes |
| --- | --- | --- |
| `Breath Detection Advanced.lua` | Detects likely breaths on the Breaths track using silence removal, gate splitting, ZCR, RMS, peak, edge, and source-track checks. | Current breath detector. |
| `Breath Reduction.lua` | Processes all breath markers, finds overlapping source audio, splits it, and reduces the matching pre-FX volume segment. | Batch reducer. |
| `Breath Reduction (Single Item).lua` | Reduces the source audio for the breath marker at the edit cursor and auditions the result. | Manual reducer. |
| `Breath Comparison.lua` | Stores before and after snapshots of the Breaths track and reports which breath items were removed. | QC helper. |
| `Start or Recheck Breath.lua` | Auditions the next breath marker from the current cursor or saved breath checkpoint. | Navigation helper. |
| `Check Next Breath.lua` | Accepts the current breath check, removes its marker, updates the checkpoint, and auditions the next marker. | Navigation helper. |
| `Mark Breath.lua` | Removes the current breath marker and creates a Check Breath region for manual follow-up. | Manual review marker. |
| `Rename Track to Breaths.lua` | Renames the selected track to Breaths. | Setup helper. |
| `Copy to Breaths, Clicks and Renders Tracks.lua` | Copies items from the selected source track to Breaths, Clicks, and Renders workflow tracks, then removes the source track. | Track-name workflow helper. |

## Click workflow

| Script | What it does | Notes |
| --- | --- | --- |
| `Click Detection.lua` | Detects click candidates, filters them, colours/cleans the result, and prepares Clicks/Renders workflow items. | Main click detector. |
| `Start or Recheck Click.lua` | Auditions the next click marker from the current cursor or saved click checkpoint. | Navigation helper. |
| `Check Next Click.lua` | Accepts the current click check, removes its marker, updates the checkpoint, and auditions the next marker. | Navigation helper. |
| `Click Reduction (Silence).lua` | Splits the source audio around a click marker and reduces that segment with pre-FX volume automation. | For clicks handled by attenuation. |
| `Click Reduction (Mid-Dialogue).lua` | Splits a padded source segment around a click marker, applies RX De-click as take FX, and creates a Check Click region. | Requires the configured RX plugin and preset. |
| `Click Double-Checker.lua` | Moves the tails-check marker forward and plays the end of the current item. | Tail QC helper. |
| `Click Double-Checker (Click Found).lua` | Marks a confirmed tail click, moves the tails-check marker forward, and plays the next tail area. | Tail QC helper. |

## Punch, ripple, and pause editing

| Script | What it does | Notes |
| --- | --- | --- |
| `Ripple Insert Start.lua` | Starts a ripple-insert recording pass by splitting at the cursor, creating space, and recording. | Used by punch helpers. |
| `Ripple Insert End.lua` | Ends a ripple-insert recording pass and closes the inserted gap. | Used by punch helpers. |
| `Ripple Punch-In.lua` | Runs Ripple Insert Start when stopped and Ripple Insert End when playing or recording. | Depends on custom action IDs. |
| `Smart Punch and Roll.eel` | Punch-and-roll helper with silence scanning and preroll handling. | EEL version. |
| `Smart Ripple Insert Punch and Roll.eel` | Silence-aware ripple-insert punch-and-roll helper using the Ripple Insert Start and End actions. | Depends on companion actions. |
| `Multicast Ripple Punch In.lua` | Placeholder-aware multicast punch-in workflow with next-track selection and automation handling. | Workflow-specific. |
| `Multicast Ripple Punch In (Sends Version).lua` | Send-based variant of the multicast punch-in workflow. | Workflow-specific. |
| `Multicast TIghten Tail before Punch.lua` | Trims excess silence from the previous item before a multicast punch. | Used by multicast punch-in. |
| `Pause Start.lua` | Finds and stores the practical start point of a pause from the selected time range. | Part one of two-script pause trimming. |
| `Pause End.lua` | Finds the pause end, removes the pause with ripple editing, and clears stored pause points. | Part two of two-script pause trimming. |
| `Pause Trimmer.eel` | Analyses a pause and removes excess length in one script. | Current single-script pause trimmer. |
| `Toggle Pre-Roll and Inverse FX.lua` | Toggles record preroll and inversely bypasses FX on Track 1 and tracks named Live. | Track-1 and Live-track workflow helper. |

## Regions, placeholders, and project structure

| Script | What it does | Notes |
| --- | --- | --- |
| `Chapter Region Maker.eel` | Trims chapter edges, creates or opens the chapter region, and runs related room-tone and automation safety actions. | Core chapter workflow. |
| `Line Region Maker.eel` | Trims selected line items and creates regions using item or filename identifiers. | Line-region workflow. |
| `Create Retail Sample Region.lua` | Creates a region from the time selection and names it 99 Retail_Sample. | Retail sample helper. |
| `Create Voice Reference Placeholders.lua` | Creates voice-reference placeholder items from region or marker text. | Placeholder workflow. |
| `Check Voice Reference.lua` | Previews voice-reference material by matching placeholder text to regions or markers. | Placeholder workflow. |
| `Regions from Additional Cast Items.lua` | Creates parent-named regions from Additional Cast child-track items. | Additional-cast workflow. |
| `Regions from SubProjects.lua` | Creates top-level regions for subproject items on Track 1. | Fixed Track 1 assumption. |
| `SubRegions from SubProjects.lua` | Creates subregions from selected subproject tabs. | Interactive subproject helper. |
| `Subregions from Subprojects (Headless).lua` | Extracts subregions from subprojects without relying on the tab-based workflow. | Headless subproject helper. |
| `Index Track GUIDs.lua` | Stores important track GUIDs in project extstate for template-based sessions. | Intended as an SWS startup action. |

## Import, export, and external workflow integration

| Script | What it does | Notes |
| --- | --- | --- |
| `ADR Script Import.lua` | Imports ADR CSV data and creates named project regions. | Uses the ADR folder convention. |
| `Build_and_Update_from_Sources.lua` | Builds or updates a project timeline from a single Sources CSV, inserting placeholders or takes. | Uses the Sources folder convention. |
| `Bulk Import Pozotron Pickups.lua` | Imports Pozotron-style pickup CSV marker files and aligns them to matching regions. | Pickup import workflow. |
| `Re-Import Rendered Files.lua` | Reimports rendered files and rebuilds the Breaths/Renders workflow state. | Uses Renders and Breaths conventions. |
| `Export Command IDs.lua` | Exports REAPER Main-section action command IDs to CSV. | Dependency documentation helper. |
| `Pay Calculator.lua` | Calculates pay from selected-track take filenames and matching Sources CSV data. | Business workflow helper. |
| `Change_Project_Start_Time.lua` | Sets the project start-time offset from the edit cursor. | Uses SWS/S&M. |

## FX, routing, and automation

| Script | What it does | Notes |
| --- | --- | --- |
| `Build Character FX Tracks and Sends.lua` | Builds or repairs Character FX tracks and sends from the All FX, Dialogue Bus, and Reverb Bus layout. | Routing setup helper. |
| `Reset Character FX Tracks and Sends.lua` | Resets send-mute automation for the Character FX routing layout. | Requires SWS/BR envelope actions. |
| `Serialise FX Chains.lua` | Splits FX chains into one-plugin-per-track managed chains. | All FX / Dialogue Bus workflow. |
| `Simultaneous Speaker FX Baking.lua` | Copies All FX track FX to selected item takes and glues each item. | Take-FX baking helper. |
| `Disable ReaGate.lua` | Selects or creates ReaGate Dry automation on the selected track and inserts reset points. | ReaGate envelope helper. |
| `Reduce Reagate Threshold.lua` | Creates a four-point ReaGate threshold dip over the time selection. | ReaGate envelope helper. |
| `Nudge Peak Volume Down with Automation.lua` | Finds the peak in the time selection and shapes a pre-FX volume dip around it. | Envelope helper. |
| `Copy Automation from First Item in Solo or Child Tracks to Later Items.lua` | Uses the first region or first item area as an automation template for later items on solo or child tracks. | Broad folder-aware automation copier. |
| `Copy Automation from First Item to All Subsequent Items In Track.lua` | Uses one selected child-track item as the automation template for later items on that same child track. | Manual selected-item template variant. |
| `Copy all Track Items to End for FX Learning.lua` | Copies selected tracks items sequentially after the project end for FX learning. | FX-learning helper. |
| `List TakeFX on Track.lua` | Lists take FX used by items on the first selected track. | Diagnostic helper. |
| `Increase Peak Display.lua` | Increases REAPER peak display gain. | Uses SWS/S&M. |
| `Decrease Peak Display.lua` | Decreases REAPER peak display gain. | Uses SWS/S&M. |
| `Reset Peak Display to 0.lua` | Resets REAPER peak display gain to 0 dB. | Uses SWS/S&M. |
| `Toggle Live Mute.lua` | Toggles mute on tracks named Live. | Named-track helper. |

## Takes, item colours, and comping

| Script | What it does | Notes |
| --- | --- | --- |
| `Character Take Report.lua` | Reports per-track item counts, coloured/rejected items, and active take usage. | Reporting helper. |
| `Colour Best Takes Based On Files Remaining.lua` | Colours matching regions or items based on rendered MP3 filenames remaining in the Renders folder. | Renders-folder workflow. |
| `Extract Best Takes from Tracks 1&2 to Tracks 3&4.lua` | Extracts and assembles green best-take regions from Tracks 1 and 2 onto Tracks 3 and 4. | Fixed track-position comping helper. |
| `Re-Order Audition Takes.lua` | Reorders adjacent audition takes into alternating order, ripples the original block, and creates a region. | Audition comping helper. |
| `FInd Next Multitake Item.lua` | Moves the edit cursor to the next coloured non-orange multitake item. | Navigation helper. |
| `Turn All Multitake Items Red.lua` | Colours all multitake items on selected tracks red. | Item-state helper. |
| `Toggle Item Colours.lua` | Cycles selected item colours through the workflow colour states. | Item-state helper. |
| `Move from Parent to Child based on tag.lua` | Reads speaker tags from item notes, creates matching child tracks, and moves items to those tracks. | Folder workflow helper. |
| `Move Items to Named Track.lua` | Moves selected items to a typed destination track, optionally creating it. | General item-routing helper. |
| `Copy to All Tracks.lua` | Duplicates all items from Track 1 onto all other tracks. | Fixed Track 1 utility. |

## QC and validation

| Script | What it does | Notes |
| --- | --- | --- |
| `Check for Empty Tracks in 15-Minute Checkpoint.lua` | Checks regions for empty tracks and reports items with take or item FX. | Checkpoint QC helper. |
| `Check Gaps Between Items.lua` | Finds long pauses or gaps between items on non-excluded tracks. | Gap QC helper. |
| `Duplicate Empty Item Checker.lua` | Reports duplicate item notes and their item locations. | Project hygiene helper. |
| `Mic Comparison Test Prep.lua` | Prepares mic comparison items by normalising loudness, compensating gain, and flagging peaks. | Uses SWS/NF loudness functions. |
| `Play-Pause when Proofing.lua` | Toggles playback and moves the Proofed up to here marker when pausing. | Proofing helper. |
| `Validate Items on Correct Tracks.lua` | Checks bracket-derived character names against track names and can move mismatched empty items. | Character-track validation helper. |
| `Split Interview Audio.lua` | Splits and mutes Track 1 wherever Track 2 has items. | Fixed Track 1/2 interview helper. |

## General utilities

| Script | What it does | Notes |
| --- | --- | --- |
| `Close Gaps in Room Tone.lua` | Closes gaps on the Room Tone track or the selected fallback track. | Room Tone helper. |
