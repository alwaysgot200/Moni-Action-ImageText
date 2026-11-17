-- Moni 动作「图片文字」：框选 → OCR → 在 Photoshop 当前文档里生成文字图层。
--
-- Moni 不提供任何 PS 专属能力：动作自带 runner（ps/runner.jsx），经
-- ctx.process.run 启动 manifest 声明过的 Photoshop（macOS 为 osascript）。
-- 脚本安装与运行前检查同样由本动作完成：安装走 setup.lua，运行前先 check。

local ACTION_ID = "ps.image-to-text"
local SCRIPT_NAME = "image_text.jsx"
local POLL_MS = 100
local MAX_POLLS = 400 -- 约 40s

-- 写 job → 启动 runner → 轮询 result.json；返回脚本的 value，失败则抛出结构化错误。
local function run_jsx(ctx, script, params)
  ctx.fs.remove("result.json")
  ctx.fs.write("job.json", ctx.json.encode({ version = 1, params = params }))
  local job_path = ctx.fs.path("job.json")
  local result_path = ctx.fs.path("result.json")
  local script_path = ctx.action_dir .. "/ps/" .. script
  local runner_path = ctx.action_dir .. "/ps/runner.jsx"

  if ctx.platform == "macos" then
    -- osascript 的环境变量不会传给 Photoshop，用 do javascript 注入 $.global。
    local inline = "__MONI_JOB='" .. job_path .. "';"
      .. "__MONI_SCRIPT='" .. script_path .. "';"
      .. "__MONI_RESULT='" .. result_path .. "';"
      .. "$.evalFile('" .. runner_path .. "');"
    ctx.process.run("osascript", {
      "-e",
      'tell application id "com.adobe.Photoshop" to do javascript "' .. inline .. '"',
    }, { wait = false })
  else
    ctx.process.run("photoshop", { "-r", runner_path }, {
      env = {
        MONI_JOB = job_path,
        MONI_SCRIPT = script_path,
        MONI_RESULT = result_path,
      },
      wait = false,
    })
  end

  for _ = 1, MAX_POLLS do
    if ctx.fs.exists("result.json") then
      local out = ctx.json.decode(ctx.fs.read("result.json"))
      if out.ok then
        return out.value or {}
      end
      local failure = out.error or {}
      error({
        code = failure.code or "A500_ACTION_FAILED",
        message = failure.message or ctx.t("error.ps_unavailable"),
      })
    end
    ctx.sleep(POLL_MS)
  end
  error({ code = "A501_TIMEOUT", message = ctx.t("error.ps_unavailable") })
end

local function check_ps_script(ctx)
  local ok, state = pcall(run_jsx, ctx, "setup.jsx", {
    mode = "check",
    action_id = ACTION_ID,
    file_name = SCRIPT_NAME,
  })
  if not ok then
    -- state 是结构化错误表（PS 未安装、超时、脚本异常等）。
    return false, state
  end
  return state ~= nil and state.installed == true, nil
end

function run(ctx)
  local installed, failure = check_ps_script(ctx)
  if failure then
    return {
      ok = false,
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_unavailable"),
      detail = tostring(failure.message or failure),
    }
  end
  if not installed then
    return {
      ok = false,
      code = "A500_ACTION_FAILED",
      message = ctx.t("error.ps_setup_required"),
      hint = ctx.t("hint.ps_setup_required"),
    }
  end

  local opt = ctx.options
  local grab = ctx.capture.pick_region({
    mode = "rect",
    hint = ctx.t("hint.pick_region"),
  })
  if not grab then
    return { ok = false, code = "A502_CANCELLED", message = ctx.t("error.cancelled") }
  end

  local ocr = ctx.ocr.recognize(grab.asset, {
    lang = opt.lang,
    return_boxes = true,
    min_score = opt.min_score,
  })
  local blocks = ocr and ocr.blocks or {}
  if #blocks == 0 then
    return { ok = false, code = "A101_NO_TEXT", message = ctx.t("error.no_text") }
  end

  ctx.progress(0.5, ctx.t("progress.creating_layers", #blocks))
  local result = run_jsx(ctx, SCRIPT_NAME, {
    calibration = opt.calibration,
    blocks = blocks,
    font = opt.font,
    fit_mode = opt.fit_mode,
    color_mode = opt.color_mode,
    group = opt.group,
    group_name = "Moni OCR " .. ctx.run_id,
    run_id = ctx.run_id,
  })

  return {
    ok = true,
    layers = result.layers,
    warnings = result.warnings,
  }
end
