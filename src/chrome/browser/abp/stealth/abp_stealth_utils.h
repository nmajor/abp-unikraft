// Copyright 2025 anthropic-abp-unikraft contributors
// Use of this source code is governed by a BSD-style license.

#ifndef CHROME_BROWSER_ABP_STEALTH_ABP_STEALTH_UTILS_H_
#define CHROME_BROWSER_ABP_STEALTH_ABP_STEALTH_UTILS_H_

#include <cstdint>
#include <string>

#include "third_party/skia/include/core/SkImageInfo.h"

namespace abp::stealth {

// Returns true if the --abp-fingerprint flag is set.
bool IsStealthEnabled();

// Returns the fingerprint seed from --abp-fingerprint, or 0 if not set.
uint64_t GetFingerprintSeed();

// Returns a deterministic hash combining the global seed with a domain string.
// Example: HashWithDomain("webgl-vendor") returns a stable uint64 for the
// current session that can be used to select from lookup tables.
uint64_t HashWithDomain(const std::string& domain);

// Returns a deterministic float in [0, 1) for the given domain.
double NormalizedHash(const std::string& domain);

// Returns the platform string from --abp-fingerprint-platform, or "windows".
std::string GetFingerprintPlatform();

// Returns the spoofed GPU vendor string, or empty if not set.
std::string GetGpuVendor();

// Returns the spoofed GPU renderer string, or empty if not set.
std::string GetGpuRenderer();

// Returns the spoofed hardware concurrency, or 0 if not set.
int GetHardwareConcurrency();

// Returns the spoofed timezone, or empty if not set.
std::string GetTimezone();

// Apply deterministic subchannel color noise to pixel data.
// This is the Bromite-originated technique: for a small number of
// seed-selected pixels, nudge one non-zero RGB subchannel by +/-1.
// Alpha is never modified. Transparent pixels are skipped.
//
// |data|: pointer to raw pixel buffer (modified in-place)
// |info|: SkImageInfo describing the pixel format
// |rect_x|, |rect_y|: origin offset for deterministic pixel selection
void ShuffleSubchannelColorData(uint8_t* data,
                                const SkImageInfo& info,
                                int rect_x,
                                int rect_y);

}  // namespace abp::stealth

#endif  // CHROME_BROWSER_ABP_STEALTH_ABP_STEALTH_UTILS_H_
