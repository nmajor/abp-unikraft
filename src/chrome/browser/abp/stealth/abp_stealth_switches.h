// Copyright 2025 anthropic-abp-unikraft contributors
// Use of this source code is governed by a BSD-style license.

#ifndef CHROME_BROWSER_ABP_STEALTH_ABP_STEALTH_SWITCHES_H_
#define CHROME_BROWSER_ABP_STEALTH_ABP_STEALTH_SWITCHES_H_

namespace abp::stealth::switches {

// Master stealth switch. When set, enables all fingerprint spoofing.
// The value is an integer seed for deterministic randomization.
// Example: --abp-fingerprint=42
extern const char kAbpFingerprint[];

// Spoof the platform reported by navigator.platform, navigator.userAgentData,
// and the User-Agent string. Values: "windows", "macos", "linux".
// Default: "windows"
extern const char kAbpFingerprintPlatform[];

// Override the WebGL UNMASKED_VENDOR_WEBGL string.
// Example: --abp-fingerprint-gpu-vendor="Google Inc. (NVIDIA)"
extern const char kAbpFingerprintGpuVendor[];

// Override the WebGL UNMASKED_RENDERER_WEBGL string.
// Example: --abp-fingerprint-gpu-renderer="ANGLE (NVIDIA, NVIDIA GeForce RTX
// 3070 Direct3D11 vs_5_0 ps_5_0, D3D11)"
extern const char kAbpFingerprintGpuRenderer[];

// Override navigator.hardwareConcurrency.
// Default: selected from seed.
extern const char kAbpFingerprintHardwareConcurrency[];

// Override the IANA timezone identifier.
// Example: --abp-timezone="America/New_York"
extern const char kAbpTimezone[];

}  // namespace abp::stealth::switches

#endif  // CHROME_BROWSER_ABP_STEALTH_ABP_STEALTH_SWITCHES_H_
