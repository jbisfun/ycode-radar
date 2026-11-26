-- Line-anchored reports in ycode: open reports in a panel (click one to jump to its
-- line), "radar: report" to file the editor selection with a note.
-- Reports are cpull issues anchored to a line of code, filed in the repo they
-- point at; everything goes through the `radar` CLI, which files them through
-- cpull's API (the cpull job has to be running).
--
-- The panel follows the active editor: the reports on its file head the list, the
-- one under the cursor highlighted, and "radar: next report" / "radar: previous
-- report" step through them (then on to the next file), like next/previous
-- diagnostic. A report whose line moved is found again by its text. Hover a report
-- to close it or open its cpull issue page in the browser.

local REFRESH_SECONDS = 15
-- how often the panel reads the active editor's file and cursor line
local CURSOR_SECONDS = 1
local S = { reports = nil, error = nil, message = nil, root = nil, cursor = nil }

local function walk_up(dir)
    while dir and dir ~= "" do
        local f = io.open(dir .. "/pullfile.plist")
        if f then f:close(); return dir end
        local parent = dir:match("^(.*)/[^/]+$")
        if not parent or parent == dir then return nil end
        dir = parent
    end
end

-- The pull workspace: $PULL_ROOT, else the nearest pullfile.plist above an open folder.
local function find_root()
    local env = os.getenv("PULL_ROOT")
    if env and env ~= "" then return env end
    local ok, folders = pcall(ycode.workspace_folders)
    for _, folder in ipairs(ok and folders or {}) do
        local root = walk_up(folder)
        if root then return root end
    end
    return walk_up(os.getenv("PWD"))
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- `radar ARGS`; `with_errors` folds stderr into the output (not for --json).
local function report_cmd(args, callback, with_errors)
    local argv = {}
    for i, a in ipairs(args) do argv[i] = q(a) end
    local cmd = "cd " .. q(S.root) .. " && PULL_ROOT=" .. q(S.root) .. " radar " .. table.concat(argv, " ")
    ycode.spawn(cmd .. (with_errors and " 2>&1" or ""), callback)
end

-- The repo and repo-relative file of a workspace-relative path: the repo is the deepest
-- directory above it holding a `.git`, since pullfile repos can be nested
-- (fossify-ios/calculator-ios).
local function repo_of(rel)
    local dir = rel:match("^(.*)/[^/]+$")
    while dir and dir ~= "" do
        local f = io.open(S.root .. "/" .. dir .. "/.git")
        if f then f:close(); return dir, rel:sub(#dir + 2) end
        dir = dir:match("^(.*)/[^/]+$")
    end
end

-- reports are known by a cpull issue id; its first 8 characters are unique enough
local function short(r) return (r.id or ""):sub(1, 8) end

local function strip_nulls(t)
    for k, v in pairs(t) do
        if type(v) == "userdata" then t[k] = nil
        elseif type(v) == "table" then strip_nulls(v) end
    end
    return t
end

local function refresh()
    S.root = S.root or find_root()
    if not S.root then return end
    S.last_refresh = os.time()
    report_cmd({ "list", "--json" }, function(ok, out)
        if not ok then S.error = out:gsub("%s+$", ""); return end
        local okj, data = pcall(ycode.json_decode, out)
        if okj and type(data) == "table" then
            S.reports, S.error = strip_nulls(data), nil
        else
            S.error = "radar list: bad json"
        end
    end)
end

local function close_report(r)
    report_cmd({ "close", r.id }, function(ok, out)
        S.message = ok and ("closed " .. short(r)) or out:gsub("%s+$", "")
        refresh()
    end, true)
end

-- The cpull web UI's base URL, from the address the workspace server wrote.
local function web_base()
    local addr
    local f = io.open(S.root .. "/.pull/cpull/serve.addr")
    if f then addr = (f:read("a") or ""):match("^%s*(.-)%s*$"); f:close() end
    if not addr or addr == "" then addr = os.getenv("CPULL_ADDR") or "127.0.0.1:8080" end
    return "http://" .. addr
end

local function open_in_browser(r)
    if not r.url then S.message = short(r) .. " has no web page"; return end
    local url = web_base() .. r.url
    ycode.spawn("setsid -f xdg-open " .. q(url) .. " >/dev/null 2>&1", function(ok, out)
        S.message = ok and ("opened " .. url) or ("xdg-open failed: " .. out)
    end)
end

local function abs_path(r) return S.root .. "/" .. r.repo .. "/" .. r.file end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- Where report `r` points now: its line while that still has the filed text, else the
-- nearest line with that text (the code moved), else the filed line. `lines` is the
-- file's lines when the caller already read them.
local function locate(r, lines)
    if not r.line_text then return r.line end
    if not lines then
        lines = {}
        local f = io.open(abs_path(r))
        if not f then return r.line end
        for l in f:lines() do lines[#lines + 1] = l end
        f:close()
    end
    local want = trim(r.line_text)
    if lines[r.line] and trim(lines[r.line]) == want then return r.line end
    for d = 1, #lines do
        for _, n in ipairs({ r.line - d, r.line + d }) do
            if lines[n] and trim(lines[n]) == want then return n end
        end
        if r.line - d < 1 and r.line + d > #lines then break end
    end
    return r.line
end

local function goto_report(r)
    local line = locate(r)
    if line ~= r.line then S.message = short(r) .. " moved: line " .. r.line .. " is now " .. line end
    ycode.open(abs_path(r), line)
end

local function report_row(r, opts)
    opts = opts or {}
    local summary = r.note or r.quote or r.line_text or ""
    local line = opts.line or r.line
    return { "list_item", (opts.short and "" or (r.file .. ":")) .. line .. (opts.short and ("  " .. (r.title or "")) or ""),
        detail = not opts.short and summary:gsub("%s+", " ") or nil,
        selected = opts.selected or nil,
        tooltip = short(r) .. "  " .. (r.title or "") .. "\n" .. (r.line_text or ""):gsub("^%s+", ""),
        start = { "icon", name = "warning", color = "warning" },
        end_ = { "text", short(r), size = "small", color = "muted" },
        end_hover = { "row",
            { "icon_button", icon = "public", tooltip = "Open " .. short(r) .. " in the browser",
              on_click = function() open_in_browser(r) end },
            { "icon_button", icon = "check", tooltip = "Close " .. short(r),
              on_click = function() close_report(r) end } },
        on_click = function()
            if opts.line then ycode.open(abs_path(r), opts.line) else goto_report(r) end
        end }
end

-- The active editor's file and cursor line, read at most every CURSOR_SECONDS.
local function track_cursor()
    local now = os.time()
    if S.cursor_pending or now - (S.cursor_at or 0) < CURSOR_SECONDS then return end
    S.cursor_pending, S.cursor_at = true, now
    local ok = pcall(ycode.selection, function(sel)
        S.cursor_pending = false
        if sel then S.cursor = { path = sel.path, line = sel.line } end
    end)
    if not ok then S.cursor_pending = false end
end

-- The open reports on the active editor's file, each with the line it points at now,
-- in line order (and the file's workspace-relative name).
local function reports_here()
    local c = S.cursor
    if not c or not S.reports then return {} end
    local here, lines = {}, nil
    for _, r in ipairs(S.reports) do
        if abs_path(r) == c.path then
            if not lines then
                lines = {}
                local f = io.open(c.path)
                if f then for l in f:lines() do lines[#lines + 1] = l end; f:close() end
            end
            here[#here + 1] = { r = r, line = locate(r, lines) }
        end
    end
    table.sort(here, function(a, b) return a.line < b.line end)
    return here
end

local function report_selection() end -- defined below

local function render(w)
    S.root = S.root or find_root()
    if not S.root then
        return { "empty", "no pullfile.plist in the open folders; open a pull workspace or set PULL_ROOT" }
    end
    if os.time() - (S.last_refresh or 0) >= REFRESH_SECONDS then refresh() end
    track_cursor()

    local reports = S.reports or {}
    local panel = { "panel", id = "radar-reports",
        header = { title = "Reports", context = S.reports and (#reports .. " open") or nil, actions = {
            { "icon_button", icon = "plus", tooltip = "Report the selection (radar: report)",
              on_click = function() report_selection() end },
            { "icon_button", icon = "rotate_cw", tooltip = "Refresh", on_click = function() refresh() end } } },
        footer = S.message or S.root,
    }
    if S.error then
        panel[#panel + 1] = { "empty", S.error, color = "error" }
        return panel
    end
    if not S.reports then
        panel[#panel + 1] = { "empty", "loading…" }
        return panel
    end
    if #reports == 0 then
        panel[#panel + 1] = { "empty", "No open reports. Select code and run radar: report.",
            action = { "button", "Report selection", icon = "plus", on_click = function() report_selection() end } }
        return panel
    end

    local here = reports_here()
    if #here > 0 then
        local name = S.cursor.path:match("([^/]+)$")
        local section = { "section", "In " .. name }
        for _, h in ipairs(here) do
            section[#section + 1] = report_row(h.r, { short = true, line = h.line,
                selected = h.line == S.cursor.line })
        end
        panel[#panel + 1] = section
    end

    local by_repo, repos = {}, {}
    for _, r in ipairs(reports) do
        if not by_repo[r.repo] then by_repo[r.repo] = {}; repos[#repos + 1] = r.repo end
        table.insert(by_repo[r.repo], r)
    end
    table.sort(repos)
    for _, repo in ipairs(repos) do
        local rows = by_repo[repo]
        table.sort(rows, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.line < b.line
        end)
        local section = { "section", repo }
        for _, r in ipairs(rows) do section[#section + 1] = report_row(r) end
        panel[#panel + 1] = section
    end
    return panel
end

-- (repo, file, line) order, the panel's.
local function before(ra, fa, la, rb, fb, lb)
    if ra ~= rb then return ra < rb end
    if fa ~= fb then return fa < fb end
    return la < lb
end

-- Jump to the next (dir = 1) or previous (-1) report from the cursor: within the
-- active file first, then on to the neighbouring files, wrapping around.
local function step(dir)
    S.root = S.root or find_root()
    if not S.root or not S.reports then S.message = "no reports loaded"; return end
    ycode.selection(function(sel)
        if #S.reports == 0 then S.message = "no open reports"; return end
        if sel then S.cursor = { path = sel.path, line = sel.line } end
        -- the cursor as (repo, file, line), its repo the longest report repo above it
        local rel = sel and sel.path:sub(1, #S.root + 1) == S.root .. "/" and sel.path:sub(#S.root + 2) or ""
        local crepo, cfile = "", ""
        for _, r in ipairs(S.reports) do
            if rel:sub(1, #r.repo + 1) == r.repo .. "/" and #r.repo > #crepo then
                crepo, cfile = r.repo, rel:sub(#r.repo + 2)
            end
        end
        local cline = sel and sel.line or 0
        local here = {}
        for _, h in ipairs(reports_here()) do here[h.r.id] = h.line end
        local items = {}
        for _, r in ipairs(S.reports) do items[#items + 1] = { r = r, line = here[r.id] or r.line } end
        table.sort(items, function(x, y) return before(x.r.repo, x.r.file, x.line, y.r.repo, y.r.file, y.line) end)
        local pick
        if dir == 1 then
            for _, it in ipairs(items) do
                if before(crepo, cfile, cline, it.r.repo, it.r.file, it.line) then pick = it; break end
            end
            pick = pick or items[1]
        else
            for i = #items, 1, -1 do
                local it = items[i]
                if before(it.r.repo, it.r.file, it.line, crepo, cfile, cline) then pick = it; break end
            end
            pick = pick or items[#items]
        end
        local line = here[pick.r.id] or locate(pick.r)
        S.message = short(pick.r) .. "  " .. (pick.r.title or "")
        ycode.open(abs_path(pick.r), line)
    end)
end

-- The popup: where the report points, the selected text, and a note.
local function open_report_window(target)
    local function file(w)
        local note = (w.text("note") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local args = { target.repo, target.file, tostring(target.line), "--source", "ycode" }
        if note ~= "" then args[#args + 1] = "--note"; args[#args + 1] = note end
        if target.quote then args[#args + 1] = "--quote"; args[#args + 1] = target.quote end
        -- `w` only lives for this callback; the result comes back through state.
        local state = w.state
        state.busy, state.error = true, nil
        report_cmd(args, function(ok, out)
            state.busy = false
            if ok then
                S.message = "filed " .. out:gsub("%s+$", "")
                state.done = true
                refresh()
            else
                state.error = out:gsub("%s+$", "")
            end
        end, true)
    end
    local preview = target.quote or target.line_text or ""
    if #preview > 400 then preview = preview:sub(1, 400) .. "…" end
    gpui.open_window{
        title = "Report " .. target.repo .. "/" .. target.file .. ":" .. target.line,
        width = 520, height = 300, kind = "floating",
        focus = "note",
        poll_ms = 250,
        state = {},
        on_key = function(w, ev)
            if ev.key == "escape" then w.close(); return true end
            if ev.ctrl and ev.key == "enter" then file(w); return true end
        end,
        render = function(w)
            if w.state.done then w.close(); return { "col" } end
            return { "panel", scroll = false,
                header = { title = target.repo .. "/" .. target.file,
                           context = "line " .. target.line .. (target.end_line ~= target.line
                               and ("–" .. target.end_line) or "") },
                footer = w.state.error or "ctrl-enter files the report, escape cancels",
                color = w.state.error and "error" or nil,
                { "col", grow = true, gap = "sm", p = "md",
                    { "col", p = "sm", bg = "editor", border = true, rounded = true,
                        { "text", preview, mono = true, size = "small" } },
                    { "input", id = "note", multiline = true, grow = true,
                      placeholder = "What's wrong here? (optional)" },
                    { "row", gap = "xs", justify = "end",
                        { "button", "Cancel", on_click = function(w) w.close() end },
                        { "button", "File report", style = "filled", disabled = w.state.busy == true,
                          on_click = file } } },
            }
        end,
    }
end

report_selection = function()
    S.root = S.root or find_root()
    if not S.root then S.message = "no pull workspace"; return end
    ycode.selection(function(sel)
        if not sel then S.message = "no file editor is active"; return end
        local prefix = S.root .. "/"
        if sel.path:sub(1, #prefix) ~= prefix then
            S.message = sel.path .. " is not in " .. S.root
            return
        end
        local repo, file = repo_of(sel.path:sub(#prefix + 1))
        if not repo then S.message = sel.path .. " is not in a repo"; return end
        local line_text
        local f = io.open(sel.path)
        if f then
            local n = 0
            for l in f:lines() do n = n + 1; if n == sel.line then line_text = l; break end end
            f:close()
        end
        -- The quote is only worth keeping when it's narrower than the line.
        local text = sel.text or ""
        local quote = text:match("%S") and text or nil
        if quote and line_text and quote:gsub("^%s+", ""):gsub("%s+$", "")
                == line_text:gsub("^%s+", ""):gsub("%s+$", "") then
            quote = nil
        end
        open_report_window({ repo = repo, file = file, line = sel.line, end_line = sel.end_line,
            quote = quote, line_text = line_text })
    end)
end

%ctor
    gpui.register_panel{
        id = "radar", title = "Reports", icon = "warning", position = "right", size = 360,
        poll_ms = 1000,
        state = {},
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "empty", "ycode-radar: " .. tostring(tree), color = "error" }
        end,
    }
end

%hook radar
%new - Panel
    ycode.dispatch("ycode::TogglePanel", { id = "radar" })
end

%new - Report
    report_selection()
end

%new - NextReport
    step(1)
end

%new - PreviousReport
    step(-1)
end
%end
