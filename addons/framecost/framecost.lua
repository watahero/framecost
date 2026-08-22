--[[
* framecost - per-frame resource monitor + per-addon cost profiler for Ashita v4
*
* Live view (like the LibraPlates performance monitor, but for the whole frame):
*   - FPS, frame time (avg / peak / 99th percentile) from a high-resolution timer
*   - Where each frame goes: game render, addon draw, present/vsync + game logic
*   - Event rates per second: packets in/out, chat text, commands
*   - Spike log: frames that blew past the threshold and what happened in them
*
* Attribution mode (/framecost profile):
*   Ashita runs every addon in its own Lua state, so no addon can time another
*   addon's handlers directly. Instead framecost measures each addon's real cost
*   by elimination: unload it, sample uncapped frame time, reload it, and compare
*   against a rolling baseline. Results are shown in a sortable table and written
*   to config\addons\framecost\profile-<stamp>.txt.
*
* Load this addon LAST in your script so the "Addon draw" bucket contains every
* other addon's present/endscene handlers.
--]]

addon.name    = 'framecost';
addon.author  = 'watahero';
addon.version = '1.0.1';
addon.desc    = 'Shows what is using time each frame and measures per-addon frame cost.';
addon.link    = 'https://github.com/watahero/framecost';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
local ffi      = require('ffi');

----------------------------------------------------------------------------------------------------
-- High resolution clock (QueryPerformanceCounter). Falls back to os.clock if FFI is unavailable.
----------------------------------------------------------------------------------------------------
local clock = { now = os.clock };
do
    local ok = pcall(function()
        pcall(ffi.cdef, [[
            int QueryPerformanceCounter(int64_t* lpPerformanceCount);
            int QueryPerformanceFrequency(int64_t* lpFrequency);
        ]]);
        local freq = ffi.new('int64_t[1]');
        ffi.C.QueryPerformanceFrequency(freq);
        local scale = 1.0 / tonumber(freq[0]);
        local buf = ffi.new('int64_t[1]');
        clock.now = function()
            ffi.C.QueryPerformanceCounter(buf);
            return tonumber(buf[0]) * scale;
        end
        clock.now();
    end);
    if (not ok) then
        clock.now = os.clock;
    end
end

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------
local default_settings = T{
    visible        = true,
    compact        = false,
    show_spikes    = true,
    show_graph     = true,
    spike_ms       = 33.0,   -- a frame slower than this is logged as a spike
    history        = 240,    -- frames kept for the graph
    window_frames  = 600,    -- frames used for avg / p99
    profile = T{
        sample_seconds  = 10,
        settle_seconds  = 2.5,
        rebaseline_every = 4,
        include_plugins = false,
        drift_pct       = 15,     -- a re-baseline this far from the previous one marks the group unstable
        abort_on_drift  = false,  -- stop the run instead of just flagging it
        exclude = T{ 'framecost', 'hideconsole', 'fps', 'move', 'nolock', 'timestamp' },
        exclude_plugins = T{ 'addons', 'thirdparty', 'cexidats', 'render', 'screenshot', 'hardwaremouse' },
    },
};

local cfg = settings.load(default_settings);

settings.register('settings', 'settings_update', function(s)
    if (s ~= nil) then
        cfg = s;
    end
    settings.save();
end);

----------------------------------------------------------------------------------------------------
-- Frame state
----------------------------------------------------------------------------------------------------
local state = {
    tBegin = 0, tEnd = 0, tPresent = 0, tPrevPresent = 0,
    selfMs = 0,
    frameCount = 0,
    -- per-frame event counters (reset every present)
    ev = { pin = 0, pinBytes = 0, pout = 0, poutBytes = 0, text = 0, cmd = 0, ids = {} },
    -- rolling per-second rates
    rate = { pin = 0, pinBytes = 0, pout = 0, poutBytes = 0, text = 0, cmd = 0, frames = 0 },
    rateAcc = { pin = 0, pinBytes = 0, pout = 0, poutBytes = 0, text = 0, cmd = 0, frames = 0 },
    rateStart = 0,
    -- ring buffers
    hist = {},      -- { total, scene, post, gap }
    histPos = 0,
    win = {},       -- total ms, for avg / p99
    winPos = 0,
    -- smoothed
    emaTotal = 0, emaScene = 0, emaPost = 0, emaGap = 0, emaSelf = 0,
    peak = 0, peakAt = 0,
    spikes = {},
    lastFps = 0,
};

local function Ms(seconds)
    return (tonumber(seconds) or 0) * 1000.0;
end

local function Ema(prev, value, alpha)
    if (prev == 0) then return value; end
    return prev + (value - prev) * alpha;
end

local function ResetStats()
    state.hist, state.histPos = {}, 0;
    state.win, state.winPos = {}, 0;
    state.emaTotal, state.emaScene, state.emaPost, state.emaGap, state.emaSelf = 0, 0, 0, 0, 0;
    state.peak, state.peakAt = 0, 0;
    state.spikes = {};
end

local statsCache = { at = 0, avg = 0, p99 = 0, max = 0 };

local function WindowStats()
    local n = #state.win;
    if (n == 0) then
        return 0, 0, 0;
    end
    if (state.frameCount - statsCache.at < 30) then
        return statsCache.avg, statsCache.p99, statsCache.max;
    end
    local sorted = {};
    local sum = 0;
    for i = 1, n do
        sorted[i] = state.win[i];
        sum = sum + state.win[i];
    end
    table.sort(sorted);
    local p99 = sorted[math.max(1, math.min(n, math.ceil(n * 0.99)))];
    local max = sorted[n];
    statsCache.at, statsCache.avg, statsCache.p99, statsCache.max = state.frameCount, sum / n, p99, max;
    return statsCache.avg, statsCache.p99, statsCache.max;
end

----------------------------------------------------------------------------------------------------
-- Profiler (elimination-based per-addon cost)
----------------------------------------------------------------------------------------------------
local profiler = {
    active = false,
    phase = 'idle',      -- idle | settle | sample
    phaseEnd = 0,
    queue = {},          -- { name, kind = 'addon'|'plugin' }
    index = 0,
    results = {},        -- { name, kind, ms, delta, baseline, stddev, fps }
    baseline = nil,      -- { ms, stddev, fps }
    baselines = {},
    sinceBaseline = 0,
    sampleSum = 0, sampleSq = 0, sampleN = 0, sampleStart = 0,
    pending = nil,       -- current target being measured, or 'baseline'
    savedDivisor = nil,
    status = '',
    report = nil,
    sortCol = 'delta',
    sortAsc = false,
    driftEvents = 0,
    lastDriftPct = 0,
};

local function Print(msg)
    print(chat.header(addon.name):append(chat.message(msg)));
end

local function PrintErr(msg)
    print(chat.header(addon.name):append(chat.error(msg)));
end

local function Queue(command)
    AshitaCore:GetChatManager():QueueCommand(1, command);
end

local function FpsDivisorPointer()
    local pointer = ashita.memory.find('FFXiMain.dll', 0, '81EC000100003BC174218B0D', 0, 0);
    if (pointer == 0) then
        return nil;
    end
    pointer = ashita.memory.read_uint32(pointer + 0x0C);
    pointer = ashita.memory.read_uint32(pointer);
    return pointer + 0x30;
end

local function ReadDivisor()
    local ok, value = pcall(function()
        local p = FpsDivisorPointer();
        if (p == nil) then return nil; end
        return ashita.memory.read_uint32(p);
    end);
    if (ok) then return value; end
    return nil;
end

local function WriteDivisor(value)
    return pcall(function()
        local p = FpsDivisorPointer();
        if (p ~= nil) then
            ashita.memory.write_uint32(p, value);
        end
    end);
end

local function InstallPath()
    local path = '.';
    pcall(function() path = AshitaCore:GetInstallPath(); end);
    path = tostring(path);
    if (path:sub(-1) ~= '\\') then
        path = path .. '\\';
    end
    return path;
end

local function EnsureFolder(path)
    local exists = false;
    pcall(function() exists = ashita.fs.exists(path); end);
    if (exists) then return true; end
    return pcall(function()
        if (ashita.fs.create_dir ~= nil) then
            ashita.fs.create_dir(path);
        elseif (ashita.fs.create_directory ~= nil) then
            ashita.fs.create_directory(path);
        end
    end);
end

local function ReportFolder()
    local base = InstallPath();
    EnsureFolder(base .. 'config');
    EnsureFolder(base .. 'config\\addons');
    EnsureFolder(base .. 'config\\addons\\framecost');
    return base .. 'config\\addons\\framecost\\';
end

-- Parse /addon load and /load lines out of the boot script (following /include).
local function ParseScript(file, addons, plugins, seen, depth)
    seen = seen or {};
    depth = depth or 0;
    if (depth > 4 or seen[file:lower()]) then return; end
    seen[file:lower()] = true;

    local f = io.open(file, 'r');
    if (f == nil) then return; end
    for line in f:lines() do
        local text = line:gsub('#.*$', ''):gsub('^%s+', ''):gsub('%s+$', '');
        local a = text:match('^/addon%s+load%s+(%S+)');
        if (a ~= nil) then
            addons[#addons + 1] = a:lower();
        else
            local inc = text:match('^/include%s+(%S+)');
            if (inc ~= nil) then
                if (not inc:lower():match('%.txt$')) then inc = inc .. '.txt'; end
                ParseScript(InstallPath() .. 'scripts\\' .. inc, addons, plugins, seen, depth + 1);
            else
                local p = text:match('^/load%s+(%S+)');
                if (p ~= nil) then
                    plugins[#plugins + 1] = p:lower();
                end
            end
        end
    end
    f:close();
end

local function ListContains(list, value)
    for _, v in ipairs(list or {}) do
        if (tostring(v):lower() == value) then return true; end
    end
    return false;
end

local function BuildTargets(onlyList, includePlugins)
    local addons, plugins = {}, {};
    if (onlyList ~= nil) then
        for name in onlyList:gmatch('[^,%s]+') do
            addons[#addons + 1] = name:lower();
        end
    else
        ParseScript(InstallPath() .. 'scripts\\default.txt', addons, plugins);
    end

    local targets, seen = {}, {};
    for _, name in ipairs(addons) do
        if (not seen[name] and not ListContains(cfg.profile.exclude, name)) then
            seen[name] = true;
            targets[#targets + 1] = { name = name, kind = 'addon' };
        end
    end
    if (includePlugins) then
        for _, name in ipairs(plugins) do
            if (not seen['plugin:' .. name] and not ListContains(cfg.profile.exclude_plugins, name)) then
                seen['plugin:' .. name] = true;
                targets[#targets + 1] = { name = name, kind = 'plugin' };
            end
        end
    end
    return targets;
end

local function SampleReset()
    profiler.sampleSum, profiler.sampleSq, profiler.sampleN = 0, 0, 0;
    profiler.sampleStart = clock.now();
end

local function SampleResult()
    local n = profiler.sampleN;
    if (n < 2) then
        return { ms = 0, stddev = 0, fps = 0, n = n };
    end
    local mean = profiler.sampleSum / n;
    local var = math.max(0, profiler.sampleSq / n - mean * mean);
    local elapsed = clock.now() - profiler.sampleStart;
    return { ms = mean, stddev = math.sqrt(var), fps = (elapsed > 0) and (n / elapsed) or 0, n = n };
end

local function SetPhase(phase, seconds)
    profiler.phase = phase;
    profiler.phaseEnd = clock.now() + seconds;
end

local function ToggleTarget(target, load)
    if (target.kind == 'plugin') then
        Queue((load and '/load ' or '/unload ') .. target.name);
    else
        Queue((load and '/addon load ' or '/addon unload ') .. target.name);
    end
end

local function WriteProfileReport()
    local folder = ReportFolder();
    local stamp = os.date('%Y%m%d-%H%M%S');
    local path = folder .. 'profile-' .. stamp .. '.txt';
    local f = io.open(path, 'w');
    if (f == nil) then
        PrintErr('Could not write report to ' .. path);
        return nil;
    end

    local sorted = {};
    for i, r in ipairs(profiler.results) do sorted[i] = r; end
    table.sort(sorted, function(a, b) return a.delta > b.delta; end);

    f:write('framecost profile ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n');
    f:write(string.format('sample %ds, settle %.1fs, uncapped frame time\n', cfg.profile.sample_seconds, cfg.profile.settle_seconds));
    f:write('\nBaselines (everything loaded):\n');
    for i, b in ipairs(profiler.baselines) do
        f:write(string.format('  #%d  %.3f ms  (sd %.3f, %.1f fps, %d frames)\n', i, b.ms, b.stddev, b.fps, b.n));
    end
    local flagged = 0;
    for _, r in ipairs(sorted) do
        if (r.unstable) then flagged = flagged + 1; end
    end
    if (profiler.driftEvents > 0) then
        f:write(string.format('\n!! SCENE DRIFT: %d re-baseline(s) moved more than %d%%. %d of %d results are flagged "?" and should be ignored.\n',
            profiler.driftEvents, cfg.profile.drift_pct, flagged, #sorted));
    end
    f:write('\nPer-addon cost (baseline - without addon). Positive = addon costs that much per frame.\n');
    f:write(string.format('%-2s %-22s %-7s %10s %10s %10s %8s\n', '', 'name', 'kind', 'cost ms', 'without', 'baseline', 'sd'));
    for _, r in ipairs(sorted) do
        f:write(string.format('%-2s %-22s %-7s %10.3f %10.3f %10.3f %8.3f\n', r.unstable and '?' or '', r.name, r.kind, r.delta, r.ms, r.baseline, r.stddev));
    end
    f:write('\nNote: values inside ~2x the baseline sd are noise. "?" = scene changed around that sample. Measure standing still, camera fixed.\n');
    f:close();
    return path;
end

local function StopProfile(reason)
    if (not profiler.active) then return; end
    profiler.active = false;
    profiler.phase = 'idle';

    -- Make sure whatever we were measuring gets reloaded.
    if (profiler.pending ~= nil and profiler.pending ~= 'baseline') then
        ToggleTarget(profiler.pending, true);
    end
    profiler.pending = nil;

    if (profiler.savedDivisor ~= nil) then
        WriteDivisor(profiler.savedDivisor);
        profiler.savedDivisor = nil;
    end

    if (#profiler.results > 0) then
        profiler.report = WriteProfileReport();
    end
    profiler.status = reason or 'done';
    Print('Profile ' .. profiler.status .. (profiler.report and (' - report: ' .. profiler.report) or ''));
end

local function StartProfile(seconds, onlyList, includePlugins)
    if (profiler.active) then
        PrintErr('A profile is already running. Use /framecost profile stop.');
        return;
    end

    local targets = BuildTargets(onlyList, includePlugins);
    if (#targets == 0) then
        PrintErr('No addons to profile. Could not read scripts\\default.txt, or everything is excluded.');
        return;
    end

    cfg.profile.sample_seconds = math.max(3, tonumber(seconds) or cfg.profile.sample_seconds);
    settings.save();

    profiler.active = true;
    profiler.queue = targets;
    profiler.index = 0;
    profiler.results = {};
    profiler.baselines = {};
    profiler.baseline = nil;
    profiler.sinceBaseline = 0;
    profiler.report = nil;
    profiler.pending = 'baseline';
    profiler.driftEvents = 0;
    profiler.lastDriftPct = 0;

    profiler.savedDivisor = ReadDivisor();
    if (profiler.savedDivisor ~= nil) then
        WriteDivisor(0);
    else
        PrintErr('Could not find the FPS divisor; profiling with the current frame cap. Run /fps 0 first for valid numbers.');
    end

    local total = (#targets + 1 + math.floor(#targets / cfg.profile.rebaseline_every)) * (cfg.profile.sample_seconds + cfg.profile.settle_seconds * 2);
    Print(string.format('Profiling %d targets, ~%d seconds. Stand still, camera fixed, hands off.', #targets, math.floor(total)));
    profiler.status = 'baseline';
    cfg.visible = true;
    SetPhase('settle', cfg.profile.settle_seconds);
end

local function ProfilerFrame(frameSeconds)
    if (not profiler.active) then return; end
    local now = clock.now();

    if (profiler.phase == 'sample') then
        local ms = Ms(frameSeconds);
        profiler.sampleSum = profiler.sampleSum + ms;
        profiler.sampleSq = profiler.sampleSq + ms * ms;
        profiler.sampleN = profiler.sampleN + 1;
    end

    if (now < profiler.phaseEnd) then return; end

    if (profiler.phase == 'settle') then
        SampleReset();
        SetPhase('sample', cfg.profile.sample_seconds);
        return;
    end

    -- Sample finished: record it.
    local sample = SampleResult();
    if (profiler.pending == 'baseline') then
        profiler.baseline = sample;
        profiler.baselines[#profiler.baselines + 1] = sample;
        local k = #profiler.baselines;
        -- Re-score everything measured between the previous baseline and this one
        -- against the average of the two, so slow drift does not land on one addon.
        if (k >= 2) then
            local prev = profiler.baselines[k - 1].ms;
            local mixed = (prev + sample.ms) * 0.5;
            local driftPct = 100 * math.abs(sample.ms - prev) / math.max(0.001, math.min(prev, sample.ms));
            local unstable = driftPct > (tonumber(cfg.profile.drift_pct) or 15);
            profiler.lastDriftPct = driftPct;
            for _, r in ipairs(profiler.results) do
                if (r.baseIdx == k - 1) then
                    r.baseline = mixed;
                    r.delta = mixed - r.ms;
                    r.unstable = unstable;
                end
            end
            if (unstable) then
                profiler.driftEvents = profiler.driftEvents + 1;
                PrintErr(string.format('Scene drift: baseline moved %.1f -> %.1f ms (%.0f%%). Results from the last group are flagged unstable.', prev, sample.ms, driftPct));
                if (cfg.profile.abort_on_drift) then
                    profiler.pending = nil;
                    StopProfile('aborted: scene drift');
                    return;
                end
            end
        end
        profiler.sinceBaseline = 0;
    elseif (profiler.pending ~= nil) then
        local target = profiler.pending;
        local base = profiler.baseline or sample;
        profiler.results[#profiler.results + 1] = {
            name = target.name, kind = target.kind,
            ms = sample.ms, fps = sample.fps, stddev = sample.stddev,
            baseline = base.ms, delta = base.ms - sample.ms,
            baseIdx = #profiler.baselines,
        };
        ToggleTarget(target, true);
        profiler.sinceBaseline = profiler.sinceBaseline + 1;
    end
    profiler.pending = nil;

    -- Decide what to measure next.
    if (profiler.index >= #profiler.queue) then
        if (profiler.sinceBaseline > 0) then
            -- closing baseline so the last group is compared against fresh data
            profiler.pending = 'baseline';
            profiler.status = 'final baseline';
            SetPhase('settle', cfg.profile.settle_seconds);
            return;
        end
        StopProfile('complete');
        return;
    end

    if (profiler.sinceBaseline >= cfg.profile.rebaseline_every) then
        profiler.pending = 'baseline';
        profiler.status = 're-baseline';
        SetPhase('settle', cfg.profile.settle_seconds);
        return;
    end

    profiler.index = profiler.index + 1;
    local target = profiler.queue[profiler.index];
    profiler.pending = target;
    profiler.status = string.format('%d/%d %s', profiler.index, #profiler.queue, target.name);
    ToggleTarget(target, false);
    SetPhase('settle', cfg.profile.settle_seconds);
end

----------------------------------------------------------------------------------------------------
-- Frame capture
----------------------------------------------------------------------------------------------------
ashita.events.register('d3d_beginscene', 'framecost_beginscene', function()
    state.tBegin = clock.now();
end);

ashita.events.register('d3d_endscene', 'framecost_endscene', function()
    state.tEnd = clock.now();
end);

ashita.events.register('packet_in', 'framecost_packet_in', function(e)
    state.ev.pin = state.ev.pin + 1;
    state.ev.pinBytes = state.ev.pinBytes + (tonumber(e.size) or 0);
    if (#state.ev.ids < 12) then
        state.ev.ids[#state.ev.ids + 1] = string.format('0x%03X', e.id);
    end
end);

ashita.events.register('packet_out', 'framecost_packet_out', function(e)
    state.ev.pout = state.ev.pout + 1;
    state.ev.poutBytes = state.ev.poutBytes + (tonumber(e.size) or 0);
end);

ashita.events.register('text_in', 'framecost_text_in', function()
    state.ev.text = state.ev.text + 1;
end);

local function RecordFrame()
    local now = clock.now();
    state.tPresent = now;

    if (state.tPrevPresent == 0 or state.tBegin == 0 or state.tEnd == 0) then
        state.tPrevPresent = now;
        return nil;
    end

    local total = now - state.tPrevPresent;
    local scene = math.max(0, state.tEnd - state.tBegin);
    local post  = math.max(0, now - state.tEnd);
    local gap   = math.max(0, total - scene - post);
    state.tPrevPresent = now;
    state.frameCount = state.frameCount + 1;

    local totalMs = Ms(total);
    local alpha = 0.08;
    state.emaTotal = Ema(state.emaTotal, totalMs, alpha);
    state.emaScene = Ema(state.emaScene, Ms(scene), alpha);
    state.emaPost  = Ema(state.emaPost,  Ms(post),  alpha);
    state.emaGap   = Ema(state.emaGap,   Ms(gap),   alpha);
    state.emaSelf  = Ema(state.emaSelf,  state.selfMs, alpha);

    -- history ring
    local h = math.max(60, tonumber(cfg.history) or 240);
    state.histPos = (state.histPos % h) + 1;
    state.hist[state.histPos] = { totalMs, Ms(scene), Ms(post), Ms(gap) };

    local w = math.max(60, tonumber(cfg.window_frames) or 600);
    state.winPos = (state.winPos % w) + 1;
    state.win[state.winPos] = totalMs;

    if (totalMs > state.peak or (now - state.peakAt) > 10) then
        state.peak = totalMs;
        state.peakAt = now;
    end

    -- per-second rates
    local acc = state.rateAcc;
    acc.frames = acc.frames + 1;
    acc.pin = acc.pin + state.ev.pin;
    acc.pinBytes = acc.pinBytes + state.ev.pinBytes;
    acc.pout = acc.pout + state.ev.pout;
    acc.poutBytes = acc.poutBytes + state.ev.poutBytes;
    acc.text = acc.text + state.ev.text;
    acc.cmd = acc.cmd + state.ev.cmd;
    if (state.rateStart == 0) then state.rateStart = now; end
    local span = now - state.rateStart;
    if (span >= 1.0) then
        for k, v in pairs(acc) do
            state.rate[k] = v / span;
            acc[k] = 0;
        end
        state.lastFps = state.rate.frames;
        state.rateStart = now;
    end

    -- spikes
    if (totalMs >= (tonumber(cfg.spike_ms) or 33)) then
        local entry = {
            at = os.date('%H:%M:%S'),
            total = totalMs, scene = Ms(scene), post = Ms(post), gap = Ms(gap),
            pin = state.ev.pin, pout = state.ev.pout, text = state.ev.text,
            ids = table.concat(state.ev.ids, ' '),
        };
        table.insert(state.spikes, 1, entry);
        if (#state.spikes > 40) then
            table.remove(state.spikes);
        end
    end

    state.ev = { pin = 0, pinBytes = 0, pout = 0, poutBytes = 0, text = 0, cmd = 0, ids = {} };
    return total;
end

----------------------------------------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------------------------------------
local COLORS = {
    text   = { 0.92, 0.92, 0.90, 1.0 },
    dim    = { 0.62, 0.64, 0.66, 1.0 },
    title  = { 0.42, 0.91, 0.94, 1.0 },
    scene  = { 0.36, 0.62, 0.96, 1.0 },
    post   = { 0.98, 0.66, 0.30, 1.0 },
    gap    = { 0.48, 0.52, 0.58, 1.0 },
    self   = { 0.75, 0.75, 0.75, 1.0 },
    good   = { 0.56, 0.96, 0.70, 1.0 },
    warn   = { 1.0, 0.84, 0.30, 1.0 },
    bad    = { 1.0, 0.42, 0.32, 1.0 },
    gold   = { 1.0, 0.84, 0.30, 1.0 },
};

local UI_WIDTH = 500;

local function CostColor(ms)
    if (ms >= 16.0) then return COLORS.bad; end
    if (ms >= 8.0) then return COLORS.warn; end
    return COLORS.good;
end

local function DeltaColor(ms)
    if (ms >= 1.0) then return COLORS.bad; end
    if (ms >= 0.3) then return COLORS.warn; end
    if (ms >= 0.1) then return COLORS.text; end
    return COLORS.dim;
end

local function PushStyle()
    local pushed = 0;
    local function Push(id, color)
        if (id ~= nil) then
            imgui.PushStyleColor(id, color);
            pushed = pushed + 1;
        end
    end
    Push(_G.ImGuiCol_WindowBg,            { 0.075, 0.085, 0.105, 0.88 });
    Push(_G.ImGuiCol_TitleBg,             { 0.075, 0.085, 0.105, 0.92 });
    Push(_G.ImGuiCol_TitleBgActive,       { 0.10, 0.15, 0.16, 0.96 });
    Push(_G.ImGuiCol_TitleBgCollapsed,    { 0.075, 0.085, 0.105, 0.92 });
    Push(_G.ImGuiCol_Button,              { 0.16, 0.48, 0.50, 0.70 });
    Push(_G.ImGuiCol_ButtonHovered,       { 0.22, 0.62, 0.64, 0.85 });
    Push(_G.ImGuiCol_ButtonActive,        { 0.16, 0.48, 0.50, 0.70 });
    Push(_G.ImGuiCol_Header,              { 0.16, 0.48, 0.50, 0.35 });
    Push(_G.ImGuiCol_HeaderHovered,       { 0.22, 0.62, 0.64, 0.50 });
    Push(_G.ImGuiCol_HeaderActive,        { 0.22, 0.62, 0.64, 0.60 });
    Push(_G.ImGuiCol_ScrollbarGrab,       { 0.16, 0.48, 0.50, 0.65 });
    Push(_G.ImGuiCol_ScrollbarGrabHovered,{ 0.22, 0.62, 0.64, 0.82 });
    Push(_G.ImGuiCol_ScrollbarGrabActive, { 0.22, 0.62, 0.64, 0.82 });
    return pushed;
end

local function Tooltip(text)
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip(text);
    end
end

local function DrawStackedBar(width, height, parts)
    -- parts: { { fraction, color }, ... }
    local x, y = imgui.GetCursorScreenPos();
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ x, y }, { x + width, y + height }, imgui.GetColorU32({ 0.12, 0.13, 0.16, 1.0 }), 2);
    local cursor = x;
    for _, p in ipairs(parts) do
        local w = width * math.max(0, math.min(1, p[1]));
        if (w > 0.5) then
            dl:AddRectFilled({ cursor, y }, { cursor + w, y + height }, imgui.GetColorU32(p[2]), 0);
            cursor = cursor + w;
        end
    end
    imgui.Dummy({ width, height });
end

local function DrawGraph(width, height)
    local x, y = imgui.GetCursorScreenPos();
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ x, y }, { x + width, y + height }, imgui.GetColorU32({ 0.09, 0.10, 0.13, 1.0 }), 3);

    local h = math.max(60, tonumber(cfg.history) or 240);
    local count = #state.hist;
    if (count == 0) then
        imgui.Dummy({ width, height });
        return;
    end

    -- scale: at least 16.7ms*2 so 60fps frames sit in the lower half
    local scaleMs = 33.4;
    for i = 1, count do
        local v = state.hist[i][1];
        if (v > scaleMs) then scaleMs = v; end
    end
    scaleMs = math.min(scaleMs, 250);

    -- guide lines at 16.7 and 33.3 ms
    for _, guide in ipairs({ 16.7, 33.3 }) do
        if (guide < scaleMs) then
            local gy = y + height - (guide / scaleMs) * height;
            dl:AddRectFilled({ x, gy }, { x + width, gy + 1 }, imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.10 }), 0);
        end
    end

    local barW = width / h;
    local idx = state.histPos;
    for i = h, 1, -1 do
        local entry = state.hist[idx];
        if (entry ~= nil) then
            local bx = x + (i - 1) * barW;
            local base = y + height;
            local segs = { { entry[2], COLORS.scene }, { entry[3], COLORS.post }, { entry[4], COLORS.gap } };
            for _, s in ipairs(segs) do
                local sh = (s[1] / scaleMs) * height;
                if (sh > 0.3) then
                    dl:AddRectFilled({ bx, base - sh }, { bx + math.max(1, barW - 0.5), base }, imgui.GetColorU32(s[2]), 0);
                    base = base - sh;
                end
            end
        end
        idx = idx - 1;
        if (idx < 1) then idx = h; end
    end

    dl:AddText({ x + 4, y + 2 }, imgui.GetColorU32(COLORS.dim), string.format('%.0f ms', scaleMs));
    imgui.Dummy({ width, height });
end

----------------------------------------------------------------------------------------------------
-- UI sections
----------------------------------------------------------------------------------------------------
local function DrawHeader()
    local avg, p99, max = WindowStats();
    local fps = state.lastFps;
    imgui.TextColored(COLORS.title, string.format('%.1f fps', fps));
    imgui.SameLine();
    imgui.TextColored(CostColor(state.emaTotal), string.format('%.2f ms', state.emaTotal));
    imgui.SameLine();
    imgui.TextColored(COLORS.dim, string.format('avg %.2f  p99 %.2f  peak %.1f', avg, p99, state.peak));
    Tooltip('Frame time between successive Present calls.\navg / p99 over the last ' .. tostring(cfg.window_frames) .. ' frames, peak over the last 10s.');
end

local function DrawPhases()
    local total = math.max(0.001, state.emaTotal);
    DrawStackedBar(UI_WIDTH, 10, {
        { state.emaScene / total, COLORS.scene },
        { state.emaPost  / total, COLORS.post },
        { state.emaGap   / total, COLORS.gap },
    });

    local rows = {
        { 'Game render', state.emaScene, COLORS.scene,
          'BeginScene -> EndScene.\nThe client drawing the world, plus EndScene handlers of addons loaded before framecost.' },
        { 'Addon draw', state.emaPost, COLORS.post,
          'EndScene -> Present.\nAddons drawing their UI (present handlers) and any EndScene handlers of addons loaded after framecost.\nLoad framecost last so this bucket holds every other addon.' },
        { 'Present + logic', state.emaGap, COLORS.gap,
          'Present -> next BeginScene.\nGPU present / vsync wait / frame cap, then the client\'s game logic, packet processing and input.\nIf you are frame-capped this is mostly idle waiting.' },
        { 'framecost itself', state.emaSelf, COLORS.self,
          'Time spent inside this addon\'s own present handler (drawing this window).' },
    };
    for _, r in ipairs(rows) do
        imgui.TextColored(r[3], '  ');
        imgui.SameLine();
        imgui.TextColored(COLORS.text, string.format('%-17s', r[1]));
        imgui.SameLine();
        imgui.TextColored(r[3], string.format('%6.2f ms', r[2]));
        imgui.SameLine();
        imgui.TextColored(COLORS.dim, string.format('%3.0f%%', 100 * r[2] / total));
        Tooltip(r[4]);
    end
end

local function DrawRates()
    local r = state.rate;
    imgui.TextColored(COLORS.gold, string.format('pkt in %4.0f/s (%.1f KB/s)   out %3.0f/s   text %3.0f/s   cmd %2.0f/s',
        r.pin, r.pinBytes / 1024, r.pout, r.text, r.cmd));
    Tooltip('Events delivered to addons per second.\nEvery addon with a packet_in / text_in handler pays for each one of these.');
end

local function DrawSpikes()
    if (not cfg.show_spikes) then return; end
    if (imgui.CollapsingHeader(string.format('Spikes > %.0f ms (%d)###spikes', cfg.spike_ms, #state.spikes))) then
        if (#state.spikes == 0) then
            imgui.TextColored(COLORS.dim, 'none yet');
            return;
        end
        if (imgui.BeginTable('##framecost_spikes', 5, 0)) then
            imgui.TableSetupColumn('time', 0, 62);
            imgui.TableSetupColumn('total', 0, 54);
            imgui.TableSetupColumn('render/addon/present', 0, 130);
            imgui.TableSetupColumn('events', 0, 84);
            imgui.TableSetupColumn('packets', 0, 160);
            imgui.TableHeadersRow();
            for i = 1, math.min(#state.spikes, 12) do
                local s = state.spikes[i];
                imgui.TableNextRow();
                imgui.TableNextColumn(); imgui.TextColored(COLORS.dim, s.at);
                imgui.TableNextColumn(); imgui.TextColored(CostColor(s.total), string.format('%.1f', s.total));
                imgui.TableNextColumn(); imgui.TextColored(COLORS.text, string.format('%.1f / %.1f / %.1f', s.scene, s.post, s.gap));
                imgui.TableNextColumn(); imgui.TextColored(COLORS.text, string.format('in%d out%d txt%d', s.pin, s.pout, s.text));
                imgui.TableNextColumn(); imgui.TextColored(COLORS.dim, s.ids);
            end
            imgui.EndTable();
        end
    end
end

local function SortResults()
    local col, asc = profiler.sortCol, profiler.sortAsc;
    local rows = {};
    for i, r in ipairs(profiler.results) do rows[i] = r; end
    table.sort(rows, function(a, b)
        local va, vb = a[col], b[col];
        if (type(va) == 'string') then
            if (asc) then return va < vb; end
            return va > vb;
        end
        if (asc) then return va < vb; end
        return va > vb;
    end);
    return rows;
end

local function SortHeader(label, col, width)
    local mark = '';
    if (profiler.sortCol == col) then
        mark = profiler.sortAsc and ' ^' or ' v';
    end
    if (imgui.SmallButton(label .. mark .. '##sort_' .. col)) then
        if (profiler.sortCol == col) then
            profiler.sortAsc = not profiler.sortAsc;
        else
            profiler.sortCol, profiler.sortAsc = col, (col == 'name');
        end
    end
end

local function DrawProfiler()
    local title = 'Per-addon cost';
    if (profiler.active) then
        title = title .. '  [running: ' .. profiler.status .. ']';
    elseif (#profiler.results > 0) then
        title = title .. string.format('  (%d measured)', #profiler.results);
    end

    if (not imgui.CollapsingHeader(title .. '###profiler', profiler.active and ImGuiTreeNodeFlags_DefaultOpen or 0)) then
        return;
    end

    if (profiler.active) then
        local remaining = math.max(0, profiler.phaseEnd - clock.now());
        imgui.TextColored(COLORS.warn, string.format('%s  -  %s %.0fs left   (hands off!)', profiler.status, profiler.phase, remaining));
        if (profiler.baseline ~= nil) then
            imgui.TextColored(COLORS.dim, string.format('baseline %.3f ms  sd %.3f  (%.0f fps uncapped)', profiler.baseline.ms, profiler.baseline.stddev, profiler.baseline.fps));
            local limit = tonumber(cfg.profile.drift_pct) or 15;
            if (#profiler.baselines >= 2) then
                local bad = profiler.lastDriftPct > limit;
                imgui.TextColored(bad and COLORS.bad or COLORS.good,
                    string.format('scene stability: last re-baseline drifted %.0f%%  %s', profiler.lastDriftPct, bad and 'UNSTABLE - stop moving' or 'ok'));
            end
            local first = profiler.baselines[1].ms;
            local liveDrift = 100 * math.abs(state.emaTotal - first) / math.max(0.001, first);
            imgui.TextColored(liveDrift > limit and COLORS.warn or COLORS.dim,
                string.format('live frame vs first baseline: %.1f vs %.1f ms (%.0f%%)', state.emaTotal, first, liveDrift));
        end
        if (imgui.Button('Stop')) then
            StopProfile('stopped');
        end
    else
        if (imgui.Button('Profile all addons')) then
            StartProfile(cfg.profile.sample_seconds, nil, cfg.profile.include_plugins);
        end
        Tooltip('Unloads each addon from scripts\\default.txt one at a time, samples uncapped frame time,\nreloads it, and reports the difference. Takes a few minutes. Stand still.');
        imgui.SameLine();
        local sec = { cfg.profile.sample_seconds };
        imgui.SetNextItemWidth(90);
        if (imgui.InputInt('sec/sample', sec)) then
            cfg.profile.sample_seconds = math.max(3, sec[1]);
            settings.save();
        end
        imgui.SameLine();
        local plug = { cfg.profile.include_plugins };
        if (imgui.Checkbox('plugins', plug)) then
            cfg.profile.include_plugins = plug[1];
            settings.save();
        end
        Tooltip('Also unload/reload native plugins (nameplate, minimap, deeps...). Core plugins are always skipped.');
    end

    if (#profiler.results == 0) then
        return;
    end

    imgui.Separator();
    local noise = (profiler.baseline and profiler.baseline.stddev or 0) * 2;
    imgui.TextColored(COLORS.dim, string.format('cost = baseline - frame time without the addon.  noise floor ~%.2f ms', noise));
    if (profiler.driftEvents > 0) then
        imgui.TextColored(COLORS.bad, string.format('scene drifted %d time(s) during this run - rows marked ? are invalid', profiler.driftEvents));
    end
    if (profiler.report ~= nil) then
        imgui.TextColored(COLORS.dim, 'saved: ' .. profiler.report);
    end

    SortHeader('Addon', 'name'); imgui.SameLine();
    SortHeader('Cost ms', 'delta'); imgui.SameLine();
    SortHeader('Without', 'ms'); imgui.SameLine();
    SortHeader('Baseline', 'baseline');

    local rows = SortResults();
    local maxDelta = 0.05;
    for _, r in ipairs(rows) do
        if (r.delta > maxDelta) then maxDelta = r.delta; end
    end

    if (imgui.BeginChild('##framecost_results', { UI_WIDTH, math.min(320, 20 * #rows + 8) }, false)) then
        if (imgui.BeginTable('##framecost_results_table', 5, 0)) then
            imgui.TableSetupColumn('name', 0, 150);
            imgui.TableSetupColumn('bar', 0, 110);
            imgui.TableSetupColumn('delta', 0, 70);
            imgui.TableSetupColumn('ms', 0, 70);
            imgui.TableSetupColumn('base', 0, 70);
            for _, r in ipairs(rows) do
                imgui.TableNextRow();
                imgui.TableNextColumn();
                local rowColor = r.unstable and COLORS.dim or DeltaColor(r.delta);
                imgui.TextColored(rowColor, (r.unstable and '? ' or '') .. r.name .. (r.kind == 'plugin' and ' (plugin)' or ''));
                if (r.unstable) then Tooltip('Scene changed between the baselines around this sample. Ignore this value.'); end
                imgui.TableNextColumn();
                DrawStackedBar(100, 10, { { math.max(0, r.delta) / maxDelta, rowColor } });
                imgui.TableNextColumn();
                imgui.TextColored(rowColor, string.format('%+.3f', r.delta));
                imgui.TableNextColumn();
                imgui.TextColored(COLORS.text, string.format('%.3f', r.ms));
                imgui.TableNextColumn();
                imgui.TextColored(COLORS.dim, string.format('%.3f', r.baseline));
            end
            imgui.EndTable();
        end
    end
    imgui.EndChild();
end

local function DrawWindow()
    if (not cfg.visible) then return; end

    local open = { true };
    local flags = bit.bor(ImGuiWindowFlags_NoCollapse or 0, ImGuiWindowFlags_AlwaysAutoResize or 0);
    imgui.SetNextWindowPos({ 18, 148 }, ImGuiCond_FirstUseEver);

    local pushed = PushStyle();
    local began = false;
    local ok, err = pcall(function()
        began = imgui.Begin('FrameCost', open, flags);
        if (not open[1]) then
            cfg.visible = false;
            settings.save();
        end
        if (not began) then return; end

        DrawHeader();
        if (cfg.compact) then
            imgui.TextColored(COLORS.scene, string.format('render %.1f', state.emaScene)); imgui.SameLine();
            imgui.TextColored(COLORS.post,  string.format('addons %.1f', state.emaPost)); imgui.SameLine();
            imgui.TextColored(COLORS.gap,   string.format('present %.1f', state.emaGap));
            if (profiler.active) then
                imgui.TextColored(COLORS.warn, 'profiling: ' .. profiler.status);
            end
            return;
        end

        imgui.Separator();
        DrawPhases();
        if (cfg.show_graph) then
            DrawGraph(UI_WIDTH, 70);
        end
        DrawRates();
        imgui.Separator();
        DrawSpikes();
        DrawProfiler();
    end);

    if (began) then
        imgui.End();
    end
    if (pushed > 0) then
        imgui.PopStyleColor(pushed);
    end
    if (not ok) then
        cfg.visible = false;
        PrintErr('UI error, window hidden: ' .. tostring(err));
    end
end

ashita.events.register('d3d_present', 'framecost_present', function()
    local frame = RecordFrame();
    if (frame ~= nil) then
        ProfilerFrame(frame);
    end

    local t0 = clock.now();
    DrawWindow();
    state.selfMs = Ms(clock.now() - t0);
end);

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------
local function PrintHelp()
    Print('Commands:');
    local cmds = {
        { '/framecost',                    'Toggle the window.' },
        { '/framecost compact',            'Toggle compact mode.' },
        { '/framecost graph | spikes',     'Toggle the graph / spike log.' },
        { '/framecost spike <ms>',         'Set the spike threshold (default 33).' },
        { '/framecost reset',              'Clear stats and spikes.' },
        { '/framecost profile [sec]',      'Measure every addon in default.txt (unload/sample/reload).' },
        { '/framecost profile [sec] only a,b,c', 'Measure only the listed addons.' },
        { '/framecost profile [sec] plugins', 'Also measure native plugins.' },
        { '/framecost profile stop',       'Abort a running profile (reloads the current addon).' },
        { '/framecost report',             'Write the current live stats to a text file.' },
    };
    for _, c in ipairs(cmds) do
        print(chat.header(addon.name):append(chat.message(c[1])):append(' - '):append(chat.color1(6, c[2])));
    end
end

local function WriteLiveReport()
    local path = ReportFolder() .. 'live-' .. os.date('%Y%m%d-%H%M%S') .. '.txt';
    local f = io.open(path, 'w');
    if (f == nil) then
        PrintErr('Could not write ' .. path);
        return;
    end
    local avg, p99, max = WindowStats();
    f:write('framecost live report ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n');
    f:write(string.format('fps %.1f  frame avg %.2f  p99 %.2f  max %.2f ms\n', state.lastFps, avg, p99, max));
    f:write(string.format('game render %.2f  addon draw %.2f  present+logic %.2f  framecost self %.2f ms\n',
        state.emaScene, state.emaPost, state.emaGap, state.emaSelf));
    f:write(string.format('packets in %.0f/s (%.1f KB/s) out %.0f/s  text %.0f/s  cmd %.0f/s\n',
        state.rate.pin, state.rate.pinBytes / 1024, state.rate.pout, state.rate.text, state.rate.cmd));
    f:write('\nspikes:\n');
    for _, s in ipairs(state.spikes) do
        f:write(string.format('  %s  %.1f ms  (render %.1f / addon %.1f / present %.1f)  in%d out%d txt%d  %s\n',
            s.at, s.total, s.scene, s.post, s.gap, s.pin, s.pout, s.text, s.ids));
    end
    f:close();
    Print('Wrote ' .. path);
end

ashita.events.register('command', 'framecost_command', function(e)
    state.ev.cmd = state.ev.cmd + 1;

    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/framecost', '/fc')) then
        return;
    end
    e.blocked = true;

    if (#args == 1) then
        cfg.visible = not cfg.visible;
        settings.save();
        return;
    end

    local sub = args[2]:lower();
    if (sub == 'help') then
        PrintHelp();
    elseif (sub == 'show') then
        cfg.visible = true; settings.save();
    elseif (sub == 'hide') then
        cfg.visible = false; settings.save();
    elseif (sub == 'compact') then
        cfg.compact = not cfg.compact; settings.save();
    elseif (sub == 'graph') then
        cfg.show_graph = not cfg.show_graph; settings.save();
    elseif (sub == 'spikes') then
        cfg.show_spikes = not cfg.show_spikes; settings.save();
    elseif (sub == 'spike' and #args >= 3) then
        cfg.spike_ms = math.max(1, tonumber(args[3]) or 33); settings.save();
        Print('Spike threshold: ' .. tostring(cfg.spike_ms) .. ' ms');
    elseif (sub == 'reset') then
        ResetStats();
    elseif (sub == 'report') then
        WriteLiveReport();
    elseif (sub == 'profile') then
        if (#args >= 3 and args[3]:lower() == 'stop') then
            StopProfile('stopped');
            return;
        end
        local seconds = cfg.profile.sample_seconds;
        local onlyList = nil;
        local plugins = cfg.profile.include_plugins;
        local i = 3;
        while (i <= #args) do
            local a = args[i]:lower();
            if (tonumber(a) ~= nil) then
                seconds = tonumber(a);
            elseif (a == 'only' and args[i + 1] ~= nil) then
                onlyList = args[i + 1];
                i = i + 1;
            elseif (a == 'plugins') then
                plugins = true;
            end
            i = i + 1;
        end
        StartProfile(seconds, onlyList, plugins);
    else
        PrintHelp();
    end
end);

ashita.events.register('unload', 'framecost_unload', function()
    if (profiler.active) then
        StopProfile('addon unloaded');
    end
    settings.save();
end);
