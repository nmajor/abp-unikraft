#!/bin/bash
# Apply feature edits to ABP source: bandwidth metering + full page screenshot.
#
# Same approach as apply-stealth-edits.sh — finds insertion points by anchor
# strings rather than exact line numbers, so it survives ABP version bumps.
#
# These edits modify ABP-specific files (not core Chromium), targeting:
#   - chrome/browser/abp/abp_network_capture.{h,cc}  (bandwidth metering)
#   - chrome/browser/abp/abp_action_context.cc        (response integration)
#   - chrome/browser/abp/abp_controller.{h,cc}        (full page screenshot)
#
# Usage: ./apply-feature-edits.sh /path/to/src
set -euo pipefail

SRC="$1"

if [ ! -d "${SRC}/chrome/browser/abp" ]; then
    echo "ERROR: Not an ABP source tree: ${SRC}"
    exit 1
fi

APPLIED=0
SKIPPED=0

echo "==> Applying feature edits to ABP source..."
echo ""

# ===================================================================
# Feature 1: Bandwidth Metering
# ===================================================================
# Adds per-action and per-session byte counters to AbpNetworkCapture
# using CDP Network event data (encodedDataLength from loadingFinished,
# estimated request size from requestWillBeSent). Counters are included
# in every action response under the "network" key.
# ===================================================================

# -------------------------------------------------------------------
# 1a: Add byte counter accessors + members to abp_network_capture.h
# -------------------------------------------------------------------
NC_HEADER="chrome/browser/abp/abp_network_capture.h"
if [ -f "${SRC}/${NC_HEADER}" ]; then
    python3 << PYEOF
import sys

filepath = "${SRC}/${NC_HEADER}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP feature' in content:
    print("  SKIP bandwidth meter (header) -- already applied")
    sys.exit(0)

modified = False

# --- Insert accessor methods after GetPendingCount ---
anchor = 'GetPendingCount()'
if anchor not in content:
    # Try alternate signatures
    for alt in ['GetPendingCount() const', 'pending_count()', 'GetPendingCount']:
        if alt in content:
            anchor = alt
            break

# Insert ONE block with both accessors and member variables.
# Use GetPendingCount as anchor — it's definitely inside the class.
# We include an explicit 'private:' before the members and restore
# the original access level afterwards so the rest of the class is
# unaffected.
if anchor in content:
    idx = content.find(anchor)
    semi = content.find(';', idx)
    if semi < 0:
        semi = content.find('\n', idx)
    newline = content.find('\n', semi)

    # Determine current access level to restore it after our block.
    # Search backwards from anchor for public:/private:/protected:.
    chunk = content[:idx]
    restore = 'public'
    for kw in ['public:', 'private:', 'protected:']:
        ki = chunk.rfind(kw)
        if ki >= 0:
            restore = kw.rstrip(':')
            break

    combined_block = '''
  // ABP feature: per-action bandwidth metering.
  int64_t GetBytesReceived() const { return action_bytes_received_; }
  int64_t GetBytesSent() const { return action_bytes_sent_; }
  int64_t GetTotalBytesTransferred() const {
    return action_bytes_received_ + action_bytes_sent_;
  }
  int64_t GetSessionBytesReceived() const { return session_bytes_received_; }
  int64_t GetSessionBytesSent() const { return session_bytes_sent_; }
  void ResetActionByteCounts();

 private:
  // ABP feature: bandwidth byte counters.
  int64_t action_bytes_received_ = 0;
  int64_t action_bytes_sent_ = 0;
  int64_t session_bytes_received_ = 0;
  int64_t session_bytes_sent_ = 0;

 ''' + restore + ''':
'''
    content = content[:newline+1] + combined_block + content[newline+1:]
    modified = True
    print("  OK   bandwidth meter -- accessors + members (single block)")
else:
    print("  WARN bandwidth meter -- GetPendingCount anchor not found")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
    print("  OK   bandwidth meter header complete")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP bandwidth meter (header) -- file not found: ${NC_HEADER}"
    SKIPPED=$((SKIPPED + 1))
fi

# -------------------------------------------------------------------
# 1b: Add byte accumulation logic to abp_network_capture.cc
# -------------------------------------------------------------------
NC_IMPL="chrome/browser/abp/abp_network_capture.cc"
if [ -f "${SRC}/${NC_IMPL}" ]; then
    python3 << PYEOF
import sys

filepath = "${SRC}/${NC_IMPL}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP feature' in content:
    print("  SKIP bandwidth meter (impl) -- already applied")
    sys.exit(0)

modified = False

# --- Hook into OnLoadingFinished to accumulate received bytes ---
# The loadingFinished CDP event includes "encodedDataLength" which is
# total bytes received over the wire for this request.
# IMPORTANT: search for the full method signature to avoid matching
# the dispatch call inside OnNetworkEvent().
for anchor in ['AbpNetworkCapture::OnLoadingFinished', 'void AbpNetworkCapture::OnLoadingFinished']:
    if anchor in content:
        idx = content.find(anchor)
        # Find the opening brace of this method body
        brace = content.find('{', idx)
        if brace > 0:
            inject = '''
  // ABP feature: accumulate received bytes from encodedDataLength.
  {
    auto encoded_len = params.FindDouble("encodedDataLength");
    if (!encoded_len) {
      // Try nested inside the event data.
      if (auto* p = params.FindDict("params"))
        encoded_len = p->FindDouble("encodedDataLength");
    }
    if (encoded_len && *encoded_len > 0) {
      action_bytes_received_ += static_cast<int64_t>(*encoded_len);
      session_bytes_received_ += static_cast<int64_t>(*encoded_len);
    }
  }
'''
            content = content[:brace+1] + inject + content[brace+1:]
            modified = True
            print("  OK   bandwidth meter -- OnLoadingFinished byte accumulation")
            break
else:
    print("  WARN bandwidth meter -- loadingFinished anchor not found")

# --- Hook into OnRequestWillBeSent to estimate sent bytes ---
# IMPORTANT: match the full method signature, not the dispatch call.
for anchor in ['AbpNetworkCapture::OnRequestWillBeSent', 'void AbpNetworkCapture::OnRequestWillBeSent']:
    if anchor in content:
        idx = content.find(anchor)
        brace = content.find('{', idx)
        if brace > 0:
            inject = '''
  // ABP feature: estimate sent bytes from request metadata.
  {
    const base::Value::Dict* req = params.FindDict("request");
    if (!req) {
      if (auto* p = params.FindDict("params"))
        req = p->FindDict("request");
    }
    if (req) {
      int64_t sent = 0;
      if (const auto* url = req->FindString("url"))
        sent += static_cast<int64_t>(url->size());
      if (const auto* body = req->FindString("postData"))
        sent += static_cast<int64_t>(body->size());
      if (const auto* hdrs = req->FindDict("headers")) {
        for (const auto kv : *hdrs) {
          sent += static_cast<int64_t>(kv.first.size());
          if (kv.second.is_string())
            sent += static_cast<int64_t>(kv.second.GetString().size());
          sent += 4;  // ": " + CRLF overhead
        }
      }
      action_bytes_sent_ += sent;
      session_bytes_sent_ += sent;
    }
  }
'''
            content = content[:brace+1] + inject + content[brace+1:]
            modified = True
            print("  OK   bandwidth meter -- OnRequestWillBeSent byte estimation")
            break
else:
    print("  WARN bandwidth meter -- requestWillBeSent anchor not found")

# --- Add ResetActionByteCounts method ---
# The .cc file has NO wrapping namespace — methods are at file scope.
# Just append the new method at the end of the file. Simple and safe.
reset_method = '''
// ABP feature: reset per-action byte counters.
void AbpNetworkCapture::ResetActionByteCounts() {
  action_bytes_received_ = 0;
  action_bytes_sent_ = 0;
}
'''

# Append to end of file (after all existing methods).
content = content.rstrip() + '\n' + reset_method
modified = True
print("  OK   bandwidth meter -- ResetActionByteCounts method (appended)")

# --- Also reset action bytes in ClearBuffer ---
# Use exact method signature to avoid matching comments or other mentions.
clear_anchor = 'AbpNetworkCapture::ClearBuffer()'
if clear_anchor in content:
    idx = content.find(clear_anchor)
    brace = content.find('{', idx)
    if brace > 0:
        inject = '''
  // ABP feature: also reset action byte counters on buffer clear.
  ResetActionByteCounts();
'''
        content = content[:brace+1] + inject + content[brace+1:]
        modified = True
        print("  OK   bandwidth meter -- ClearBuffer reset hook")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
    print("  OK   bandwidth meter impl complete")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP bandwidth meter (impl) -- file not found: ${NC_IMPL}"
    SKIPPED=$((SKIPPED + 1))
fi

# -------------------------------------------------------------------
# 1c: Include bandwidth data in action response envelope
# -------------------------------------------------------------------
ACTION_CTX="chrome/browser/abp/abp_action_context.cc"
if [ -f "${SRC}/${ACTION_CTX}" ]; then
    python3 << PYEOF
import sys

filepath = "${SRC}/${ACTION_CTX}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP feature' in content:
    print("  SKIP bandwidth response (action_context) -- already applied")
    sys.exit(0)

modified = False

# --- Add bandwidth fields to the network dict in SendResponse ---
# Look for where net_dict.Set("pending", ...) is called — that's where
# we add our bandwidth fields.
for anchor in ['net_dict.Set("pending"', '"pending", nc->GetPendingCount',
               'net_dict.Set("completed"', '"network"']:
    if anchor in content:
        idx = content.find(anchor)
        # Find end of this line
        eol = content.find('\n', idx)
        # After the pending count line, also after completed if it's there
        # Find the next line that starts with "envelope" or similar
        # Safest: insert right after this line
        inject = '''    // ABP feature: bandwidth metering per action.
    net_dict.Set("bytes_received",
                 static_cast<double>(nc->GetBytesReceived()));
    net_dict.Set("bytes_sent",
                 static_cast<double>(nc->GetBytesSent()));
    net_dict.Set("bytes_total",
                 static_cast<double>(nc->GetTotalBytesTransferred()));
    net_dict.Set("session_bytes_received",
                 static_cast<double>(nc->GetSessionBytesReceived()));
    net_dict.Set("session_bytes_sent",
                 static_cast<double>(nc->GetSessionBytesSent()));
'''
        content = content[:eol+1] + inject + content[eol+1:]
        modified = True
        print("  OK   bandwidth response -- added to network dict")
        break
else:
    print("  WARN bandwidth response -- no network dict anchor found")
    # Fallback: find envelope.Set("network" and inject before it
    if 'envelope.Set("network"' in content:
        idx = content.find('envelope.Set("network"')
        line_start = content.rfind('\n', 0, idx) + 1
        inject = '''    // ABP feature: bandwidth metering (injected before network dict set).
    if (tab_it != controller_->tab_states_.end() &&
        tab_it->second.network_capture) {
      auto* nc_bw = tab_it->second.network_capture.get();
      base::Value::Dict bw_dict;
      bw_dict.Set("bytes_received",
                   static_cast<double>(nc_bw->GetBytesReceived()));
      bw_dict.Set("bytes_sent",
                   static_cast<double>(nc_bw->GetBytesSent()));
      bw_dict.Set("bytes_total",
                   static_cast<double>(nc_bw->GetTotalBytesTransferred()));
      bw_dict.Set("session_bytes_received",
                   static_cast<double>(nc_bw->GetSessionBytesReceived()));
      bw_dict.Set("session_bytes_sent",
                   static_cast<double>(nc_bw->GetSessionBytesSent()));
      envelope.Set("bandwidth", std::move(bw_dict));
    }
'''
        content = content[:line_start] + inject + content[line_start:]
        modified = True
        print("  OK   bandwidth response -- added as envelope.bandwidth (fallback)")

# --- Reset action byte counts at the start of each action ---
# Look for where the action context begins its lifecycle (Run method or
# where SetCurrentActionId is called).
for anchor in ['SetCurrentActionId(action_id_)', 'SetCurrentActionId(',
               'profile_queued_at_', 'Run(']:
    if anchor in content:
        idx = content.find(anchor)
        eol = content.find('\n', idx)
        inject = '''    // ABP feature: reset per-action byte counters.
    {
      auto tab_it_bw = controller_->tab_states_.find(tab_id_);
      if (tab_it_bw != controller_->tab_states_.end() &&
          tab_it_bw->second.network_capture) {
        tab_it_bw->second.network_capture->ResetActionByteCounts();
      }
    }
'''
        content = content[:eol+1] + inject + content[eol+1:]
        modified = True
        print("  OK   bandwidth meter -- reset at action start")
        break
else:
    print("  WARN bandwidth meter -- no action start anchor found for reset")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
    print("  OK   bandwidth response integration complete")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP bandwidth response -- file not found: ${ACTION_CTX}"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Feature 2: Full Page Screenshot
# ===================================================================
# Adds POST /api/v1/tabs/{id}/screenshot/full endpoint.
# Uses CDP Page.captureScreenshot with captureBeyondViewport: true
# to capture the entire scrollable page, not just the viewport.
# ===================================================================

# -------------------------------------------------------------------
# 2a: Add ScreenshotFull + helper declarations to abp_controller.h
# -------------------------------------------------------------------
CTRL_HEADER="chrome/browser/abp/abp_controller.h"
if [ -f "${SRC}/${CTRL_HEADER}" ]; then
    python3 << PYEOF
import sys

filepath = "${SRC}/${CTRL_HEADER}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP feature' in content or 'ScreenshotFull' in content:
    print("  SKIP full page screenshot (header) -- already applied")
    sys.exit(0)

# Find the Screenshot method declaration and add ScreenshotFull after it.
for anchor in ['void Screenshot(', 'Screenshot(const std::string& tab_id']:
    if anchor in content:
        idx = content.find(anchor)
        # Find end of this declaration (the closing semicolon + newline)
        semi = content.find(';', idx)
        eol = content.find('\n', semi)

        inject = '''
  // ABP feature: full page screenshot endpoint.
  void ScreenshotFull(const std::string& tab_id,
                      const base::Value::Dict& params,
                      ResponseCallback callback);
  void OnFullPageDimensionsReady(const std::string& tab_id,
                                 int quality,
                                 ResponseCallback callback,
                                 bool success,
                                 const std::string& response);
  void OnFullPageCaptureReady(int width,
                              int height,
                              ResponseCallback callback,
                              bool success,
                              const std::string& response);
'''
        content = content[:eol+1] + inject + content[eol+1:]

        with open(filepath, 'w') as f:
            f.write(content)
        print("  OK   full page screenshot -- header declarations")
        break
else:
    print("  WARN full page screenshot -- Screenshot anchor not found in header")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP full page screenshot (header) -- file not found: ${CTRL_HEADER}"
    SKIPPED=$((SKIPPED + 1))
fi

# -------------------------------------------------------------------
# 2b: Add route + implementation to abp_controller.cc
# -------------------------------------------------------------------
CTRL_IMPL="chrome/browser/abp/abp_controller.cc"
if [ -f "${SRC}/${CTRL_IMPL}" ]; then
    python3 << PYEOF
import sys, re

filepath = "${SRC}/${CTRL_IMPL}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP feature' in content or 'ScreenshotFull' in content:
    print("  SKIP full page screenshot (impl) -- already applied")
    sys.exit(0)

modified = False

# --- Add route for /screenshot/full ---
# The existing route looks like:
#   } else if (action == "screenshot") {
#     if (method == "GET") { BinaryScreenshot(...) }
#     else { Screenshot(...) }
#   }
# We need to check for a sub-path "full" when segments.size() > 5.

# Find the screenshot routing block.
# Use a more specific anchor to avoid matching comments or other contexts.
# The route is: } else if (action == "screenshot") {
for anchor in ['(action == "screenshot")', 'action == "screenshot"']:
    if anchor in content:
        # Find the LAST occurrence — route handlers are near the end of HandleRequest
        idx = content.rfind(anchor)
        # Find the opening brace of this if block
        brace = content.find('{', idx)
        if brace > 0:
            # Insert a check for /full sub-path at the top of the block
            inject = '''
    // ABP feature: full page screenshot at /screenshot/full.
    if (segments.size() > 5 && segments[5] == "full") {
      ScreenshotFull(tab_id, params, std::move(callback));
      return;
    }
'''
            content = content[:brace+1] + inject + content[brace+1:]
            modified = True
            print("  OK   full page screenshot -- route added")
            break
else:
    print("  WARN full page screenshot -- screenshot route anchor not found")

# --- Add ScreenshotFull implementation ---
# Insert at the end of the file, before the last closing brace/namespace.
# Find a good spot: after the existing Screenshot method.

impl_code = '''
// ABP feature: full page screenshot implementation.
// CdpCallback signature: void(bool success, const std::string& json_response)
void AbpController::ScreenshotFull(
    const std::string& tab_id,
    const base::Value::Dict& params,
    ResponseCallback callback) {
  auto tab_it = tab_states_.find(tab_id);
  if (tab_it == tab_states_.end() || !tab_it->second.cdp_client) {
    SendError(404, "Tab not found or no CDP client", std::move(callback));
    return;
  }

  int quality = params.FindInt("quality").value_or(80);

  base::Value::Dict eval_params;
  eval_params.Set("expression",
      "JSON.stringify({"
      "w:Math.max(document.documentElement.scrollWidth||0,"
      "document.body?document.body.scrollWidth:0,1),"
      "h:Math.max(document.documentElement.scrollHeight||0,"
      "document.body?document.body.scrollHeight:0,1)})");
  eval_params.Set("returnByValue", true);

  auto* cdp = tab_it->second.cdp_client.get();
  cdp->SendCommand(
      "Runtime.evaluate", eval_params,
      base::BindOnce(&AbpController::OnFullPageDimensionsReady,
                     weak_factory_.GetWeakPtr(), tab_id,
                     quality, std::move(callback)));
}

void AbpController::OnFullPageDimensionsReady(
    const std::string& tab_id,
    int quality,
    ResponseCallback callback,
    bool success,
    const std::string& response) {
  int width = 1280;
  int height = 800;

  if (success) {
    auto parsed = base::JSONReader::Read(response, base::JSON_PARSE_RFC);
    if (parsed && parsed->is_dict()) {
      const auto* result = parsed->GetDict().FindDict("result");
      if (result) {
        const std::string* value_str = result->FindString("value");
        if (value_str) {
          auto dims_parsed = base::JSONReader::Read(*value_str, base::JSON_PARSE_RFC);
          if (dims_parsed && dims_parsed->is_dict()) {
            width = dims_parsed->GetDict().FindInt("w").value_or(1280);
            height = dims_parsed->GetDict().FindInt("h").value_or(800);
          }
        }
      }
    }
  }

  width = std::min(std::max(width, 1), 4096);
  height = std::min(std::max(height, 1), 16384);
  VLOG(1) << "ABP full page screenshot: " << width << "x" << height;

  auto tab_it = tab_states_.find(tab_id);
  if (tab_it == tab_states_.end() || !tab_it->second.cdp_client) {
    SendError(500, "Tab lost during screenshot", std::move(callback));
    return;
  }

  base::Value::Dict ss_params;
  ss_params.Set("format", "webp");
  ss_params.Set("quality", quality);
  ss_params.Set("captureBeyondViewport", true);
  base::Value::Dict clip;
  clip.Set("x", 0.0);
  clip.Set("y", 0.0);
  clip.Set("width", static_cast<double>(width));
  clip.Set("height", static_cast<double>(height));
  clip.Set("scale", 1.0);
  ss_params.Set("clip", std::move(clip));

  auto* cdp = tab_it->second.cdp_client.get();
  cdp->SendCommand(
      "Page.captureScreenshot", ss_params,
      base::BindOnce(&AbpController::OnFullPageCaptureReady,
                     weak_factory_.GetWeakPtr(), width, height,
                     std::move(callback)));
}

void AbpController::OnFullPageCaptureReady(
    int width,
    int height,
    ResponseCallback callback,
    bool success,
    const std::string& response) {
  if (!success) {
    SendError(500, "Full page screenshot capture failed", std::move(callback));
    return;
  }

  auto parsed = base::JSONReader::Read(response, base::JSON_PARSE_RFC);
  std::string data;
  if (parsed && parsed->is_dict()) {
    const std::string* d = parsed->GetDict().FindString("data");
    if (d) data = *d;
  }

  if (data.empty()) {
    SendError(500, "Full page screenshot returned no data", std::move(callback));
    return;
  }

  base::Value::Dict screenshot;
  screenshot.Set("data", std::move(data));
  screenshot.Set("format", "webp");
  screenshot.Set("width", width);
  screenshot.Set("height", height);
  screenshot.Set("full_page", true);

  base::Value::Dict resp;
  resp.Set("screenshot", std::move(screenshot));
  SendJson(200, base::Value(std::move(resp)), std::move(callback));
}
'''

# Append implementation at end of file (no wrapping namespace to worry about).
content = content.rstrip() + '\n' + impl_code
modified = True
print("  OK   full page screenshot -- implementation appended")

# --- Add #include for JSONReader if not present ---
if '#include "base/json/json_reader.h"' not in content:
    # Find the first #include and add after it
    first_include = content.find('#include')
    if first_include >= 0:
        eol = content.find('\n', first_include)
        content = content[:eol+1] + '#include "base/json/json_reader.h"  // ABP feature\n' + content[eol+1:]
        modified = True
        print("  OK   full page screenshot -- added json_reader include")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
    print("  OK   full page screenshot impl complete")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP full page screenshot (impl) -- file not found: ${CTRL_IMPL}"
    SKIPPED=$((SKIPPED + 1))
fi

echo ""
echo "==> Feature edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
echo ""
echo "Features added:"
echo "  - Bandwidth metering: bytes_received, bytes_sent in every action response"
echo "  - Full page screenshot: POST /api/v1/tabs/{id}/screenshot/full"
