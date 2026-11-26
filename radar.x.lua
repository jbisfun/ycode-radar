-- radar in ycode: open reports in a panel (click one to jump to its line), and
-- "radar: report" to file the editor selection with a note.
-- Reports are cpull issues anchored to a line of code, filed in the repo they
-- point at; everything goes through `pull cpull report` (pull pins its identity
-- into the repos and runs `cpull report`).

-- Listing reads every repo's cpull/events, so poll gently; filing and closing
-- refresh right away.
local REFRESH_SECONDS = 15
local S = { reports = nil, error = nil, message = nil, root = nil }

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

local function radar(args, callback)
    local argv = {}
    for i, a in ipairs(args) do argv[i] = q(a) end
    local cmd = "cd " .. q(S.root) .. " && PULL_ROOT=" .. q(S.root) .. " pull cpull report " .. table.concat(argv, " ")
    ycode.spawn(cmd, callback)
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
    radar({ "list", "--json" }, function(ok, out)
        if not ok then S.error = out:gsub("%s+$", ""); return end
        local okj, data = pcall(ycode.json_decode, out)
        if okj and type(data) == "table" then
            S.reports, S.error = strip_nulls(data), nil
        else
            S.error = "cpull report list: bad json"
        end
    end)
end

local function close_report(r)
    radar({ "close", r.id }, function(ok, out)
        S.message = ok and ("closed " .. short(r)) or out:gsub("%s+$", "")
        refresh()
    end)
end

local function report_row(r)
    local summary = r.note or r.quote or r.line_text or ""
    return { "list_item", r.file .. ":" .. r.line, detail = summary:gsub("%s+", " "),
        tooltip = short(r) .. "  " .. (r.title or "") .. "\n" .. (r.line_text or ""):gsub("^%s+", ""),
        start = { "icon", name = "warning", color = "warning" },
        end_ = { "text", short(r), size = "small", color = "muted" },
        end_hover = { "icon_button", icon = "check", tooltip = "Close " .. short(r),
            on_click = function() close_report(r) end },
        on_click = function()
            ycode.open(S.root .. "/" .. r.repo .. "/" .. r.file, r.line)
        end }
end

local function report_selection() end -- defined below

local function render(w)
    S.root = S.root or find_root()
    if not S.root then
        return { "empty", "no pullfile.plist in the open folders; open a pull workspace or set PULL_ROOT" }
    end
    if os.time() - (S.last_refresh or 0) >= REFRESH_SECONDS then refresh() end

    local reports = S.reports or {}
    local panel = { "panel", id = "radar-reports",
        header = { title = "Radar", context = S.reports and (#reports .. " open") or nil, actions = {
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
        radar(args, function(ok, out)
            state.busy = false
            if ok then
                S.message = "filed " .. out:gsub("%s+$", "")
                state.done = true
                refresh()
            else
                state.error = out:gsub("%s+$", "")
            end
        end)
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
        local repo, file = sel.path:sub(#prefix + 1):match("^([^/]+)/(.+)$")
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
        id = "radar", title = "Radar", icon = "warning", position = "right", size = 360,
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
%end
