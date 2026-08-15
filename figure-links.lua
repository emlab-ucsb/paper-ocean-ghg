-- Inlines every figure and data table the prose links to, for the review build
-- of inventories_comparison.md.
--
-- The manuscript cites its evidence as plain links - [name.png](figures/name.png)
-- and [name.csv](data/.../name.csv) - so the source stays readable and the paths
-- stay checkable. A reviewer reading the HTML should not have to open each one,
-- so this filter appends the image or the rendered table beneath the paragraph
-- that cites it. The inline link is kept, not replaced: the sentence still names
-- the file it is pointing at.
--
-- Numbering is by first citation across the document, figures and tables counted
-- separately. Something cited again in a later paragraph is re-inserted there
-- and marked "(shown again)", so every paragraph carries everything it refers to
-- and a reviewer never has to scroll back. Within a single paragraph a repeated
-- citation is drawn once.
--
-- Which CSVs get inlined: those under data/, which the prose cites as evidence
-- the way it cites a figure. The comparison tables under tables/ are left as
-- links - the prose calls them "Supplementary Table 1/2/3", they belong to the
-- SI rather than to this argument, and each is eight columns of paragraph-length
-- text that would swamp the page at the four to five points where it is cited.
-- Widen INLINE_CSV_DIR to "" to inline every linked CSV instead.
--
-- Rebuild the review HTML with:
--
--   quarto pandoc inventories_comparison.md \
--     --standalone --embed-resources --toc --citeproc \
--     --lua-filter figure-links.lua \
--     --metadata title="Systematic comparison of our methods — review draft" \
--     --metadata subtitle="Generated review copy: figures inlined, citations linked to the reference list" \
--     -o inventories_comparison_review.html
--
-- (`quarto pandoc` is used because pandoc is not on PATH here; plain `pandoc`
-- works the same way.)

local INLINE_CSV_DIR = "data/"

local figure_number, table_number = {}, {}
local figure_count, table_count = 0, 0

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function is_png(target)
  return target:sub(-4):lower() == ".png"
end

local function is_inlined_csv(target)
  return target:sub(-4):lower() == ".csv"
    and target:sub(1, #INLINE_CSV_DIR) == INLINE_CSV_DIR
end

-- Words and spaces rather than one Str, so pandoc can wrap the caption the same
-- way it wraps prose.
local function to_inlines(text)
  local result = {}
  for word in text:gmatch("%S+") do
    if #result > 0 then
      result[#result + 1] = pandoc.Space()
    end
    result[#result + 1] = pandoc.Str(word)
  end
  return result
end

-- A real CSV reader rather than a split on commas: these files quote any field
-- containing one, e.g. "GFW (AIS, any registry)".
local function parse_csv(text)
  local rows, row, field, quoted = {}, {}, {}, false
  local i = 1

  local function end_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end

  local function end_row()
    end_field()
    rows[#rows + 1] = row
    row = {}
  end

  while i <= #text do
    local c = text:sub(i, i)
    if quoted then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          quoted = false
        end
      else
        field[#field + 1] = c
      end
    elseif c == '"' then
      quoted = true
    elseif c == "," then
      end_field()
    elseif c == "\n" then
      end_row()
    elseif c ~= "\r" then
      field[#field + 1] = c
    end
    i = i + 1
  end

  if #field > 0 or #row > 0 then
    end_row()
  end
  return rows
end

-- Rendered by handing pandoc a pipe table to read, which is far less code than
-- assembling a Table node cell by cell and gives the same AST.
local function csv_to_table(path, label)
  local handle = io.open(path, "r")
  if handle == nil then
    io.stderr:write("figure-links.lua: cannot read " .. path .. "\n")
    return nil
  end
  local rows = parse_csv(handle:read("a"))
  handle:close()

  if #rows == 0 then
    return nil
  end

  local width = 0
  for _, r in ipairs(rows) do
    width = math.max(width, #r)
  end

  local function render_row(r)
    local cells = {}
    for column = 1, width do
      local cell = r[column] or ""
      -- Escape what pipe-table syntax would otherwise consume.
      cells[column] = cell:gsub("|", "\\|"):gsub("%s+", " ")
    end
    return "| " .. table.concat(cells, " | ") .. " |"
  end

  local lines = { render_row(rows[1]) }
  local rule = {}
  for column = 1, width do
    rule[column] = "---"
  end
  lines[#lines + 1] = "| " .. table.concat(rule, " | ") .. " |"
  for index = 2, #rows do
    lines[#lines + 1] = render_row(rows[index])
  end

  local parsed = pandoc.read(table.concat(lines, "\n"), "markdown").blocks
  if #parsed == 0 or parsed[1].t ~= "Table" then
    io.stderr:write("figure-links.lua: could not parse " .. path .. "\n")
    return nil
  end

  local tbl = parsed[1]
  tbl.caption = { long = pandoc.Blocks({ pandoc.Plain(to_inlines(label)) }) }
  return tbl
end

function Para(el)
  local targets, seen_here = {}, {}

  pandoc.walk_block(el, {
    Link = function(link)
      local target = link.target
      if (is_png(target) or is_inlined_csv(target)) and not seen_here[target] then
        seen_here[target] = true
        targets[#targets + 1] = target
      end
    end,
  })

  if #targets == 0 then
    return nil
  end

  local blocks = { el }

  for _, target in ipairs(targets) do
    if is_png(target) then
      local label
      if figure_number[target] then
        label = string.format(
          "Figure %d (shown again) — %s",
          figure_number[target],
          basename(target)
        )
      else
        figure_count = figure_count + 1
        figure_number[target] = figure_count
        label = string.format("Figure %d — %s", figure_count, basename(target))
      end

      -- Built as an explicit Figure rather than left to the implicit-figure
      -- rule: pandoc only promotes a lone captioned image to a figure in the
      -- reader, so a Para a filter creates here would come out as a bare <img>
      -- inside a <p>.
      local image = pandoc.Image(
        to_inlines(label),
        target,
        "",
        pandoc.Attr("", {}, { role = "img", ["aria-label"] = label })
      )
      blocks[#blocks + 1] = pandoc.Figure(
        pandoc.Plain({ image }),
        { long = { pandoc.Plain(to_inlines(label)) } }
      )
    else
      local label
      if table_number[target] then
        label = string.format(
          "Table %d (shown again) — %s",
          table_number[target],
          basename(target)
        )
      else
        table_count = table_count + 1
        table_number[target] = table_count
        label = string.format("Table %d — %s", table_count, basename(target))
      end

      local tbl = csv_to_table(target, label)
      if tbl ~= nil then
        blocks[#blocks + 1] = tbl
      end
    end
  end

  return blocks
end
