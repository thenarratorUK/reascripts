-- @description Find Text in Item Notes
-- @version 1.0
-- @author David Winter
-- @about
--   Searches every non-empty item note in project-timeline order.
--
--   Notes are compared in overlapping groups of three: notes 1-3, then 2-4,
--   then 3-5, and so on. After the best three-note group is found, the script
--   narrows the result to the strongest contiguous one-, two-, or three-item
--   subset, selects those items, and reveals them in the arrange view.
--
--   Matching ignores case, punctuation, apostrophes, line breaks, and repeated
--   spaces. It also tolerates small spelling differences and incomplete quotes,
--   so a query can match a shorter run such as "exactly what she wanted".

local PROJECT = 0
local WINDOW_SIZE = 3
local MINIMUM_MATCH_SCORE = 0.34
local FUZZY_WORD_THRESHOLD = 0.74
local MINIMUM_VIEW_SECONDS = 6.0
local MAX_RESULT_TEXT_LENGTH = 1200
local TITLE = "Find Text in Item Notes"

local function trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

local function normalize(text)
  text = tostring(text or ""):lower()
  text = text:gsub("’", "'")
  text = text:gsub("‘", "'")
  text = text:gsub("“", '"')
  text = text:gsub("”", '"')
  text = text:gsub("—", " ")
  text = text:gsub("–", " ")
  text = text:gsub("…", " ")
  text = text:gsub("'", "")
  text = text:gsub("[%p%c]", " ")
  text = text:gsub("%s+", " ")
  return trim(text)
end

local function tokenize(normalized_text)
  local words = {}
  for word in (normalized_text or ""):gmatch("%S+") do
    words[#words + 1] = word
  end
  return words
end

local function levenshtein(left, right)
  if left == right then return 0 end
  local left_length = #left
  local right_length = #right
  if left_length == 0 then return right_length end
  if right_length == 0 then return left_length end

  local previous = {}
  for column = 0, right_length do previous[column] = column end

  for row = 1, left_length do
    local current = {[0] = row}
    local left_character = left:sub(row, row)
    for column = 1, right_length do
      local cost = left_character == right:sub(column, column) and 0 or 1
      current[column] = math.min(
        current[column - 1] + 1,
        previous[column] + 1,
        previous[column - 1] + cost
      )
    end
    previous = current
  end

  return previous[right_length]
end

local function word_similarity(left, right)
  if left == right then return 1.0 end

  local longest = math.max(#left, #right)
  local shortest = math.min(#left, #right)
  if shortest < 4 then return 0.0 end

  local similarity = 1.0 - (levenshtein(left, right) / longest)
  if similarity >= FUZZY_WORD_THRESHOLD then return similarity end
  return 0.0
end

local function calculate_match(query_normalized, query_words, candidate_text)
  local candidate_normalized = normalize(candidate_text)
  local candidate_words = tokenize(candidate_normalized)
  local query_count = #query_words
  local candidate_count = #candidate_words

  if query_count == 0 or candidate_count == 0 then
    return {score = 0, ordered_weight = 0, density = 0, candidate_count = candidate_count}
  end

  if candidate_normalized:find(query_normalized, 1, true) then
    local density = math.min(1.0, query_count / candidate_count)
    return {
      score = 1.0,
      ordered_weight = query_count,
      density = density,
      candidate_count = candidate_count,
    }
  end

  -- Longest approximately matching contiguous word run.
  local previous_run_weight = {}
  local previous_run_length = {}
  local best_run_weight = 0
  local best_run_length = 0

  for query_index = 1, query_count do
    local current_run_weight = {}
    local current_run_length = {}
    for candidate_index = 1, candidate_count do
      local similarity = word_similarity(query_words[query_index], candidate_words[candidate_index])
      if similarity >= FUZZY_WORD_THRESHOLD then
        current_run_weight[candidate_index] = (previous_run_weight[candidate_index - 1] or 0) + similarity
        current_run_length[candidate_index] = (previous_run_length[candidate_index - 1] or 0) + 1
        if current_run_weight[candidate_index] > best_run_weight then
          best_run_weight = current_run_weight[candidate_index]
          best_run_length = current_run_length[candidate_index]
        end
      else
        current_run_weight[candidate_index] = 0
        current_run_length[candidate_index] = 0
      end
    end
    previous_run_weight = current_run_weight
    previous_run_length = current_run_length
  end

  -- Weighted longest common subsequence. This rewards query words that remain
  -- in the right order even when the candidate has extra or missing words.
  local previous_ordered = {}
  for candidate_index = 0, candidate_count do previous_ordered[candidate_index] = 0 end

  for query_index = 1, query_count do
    local current_ordered = {[0] = 0}
    for candidate_index = 1, candidate_count do
      local best = math.max(
        previous_ordered[candidate_index] or 0,
        current_ordered[candidate_index - 1] or 0
      )
      local similarity = word_similarity(query_words[query_index], candidate_words[candidate_index])
      if similarity >= FUZZY_WORD_THRESHOLD then
        best = math.max(best, (previous_ordered[candidate_index - 1] or 0) + similarity)
      end
      current_ordered[candidate_index] = best
    end
    previous_ordered = current_ordered
  end

  local ordered_weight = previous_ordered[candidate_count] or 0
  local contiguous_coverage = best_run_weight / query_count
  local ordered_coverage = ordered_weight / query_count
  local score = math.min(1.0, (0.72 * contiguous_coverage) + (0.28 * ordered_coverage))
  local density = math.min(1.0, ordered_weight / candidate_count)

  return {
    score = score,
    ordered_weight = ordered_weight,
    density = density,
    candidate_count = candidate_count,
    best_run_length = best_run_length,
  }
end

local function collect_note_items()
  local records = {}

  for item_index = 0, reaper.CountMediaItems(PROJECT) - 1 do
    local item = reaper.GetMediaItem(PROJECT, item_index)
    local ok, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    if ok and normalize(notes) ~= "" then
      local track = reaper.GetMediaItem_Track(item)
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      records[#records + 1] = {
        item = item,
        track = track,
        notes = notes,
        position = position,
        end_time = position + math.max(0, length),
        track_number = track and reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or math.huge,
        lane = reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or -1,
        original_index = item_index,
      }
    end
  end

  table.sort(records, function(left, right)
    if left.position ~= right.position then return left.position < right.position end
    if left.track_number ~= right.track_number then return left.track_number < right.track_number end
    if left.lane ~= right.lane then return left.lane < right.lane end
    if left.end_time ~= right.end_time then return left.end_time < right.end_time end
    return left.original_index < right.original_index
  end)

  return records
end

local function concatenate_records(records, first_index, last_index)
  local parts = {}
  for index = first_index, last_index do
    parts[#parts + 1] = records[index].notes
  end
  return table.concat(parts, " ")
end

local function find_best_window(records, query_normalized, query_words)
  local window_length = math.min(WINDOW_SIZE, #records)
  local final_start = #records - window_length + 1
  local best = nil

  for first_index = 1, final_start do
    local last_index = first_index + window_length - 1
    local text = concatenate_records(records, first_index, last_index)
    local match = calculate_match(query_normalized, query_words, text)

    if not best or match.score > best.match.score + 1e-12 then
      best = {
        first_index = first_index,
        last_index = last_index,
        text = text,
        match = match,
      }
    end
  end

  return best
end

local function find_best_subset(records, window, query_normalized, query_words)
  local best = nil

  for first_index = window.first_index, window.last_index do
    for last_index = first_index, window.last_index do
      local text = concatenate_records(records, first_index, last_index)
      local match = calculate_match(query_normalized, query_words, text)
      local selection_score = (0.82 * match.score) + (0.18 * match.density)
      local item_count = last_index - first_index + 1

      if not best or
         selection_score > best.selection_score + 1e-12 or
         (math.abs(selection_score - best.selection_score) <= 1e-12 and item_count < best.item_count) then
        best = {
          first_index = first_index,
          last_index = last_index,
          text = text,
          match = match,
          selection_score = selection_score,
          item_count = item_count,
        }
      end
    end
  end

  return best
end

local function focus_records(records, first_index, last_index)
  local start_time = math.huge
  local end_time = -math.huge
  local selected_tracks = {}

  reaper.PreventUIRefresh(1)
  reaper.SelectAllMediaItems(PROJECT, false)
  reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks

  for index = first_index, last_index do
    local record = records[index]
    reaper.SetMediaItemSelected(record.item, true)
    if record.track and not selected_tracks[record.track] then
      reaper.SetTrackSelected(record.track, true)
      selected_tracks[record.track] = true
    end
    start_time = math.min(start_time, record.position)
    end_time = math.max(end_time, record.end_time)
  end

  local centre = (start_time + end_time) / 2
  local view_duration = math.max(MINIMUM_VIEW_SECONDS, (end_time - start_time) * 3)
  local view_start = math.max(0, centre - (view_duration / 2))
  local view_end = view_start + view_duration

  reaper.GetSet_ArrangeView2(PROJECT, true, 0, 0, view_start, view_end)
  reaper.SetEditCurPos(start_time, true, false)
  reaper.Main_OnCommand(40913, 0) -- Track: Vertical scroll selected tracks into view
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

local function shorten(text, maximum_length)
  text = trim((text or ""):gsub("%s+", " "))
  if #text <= maximum_length then return text end
  return text:sub(1, maximum_length - 3) .. "..."
end

local function main()
  local accepted, query = reaper.GetUserInputs(
    TITLE,
    1,
    "Words or quotation to find:,extrawidth=420",
    ""
  )
  if not accepted then return end

  query = trim(query)
  local query_normalized = normalize(query)
  local query_words = tokenize(query_normalized)
  if #query_words == 0 then
    reaper.ShowMessageBox("Enter at least one word to find.", TITLE, 0)
    return
  end

  local records = collect_note_items()
  if #records == 0 then
    reaper.ShowMessageBox("This project contains no non-empty item notes.", TITLE, 0)
    return
  end

  local best_window = find_best_window(records, query_normalized, query_words)
  if not best_window or best_window.match.score < MINIMUM_MATCH_SCORE then
    local closest = best_window and shorten(best_window.text, MAX_RESULT_TEXT_LENGTH) or ""
    local score = best_window and math.floor(best_window.match.score * 100 + 0.5) or 0
    reaper.ShowMessageBox(
      string.format("No close match was found.\n\nClosest three-note window: %d%%\n\n%s", score, closest),
      TITLE,
      0
    )
    return
  end

  local best_subset = find_best_subset(records, best_window, query_normalized, query_words)
  focus_records(records, best_subset.first_index, best_subset.last_index)

  local percentage = math.floor(best_window.match.score * 100 + 0.5)
  local result_text = shorten(best_subset.text, MAX_RESULT_TEXT_LENGTH)
  reaper.ShowMessageBox(
    string.format(
      "Best match: %d%%\nSelected %d item%s.\n\n%s",
      percentage,
      best_subset.item_count,
      best_subset.item_count == 1 and "" or "s",
      result_text
    ),
    TITLE,
    0
  )
end

main()
