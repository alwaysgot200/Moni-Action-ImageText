-- Moni 动作「图片文字」：框选 → OCR → 在 Photoshop 当前文档里生成文字图层。
--
-- Moni 不提供任何 PS 专属能力：动作自带 runner（ps/runner.jsx），经
-- ctx.process.run 启动 manifest 声明过的 Photoshop（macOS 为 osascript）。
-- 脚本安装与运行前检查同样由本动作完成：安装走 setup.lua，运行前先 check。

local ACTION_ID = "ps.image-to-text"
local SCRIPT_NAME = "image_text.jsx"
local POLL_MS = 100
local MAX_POLLS = 450 -- 约 45s：由动作启动 PS 时含冷启动
local PROBE_POLLS = 30 -- 已在运行时 3s 内必须响应，否则判定通道不通
local LAUNCH_POLLS = 450 -- 等进程出现最多 45s（PS 冷启动较慢）

-- 依赖软件是否在运行：只问宿主「进程在不在」，不涉及权限或软件语义。
local function app_online(ctx)
  local ok, info = pcall(ctx.process.inspect, "photoshop")
  return ok and type(info) == "table" and info.running == true
end

-- 运行期前置条件：Photoshop 在线，不在线时按动作选项决定是否由宿主启动。
-- 返回 launched（是否本次启动）与结构化错误；调起失败立即中止，不等超时。
local function ensure_app(ctx)
  if app_online(ctx) then
    return false, nil
  end
  if ctx.options.launch_app == false then
    return false, {
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_not_running"),
      hint = ctx.t("hint.ps_not_running"),
    }
  end
  ctx.notify(ctx.t("notice.launching_ps"))
  local started, err = pcall(ctx.process.run, "photoshop", {}, { wait = false })
  if not started then
    return false, {
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_launch_failed"),
      detail = tostring(err),
    }
  end
  for _ = 1, LAUNCH_POLLS do
    if app_online(ctx) then
      return true, nil
    end
    ctx.sleep(POLL_MS)
  end
  return false, { code = "A407_PS_OFFLINE", message = ctx.t("error.ps_launch_timeout") }
end

-- 写 job → 启动 runner → 轮询 result.json；返回脚本的 value，失败则抛出结构化错误。
local function run_jsx(ctx, script, params, max_polls)
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
    -- Windows 的 -r 在已运行的 Photoshop 进程里执行，进程环境变量传不过去；
    -- 把路径写进一次性包装脚本，由它设置全局变量后再调用 runner。
    local wrapper = "$.global.__MONI_JOB='" .. job_path:gsub("\\", "/") .. "';"
      .. "$.global.__MONI_SCRIPT='" .. script_path:gsub("\\", "/") .. "';"
      .. "$.global.__MONI_RESULT='" .. result_path:gsub("\\", "/") .. "';"
      .. "$.evalFile('" .. runner_path:gsub("\\", "/") .. "');"
    ctx.fs.write("runner_wrapper.jsx", wrapper)
    ctx.process.run("photoshop", { "-r", ctx.fs.path("runner_wrapper.jsx") }, { wait = false })
  end

  for _ = 1, max_polls or MAX_POLLS do
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

local function check_ps_script(ctx, max_polls)
  local ok, state = pcall(run_jsx, ctx, "setup.jsx", {
    mode = "check",
    action_id = ACTION_ID,
    file_name = SCRIPT_NAME,
  }, max_polls)
  if not ok then
    -- state 是结构化错误表（PS 未安装、超时、脚本异常等）。
    return false, state
  end
  return state ~= nil and state.installed == true, nil
end

function run(ctx)
  local launched, offline = ensure_app(ctx)
  if offline then
    return {
      ok = false,
      code = offline.code,
      message = offline.message,
      hint = offline.hint,
      detail = offline.detail,
    }
  end

  -- 已在运行却 3s 无响应：双方权限不一致（如 PS 以管理员运行）或 PS 无响应。
  local installed, failure = check_ps_script(ctx, launched and MAX_POLLS or PROBE_POLLS)
  if failure then
    if failure.code == "A501_TIMEOUT" then
      return {
        ok = false,
        code = "A407_PS_OFFLINE",
        message = ctx.t("error.ps_comm_failed"),
        hint = ctx.t("hint.ps_comm_failed"),
      }
    end
    return {
      ok = false,
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_unavailable"),
      detail = tostring(failure.message or failure),
    }
  end
  if not installed then
    -- 用户只点「运行」：脚本没装就由动作自己装到 PS 脚本目录，下次运行只做检查。
    ctx.notify(ctx.t("notice.installing_script"))
    local ok, state = pcall(run_jsx, ctx, "setup.jsx", {
      mode = "install",
      action_id = ACTION_ID,
      file_name = SCRIPT_NAME,
    }, MAX_POLLS)
    if not ok or type(state) ~= "table" or state.installed ~= true then
      return {
        ok = false,
        code = "A500_ACTION_FAILED",
        message = ctx.t("error.ps_setup_required"),
        hint = ctx.t("hint.ps_setup_required"),
        detail = tostring(ok and "install reported not installed" or state),
      }
    end
  end

  local opt = ctx.options
  -- 取消框选在宿主侧是结构化错误（A502），不是 nil；用 pcall 转成本地化返回值。
  local picked, grab = pcall(ctx.capture.pick_region, {
    mode = "rect",
    hint = ctx.t("hint.pick_region"),
  })
  if not picked then
    local failure = grab
    if type(failure) == "table" and failure.code == "A502_CANCELLED" then
      return { ok = false, code = "A502_CANCELLED", message = ctx.t("error.cancelled") }
    end
    error(failure, 0)
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
