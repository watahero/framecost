# framecost

Per-frame resource monitor + per-addon cost profiler for Ashita v4 (CatsEyeXI).

Like the LibraPlates performance monitor, but for the whole frame and every addon.

## Install

1. Download the latest release (or clone this repo).
2. Copy `addons/framecost` into your Ashita `addons\` folder
   (CatsEyeXI: `CatsEyeXI\catseyexi-client\Ashitaddonsramecost`).
3. Add `/addon load framecost` as the **last** line of `scripts\default.txt`
   (after any `/include`), or run it in game.

Requires Ashita v4 (LuaJIT FFI + ImGui, both standard).

## Live window (`/framecost` or `/fc`)

| Row | What it measures |
|---|---|
| **Game render** | BeginScene → EndScene. The client drawing the world. |
| **Addon draw** | EndScene → Present. Addons drawing their UI. Load framecost **last** so this bucket contains every other addon. |
| **Present + logic** | Present → next BeginScene. VSync / frame-cap wait, game logic, packet processing. Mostly idle if you are capped. |
| **framecost itself** | Cost of this window. |

Plus: fps, avg / p99 / peak frame time, a stacked history graph, packet/text/command
rates per second, and a spike log showing which packets arrived in any frame over the
threshold (`/framecost spike <ms>`).

## Per-addon cost (`/framecost profile`)

Ashita runs each addon in its own Lua state, so nothing can time another addon's
handlers directly. framecost measures by elimination instead:

1. Reads your current `/fps` divisor and sets it to 0 (uncapped — a cap hides the cost).
2. Samples a baseline with everything loaded.
3. For each `/addon load X` in `scripts\default.txt`: unload X → settle → sample → reload X.
4. Re-samples the baseline every 4 addons and scores each addon against the average of
   the baselines around it, so drift does not land on one addon.
5. Restores your fps divisor and writes `config\addons\framecost\profile-<stamp>.txt`.

Stand still, camera fixed, hands off. ~15 s per addon with the defaults.

```
/framecost profile            measure everything (default 10 s per sample)
/framecost profile 15         15 s per sample (less noise)
/framecost profile only xiui,statustimers,recast
/framecost profile plugins    also unload/reload native plugins (nameplate, minimap, deeps…)
/framecost profile stop
```

Skipped by default: framecost, hideconsole, fps, move, nolock, timestamp, and the core
plugins (addons, thirdparty, cexidats, render, screenshot, hardwaremouse). Edit the
`exclude` lists in `config\addons\framecost\settings.lua` to change that.

Values within ~2× the baseline standard deviation are noise.

**Scene drift guard.** If a re-baseline differs from the previous one by more than
`drift_pct` (default 15 %), you moved / the crowd changed, and every result measured
between those two baselines is flagged `?` in the table and the report — ignore them.
While a run is active the window shows a live *scene stability* line so you can tell
within a minute whether the run is going to be valid. Set `abort_on_drift = true` in the
settings file to stop the run instead of flagging.

## Other commands

```
/framecost compact | graph | spikes | reset | report | help
```
