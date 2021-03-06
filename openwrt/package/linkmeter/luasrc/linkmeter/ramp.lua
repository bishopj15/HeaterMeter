module("linkmeter.ramp", package.seeall)

local RAMPSTATE_NONE    = 0
local RAMPSTATE_RAMPING = 1

local function log(...)
  nixio.syslog("warning", ...)
  --print(...)
end

local ctx
local function resetContext()
  ctx = {
    state = RAMPSTATE_NONE,
    updateCnt = nil,
    startSetpoint = nil,
    lastSetpoint = nil,
    requestedSetpoint = nil,
    params = {}
  }
end

local function uciSetSingle(param, val)
  local uci = require "uci"
  uci = uci.cursor()
  uci:set("linkmeter", "ramp", param, val)
  uci:commit("linkmeter")
end

local function cancelRamp()
  uciSetSingle("enabled", "0")
  uciSetSingle("startsetpoint", "")
  ctx.state = RAMPSTATE_NONE
  ctx.params.enabled = false

  linkmeterd.publishStatusVal("ramp", nil)
end

local function setpointChanged(setpoint)
  if ctx.state == RAMPSTATE_RAMPING and setpoint ~= ctx.requestedSetpoint then
    log("Unrequested setpoint change detected. Ramp canceled.")
    cancelRamp()
  end
  ctx.lastSetpoint = setpoint
end

local function reloadRampParameters()
  local uci = require "uci"
  uci = uci.cursor()

  ctx.params = {
    enabled = uci:get("linkmeter", "ramp", "enabled") == "1",
    watch = {},
    target = tonumber(uci:get("linkmeter", "ramp", "target")) or 999,
    trigger = tonumber(uci:get("linkmeter", "ramp", "trigger")) or 999
  }
  -- Split the watch string "1 2 3" into a table {1,2,3}
  (uci:get("linkmeter", "ramp", "watch") or ""):gsub("([^%s])", function(x) ctx.params.watch[#ctx.params.watch+1] = tonumber(x) end)

  if ctx.params.enabled then
    ctx.startSetpoint = tonumber(uci:get("linkmeter", "ramp", "startsetpoint"))
  end
end

local function updateState(now, vals)
  -- SetPoint, Probe0, Probe1, Probe2, Probe3, Output, OutputAvg, Lid, Fan
  -- 1         2       3       4       5       6       7          8    9
  local setpoint = tonumber(vals[1])
  if ctx.lastSetpoint ~= setpoint then setpointChanged(setpoint) end

  -- No setpoint (manual mode or off) or not enabled or no watch probe length = Disabled
  if setpoint == nil or not ctx.params.enabled or #ctx.params.watch == 0 then
    if ctx.state ~= RAMPSTATE_NONE then cancelRamp() end
    return
  end

  local watchVal
  for _,w in pairs(ctx.params.watch) do
    local probeVal = tonumber(vals[2+w]) -- returns nil for both not number as well as 'U' (probe unplugged)
    if probeVal ~= nil then
      watchVal = watchVal and (watchVal + probeVal) or probeVal
    end
  end
  -- If watchprobe is unplugged or not a number, just pause the ramping
  if watchVal == nil then return end
  -- Divide probe sum by count
  watchVal = watchVal / #ctx.params.watch

  if ctx.state == RAMPSTATE_NONE and
    (watchVal > ctx.params.trigger or ctx.startSetpoint ~= nil) then
    ctx.state = RAMPSTATE_RAMPING
    ctx.updateCnt = 0
    if ctx.startSetpoint == nil then
      ctx.startSetpoint = setpoint
      -- save the fact that we're ramping in nonvolatile storage
      -- to be able to restore in case of power loss
      uciSetSingle("startsetpoint", setpoint)
    end
    log(("Beginning ramp: Set(%d->%d) Watch(%d->%d)"):format(
      ctx.startSetpoint, ctx.params.target, ctx.params.trigger, ctx.params.target))
  end

  if ctx.state == RAMPSTATE_RAMPING then
    local newSp = ctx.lastSetpoint
    local watchDiff = ctx.params.target - watchVal
    if watchDiff < 1 or (ctx.params.target == ctx.params.trigger) then
      log("Ramp complete")
      newSp = ctx.params.target
      cancelRamp()
    else
      ctx.updateCnt = ctx.updateCnt - 1
      -- Only update every N seconds
      if ctx.updateCnt <= 0 then
        ctx.updateCnt = 60
        local rampProgress = (ctx.params.target - watchVal) / (ctx.params.target - ctx.params.trigger)
        newSp = math.ceil((ctx.startSetpoint - ctx.params.target) * rampProgress) + ctx.params.target

        linkmeterd.publishStatusVal("ramp", {
          s = ctx.startSetpoint,
          ta = ctx.params.target,
          tr = ctx.params.trigger
        })
      end -- if time to update ramp
    end -- if not done

    if newSp ~= ctx.lastSetpoint then
      ctx.requestedSetpoint = newSp
      linkmeterd.hmWrite("/set?sp=" .. newSp .. "\n")
      log(("New ramp setpoint %d vs %d at watchVal %.1f"):format(newSp, ctx.lastSetpoint, watchVal))
    end
  end  -- if RAMPING
end

local function segLmRamp()
  -- Right now just the one thing, nofify config change
  reloadRampParameters()
  return "OK"
end

function init()
  resetContext()
  reloadRampParameters()
  linkmeterd.registerStatusListener(updateState)
  linkmeterd.registerSegmentListener("$LMRA", segLmRamp)
end
