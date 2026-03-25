// Copyright 2025 anthropic-abp-unikraft contributors
// Use of this source code is governed by a BSD-style license.
//
// Static data tables for fingerprint spoofing. GPU models, font lists, and
// platform strings are sourced from real-world browser population data.

#ifndef CHROME_BROWSER_ABP_STEALTH_ABP_FINGERPRINT_DATA_H_
#define CHROME_BROWSER_ABP_STEALTH_ABP_FINGERPRINT_DATA_H_

#include <string>
#include <vector>

namespace abp::stealth::data {

// =========================================================================
// GPU Models — ANGLE (Direct3D11) format strings for Windows
// =========================================================================

struct GpuModel {
  const char* vendor;
  const char* renderer;
};

// Common consumer GPUs seen in real Chrome browser populations.
// Format matches what ANGLE reports on Windows with D3D11 backend.
inline const GpuModel kWindowsGpuModels[] = {
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 3070 Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 3080 Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 4070 Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce GTX 1660 SUPER Direct3D11 vs_5_0 "
     "ps_5_0, D3D11)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce GTX 1080 Ti Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (AMD)",
     "ANGLE (AMD, AMD Radeon RX 6700 XT Direct3D11 vs_5_0 ps_5_0, D3D11)"},
    {"Google Inc. (AMD)",
     "ANGLE (AMD, AMD Radeon RX 6800 XT Direct3D11 vs_5_0 ps_5_0, D3D11)"},
    {"Google Inc. (Intel)",
     "ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0, "
     "D3D11)"},
    {"Google Inc. (Intel)",
     "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 "
     "ps_5_0, D3D11)"},
};

inline constexpr size_t kWindowsGpuModelCount =
    sizeof(kWindowsGpuModels) / sizeof(kWindowsGpuModels[0]);

// macOS GPU models (Metal backend).
inline const GpuModel kMacGpuModels[] = {
    {"Google Inc. (Apple)", "ANGLE (Apple, Apple M1, OpenGL 4.1)"},
    {"Google Inc. (Apple)", "ANGLE (Apple, Apple M1 Pro, OpenGL 4.1)"},
    {"Google Inc. (Apple)", "ANGLE (Apple, Apple M2, OpenGL 4.1)"},
    {"Google Inc. (Apple)", "ANGLE (Apple, Apple M2 Pro, OpenGL 4.1)"},
    {"Google Inc. (Apple)", "ANGLE (Apple, Apple M3, OpenGL 4.1)"},
    {"Google Inc. (Apple)", "ANGLE (Apple, Apple M3 Pro, OpenGL 4.1)"},
};

inline constexpr size_t kMacGpuModelCount =
    sizeof(kMacGpuModels) / sizeof(kMacGpuModels[0]);

// Linux GPU models (OpenGL backend).
inline const GpuModel kLinuxGpuModels[] = {
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060/PCIe/SSE2, OpenGL 4.5.0)"},
    {"Google Inc. (NVIDIA)",
     "ANGLE (NVIDIA, NVIDIA GeForce RTX 3070/PCIe/SSE2, OpenGL 4.5.0)"},
    {"Google Inc. (AMD)",
     "ANGLE (AMD, AMD Radeon RX 6700 XT (radeonsi, navi22, LLVM 15.0.7, "
     "DRM 3.49, 6.1.0), OpenGL 4.6)"},
    {"Google Inc. (Intel)",
     "ANGLE (Intel, Mesa Intel(R) UHD Graphics 630 (CFL GT2), OpenGL 4.6)"},
};

inline constexpr size_t kLinuxGpuModelCount =
    sizeof(kLinuxGpuModels) / sizeof(kLinuxGpuModels[0]);

// =========================================================================
// Platform User-Agent fragments
// =========================================================================

struct PlatformUA {
  const char* os_info;         // e.g., "Windows NT 10.0; Win64; x64"
  const char* platform;        // navigator.platform
  const char* platform_ua;     // navigator.userAgentData.platform
};

inline const PlatformUA kWindowsUA = {
    "Windows NT 10.0; Win64; x64", "Win32", "Windows"};
inline const PlatformUA kMacUA = {
    "Macintosh; Intel Mac OS X 10_15_7", "MacIntel", "macOS"};
inline const PlatformUA kLinuxUA = {
    "X11; Linux x86_64", "Linux x86_64", "Linux"};

// =========================================================================
// Hardware concurrency values (common consumer machines)
// =========================================================================

inline const int kHardwareConcurrencies[] = {4, 6, 8, 10, 12, 16};
inline constexpr size_t kHardwareConcurrencyCount =
    sizeof(kHardwareConcurrencies) / sizeof(kHardwareConcurrencies[0]);

// =========================================================================
// Platform font lists (the fonts navigator APIs should enumerate)
// =========================================================================

// Windows 10/11 default fonts.
inline const char* const kWindowsFonts[] = {
    "Arial",
    "Arial Black",
    "Calibri",
    "Cambria",
    "Cambria Math",
    "Candara",
    "Comic Sans MS",
    "Consolas",
    "Constantia",
    "Corbel",
    "Courier New",
    "Georgia",
    "Impact",
    "Lucida Console",
    "Lucida Sans Unicode",
    "Microsoft Sans Serif",
    "Palatino Linotype",
    "Segoe Print",
    "Segoe Script",
    "Segoe UI",
    "Segoe UI Symbol",
    "Tahoma",
    "Times New Roman",
    "Trebuchet MS",
    "Verdana",
    "Webdings",
    "Wingdings",
};
inline constexpr size_t kWindowsFontCount =
    sizeof(kWindowsFonts) / sizeof(kWindowsFonts[0]);

// macOS default fonts.
inline const char* const kMacFonts[] = {
    "American Typewriter",
    "Apple Color Emoji",
    "Arial",
    "Arial Black",
    "Avenir",
    "Avenir Next",
    "Baskerville",
    "Courier",
    "Courier New",
    "Futura",
    "Geneva",
    "Georgia",
    "Helvetica",
    "Helvetica Neue",
    "Lucida Grande",
    "Menlo",
    "Monaco",
    "Optima",
    "Palatino",
    "San Francisco",
    "SF Pro",
    "Times",
    "Times New Roman",
    "Trebuchet MS",
    "Verdana",
};
inline constexpr size_t kMacFontCount =
    sizeof(kMacFonts) / sizeof(kMacFonts[0]);

// =========================================================================
// Window decoration offsets (toolbar + borders)
// =========================================================================

struct WindowChrome {
  int top;     // Height of title bar + toolbar + tab strip.
  int bottom;  // Bottom window border.
  int left;    // Left window border.
  int right;   // Right window border.
};

inline const WindowChrome kWindowsChrome = {87, 8, 8, 8};
inline const WindowChrome kMacChrome = {56, 0, 0, 0};
inline const WindowChrome kLinuxChrome = {72, 0, 0, 0};

}  // namespace abp::stealth::data

#endif  // CHROME_BROWSER_ABP_STEALTH_ABP_FINGERPRINT_DATA_H_
