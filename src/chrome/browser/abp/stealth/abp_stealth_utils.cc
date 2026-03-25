// Copyright 2025 anthropic-abp-unikraft contributors
// Use of this source code is governed by a BSD-style license.

#include "chrome/browser/abp/stealth/abp_stealth_utils.h"

#include <functional>

#include "base/command_line.h"
#include "base/strings/string_number_conversions.h"
#include "chrome/browser/abp/stealth/abp_stealth_switches.h"

namespace abp::stealth {

namespace {

uint64_t g_seed_cache = 0;
bool g_seed_initialized = false;

uint64_t GetCachedSeed() {
  if (!g_seed_initialized) {
    auto* cmd = base::CommandLine::ForCurrentProcess();
    std::string seed_str =
        cmd->GetSwitchValueASCII(switches::kAbpFingerprint);
    if (!seed_str.empty()) {
      uint64_t val = 0;
      if (base::StringToUint64(seed_str, &val)) {
        g_seed_cache = val;
      } else {
        // Non-numeric seed: hash the string.
        g_seed_cache = std::hash<std::string>{}(seed_str);
      }
    }
    g_seed_initialized = true;
  }
  return g_seed_cache;
}

}  // namespace

bool IsStealthEnabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(
      switches::kAbpFingerprint);
}

uint64_t GetFingerprintSeed() {
  return GetCachedSeed();
}

uint64_t HashWithDomain(const std::string& domain) {
  uint64_t seed = GetCachedSeed();
  std::string combined =
      std::to_string(seed) + ":" + domain;
  return std::hash<std::string>{}(combined);
}

double NormalizedHash(const std::string& domain) {
  uint64_t h = HashWithDomain(domain);
  return static_cast<double>(h) /
         static_cast<double>(std::numeric_limits<uint64_t>::max());
}

std::string GetFingerprintPlatform() {
  auto* cmd = base::CommandLine::ForCurrentProcess();
  std::string plat =
      cmd->GetSwitchValueASCII(switches::kAbpFingerprintPlatform);
  if (plat.empty())
    plat = "windows";
  return plat;
}

std::string GetGpuVendor() {
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
      switches::kAbpFingerprintGpuVendor);
}

std::string GetGpuRenderer() {
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
      switches::kAbpFingerprintGpuRenderer);
}

int GetHardwareConcurrency() {
  auto* cmd = base::CommandLine::ForCurrentProcess();
  std::string val =
      cmd->GetSwitchValueASCII(switches::kAbpFingerprintHardwareConcurrency);
  int result = 0;
  if (!val.empty())
    base::StringToInt(val, &result);
  return result;
}

std::string GetTimezone() {
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
      switches::kAbpTimezone);
}

void ShuffleSubchannelColorData(uint8_t* data,
                                const SkImageInfo& info,
                                int rect_x,
                                int rect_y) {
  if (!IsStealthEnabled() || !data)
    return;

  const int width = info.width();
  const int height = info.height();
  const int total_pixels = width * height;
  if (total_pixels == 0)
    return;

  // Bytes per pixel for supported color types.
  int bpp = 0;
  int channels = 0;
  int alpha_idx = -1;  // Index of alpha channel, -1 if none.

  switch (info.colorType()) {
    case kRGBA_8888_SkColorType:
    case kSRGBA_8888_SkColorType:
      bpp = 4;
      channels = 4;
      alpha_idx = 3;
      break;
    case kBGRA_8888_SkColorType:
      bpp = 4;
      channels = 4;
      alpha_idx = 3;
      break;
    case kRGB_888x_SkColorType:
      bpp = 4;
      channels = 3;
      alpha_idx = -1;
      break;
    default:
      // Unsupported format — skip noise injection.
      return;
  }

  uint64_t seed = GetFingerprintSeed();

  // Select 2-10 pixels to modify (deterministic per seed + rect origin).
  std::string count_domain =
      "noise-count:" + std::to_string(rect_x) + "," + std::to_string(rect_y);
  uint64_t count_hash = HashWithDomain(count_domain);
  int modify_count = 2 + static_cast<int>(count_hash % 9);  // 2..10

  for (int i = 0; i < modify_count; ++i) {
    // Deterministically select a pixel.
    std::string px_domain =
        "noise-px:" + std::to_string(i) + ":" + std::to_string(rect_x) +
        "," + std::to_string(rect_y);
    uint64_t px_hash = HashWithDomain(px_domain);
    int pixel_idx = static_cast<int>(px_hash % total_pixels);
    uint8_t* pixel = data + pixel_idx * bpp;

    // Skip fully transparent pixels.
    if (alpha_idx >= 0 && pixel[alpha_idx] == 0)
      continue;

    // Select which channel to modify (only non-alpha, non-zero channels).
    std::string ch_domain =
        "noise-ch:" + std::to_string(i) + ":" + std::to_string(rect_x) +
        "," + std::to_string(rect_y);
    uint64_t ch_hash = HashWithDomain(ch_domain);
    int channel = static_cast<int>(ch_hash % channels);

    // Skip alpha channel.
    if (channel == alpha_idx)
      channel = (channel + 1) % channels;

    // Skip zero-value channels to preserve visual appearance.
    if (pixel[channel] == 0)
      continue;

    // Nudge by +1 or -1.
    if (ch_hash & 0x100) {
      if (pixel[channel] < 255)
        pixel[channel]++;
    } else {
      if (pixel[channel] > 1)
        pixel[channel]--;
    }
  }
}

}  // namespace abp::stealth
