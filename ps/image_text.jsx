// Moni 动作「图片文字」的 Photoshop 脚本（ExtendScript / JSX）。
//
// 由动作自带的 runner 调用：moniRun(job)，job.params =
//   { blocks:[{ text, box:{x,y,w,h} }], font, fit_mode, color_mode,
//     calibration, group, group_name, run_id }
// 其中 box 为截图内的归一化坐标（0..1）。
//
// 也可以从 Photoshop 的「文件 > 脚本」手动运行：没有 job 时会使用空数据并报错，
// 因此本脚本的用途主要是被动作调用/供用户查看。

function moniClamp(value, min, max) {
  if (value < min) { return min; }
  if (value > max) { return max; }
  return value;
}

// 归一化 box → 目标矩形内的像素 box。
function moniMapBox(box, target) {
  return {
    x: target.x + box.x * target.w,
    y: target.y + box.y * target.h,
    w: box.w * target.w,
    h: box.h * target.h
  };
}

// 字号（pt）= 像素高 × (72 / dpi)。PS 文档可能是 72/144/300dpi。
function moniFontSizePt(boxHeight, targetHeight, resolution) {
  var pixels = boxHeight * targetHeight * 0.78;
  var dpi = resolution > 0 ? resolution : 72;
  return moniClamp(Math.round((pixels * 72 / dpi) * 10) / 10, 1, 1000);
}

function moniLayerName(text, maxLength) {
  var name = String(text == null ? "" : text).replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
  var limit = maxLength > 0 ? maxLength : 32;
  if (name.length > limit) {
    name = name.substring(0, limit - 1) + "\u2026";
  }
  return name.length ? name : "Text";
}

function moniTextColor(mode, sampled) {
  if (mode === "white") { return { r: 255, g: 255, b: 255 }; }
  if (mode === "sample" && sampled &&
      typeof sampled.r === "number" && typeof sampled.g === "number" && typeof sampled.b === "number") {
    return { r: sampled.r, g: sampled.g, b: sampled.b };
  }
  return { r: 0, g: 0, b: 0 };
}

function moniTargetRect(doc, mode, warnings) {
  var full = {
    x: 0,
    y: 0,
    w: doc.width.as("px"),
    h: doc.height.as("px")
  };
  if (mode !== "selection") { return full; }
  try {
    var bounds = doc.selection.bounds;
    var left = bounds[0].as("px");
    var top = bounds[1].as("px");
    var right = bounds[2].as("px");
    var bottom = bounds[3].as("px");
    if (right - left > 1 && bottom - top > 1) {
      return { x: left, y: top, w: right - left, h: bottom - top };
    }
  } catch (ignored) {}
  warnings.push("no active selection; using the full canvas");
  return full;
}

function moniSampleColor(doc, x, y) {
  var sampler = null;
  try {
    sampler = doc.colorSamplers.add([new UnitValue(x, "px"), new UnitValue(y, "px")]);
    var rgb = sampler.color.rgb;
    return { r: rgb.red, g: rgb.green, b: rgb.blue };
  } catch (ignored) {
    return null;
  } finally {
    if (sampler) {
      try { doc.colorSamplers.remove(sampler); } catch (ignored2) {}
    }
  }
}

function moniApplyFont(textItem, font, warnings) {
  if (!font) { return; }
  try {
    textItem.font = font;
  } catch (ignored) {
    if (warnings.length < 5) { warnings.push("font not found: " + font); }
  }
}

function moniApplyColor(textItem, color) {
  var solid = new SolidColor();
  solid.rgb.red = color.r;
  solid.rgb.green = color.g;
  solid.rgb.blue = color.b;
  textItem.color = solid;
}

function moniFitOnce(layer, textItem, box, params, warnings) {
  var mode = params.fit_mode || "height";
  if (mode === "height") { return; }
  try {
    var bounds = layer.bounds;
    var actualWidth = bounds[2].as("px") - bounds[0].as("px");
    var actualHeight = bounds[3].as("px") - bounds[1].as("px");
    if (actualWidth <= 0 || actualHeight <= 0) { return; }
    var scale;
    if (mode === "width") {
      scale = box.w / actualWidth;
    } else {
      scale = Math.min(box.w / actualWidth, box.h / actualHeight);
      if (scale > 1) { scale = 1; }
    }
    if (scale > 0 && Math.abs(scale - 1) > 0.02) {
      textItem.size = textItem.size.as("pt") * scale;
    }
  } catch (error) {
    if (warnings.length < 5) { warnings.push("cannot fit text: " + error.message); }
  }
}

function moniCreateLayer(doc, group, block, target, params, warnings) {
  var mapped = moniMapBox(block.box, target);
  if (mapped.w <= 0 || mapped.h <= 0) { return null; }

  var layer = doc.artLayers.add();
  layer.kind = LayerKind.TEXT;
  layer.name = moniLayerName(block.text, 40);

  var textItem = layer.textItem;
  textItem.kind = TextType.POINTTEXT;
  textItem.contents = String(block.text);
  textItem.justification = Justification.LEFT;
  textItem.antiAliasMethod = AntiAlias.SHARP;
  moniApplyFont(textItem, params.font, warnings);
  textItem.size = new UnitValue(
    moniFontSizePt(block.box.h, target.h, doc.resolution),
    "pt"
  );

  // 采样点取块中心；截图与文档内容对齐时颜色才准确。
  var sampled = null;
  if ((params.color_mode || "sample") === "sample") {
    sampled = moniSampleColor(doc, mapped.x + mapped.w / 2, mapped.y + mapped.h / 2);
    if (!sampled && warnings.length < 5) { warnings.push("color sampling failed; using black"); }
  }
  moniApplyColor(textItem, moniTextColor(params.color_mode, sampled));

  // 点文本的 position 原点是第一行基线左下角，因此用块底边定位。
  textItem.position = [
    new UnitValue(mapped.x, "px"),
    new UnitValue(mapped.y + mapped.h, "px")
  ];
  moniFitOnce(layer, textItem, mapped, params, warnings);

  if (group) {
    layer.move(group, ElementPlacement.INSIDE);
  }
  return layer;
}

function moniRunApply() {
  var state = $.global.__moniJob;
  var params = state.params;
  var doc = state.doc;
  var warnings = state.warnings;
  var blocks = params.blocks || [];
  var target = moniTargetRect(doc, params.calibration, warnings);

  var group = null;
  if (params.group !== false) {
    try {
      group = doc.layerSets.add();
      group.name = params.group_name || "Moni OCR";
      doc.activeLayer = group;
    } catch (error) {
      warnings.push("cannot create layer group: " + error.message);
      group = null;
    }
  }

  var layers = [];
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i];
    if (!block || !block.text || !block.box) { continue; }
    try {
      var layer = moniCreateLayer(doc, group, block, target, params, warnings);
      if (layer) {
        layers.push({ id: layer.id, name: layer.name });
      }
    } catch (error) {
      if (warnings.length < 5) {
        warnings.push("block " + (i + 1) + " failed: " + error.message);
      }
    }
  }
  $.global.__moniResult = { layers: layers };
}

function moniRun(job) {
  if (!app.documents.length) {
    throw { code: "A401_PS_NO_DOC", message: "open a document before running this action" };
  }
  var params = (job && job.params) || {};
  if (!params.blocks || !params.blocks.length) {
    throw { code: "A101_NO_TEXT", message: "no OCR blocks to place" };
  }
  $.global.__moniJob = {
    doc: app.activeDocument,
    params: params,
    warnings: []
  };
  $.global.__moniResult = null;
  try {
    app.activeDocument.suspendHistory("Moni: image to text", "moniRunApply()");
    if (!$.global.__moniResult) {
      throw { code: "A500_ACTION_FAILED", message: "script did not finish" };
    }
    return {
      layers: $.global.__moniResult.layers,
      warnings: $.global.__moniJob.warnings
    };
  } finally {
    delete $.global.__moniJob;
    delete $.global.__moniResult;
  }
}
