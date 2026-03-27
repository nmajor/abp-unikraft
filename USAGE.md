# ABP Stealth — Browser Service for LLM Agents

A headless Chromium browser running on Unikraft unikernels with ~7ms cold starts, scale-to-zero, and built-in stealth. Control it via REST API.

## What This Is

A single browser instance that:
- **Sleeps when idle** — scales to zero after 5s of inactivity (you only pay for compute during active actions)
- **Wakes in ~7ms** from a memory snapshot with full state preserved (page, tabs, scroll position, cookies)
- **Freezes JavaScript between actions** — timers, animations, and `Date.now()` pause between your API calls, giving you deterministic atomic steps
- **Passes bot detection** — C++ level stealth patches (not JS injection), no "HeadlessChrome" in UA, `navigator.webdriver === false`

## Quick Start

The instance is running at:
```
https://<instance-fqdn>.fra.unikraft.app
```

Every endpoint returns JSON. Every action that touches the page returns `screenshot_before`, `screenshot_after` (WebP base64), `profiling` (timing), and `events` (navigation, dialogs, etc).

### 1. Check it's alive
```bash
GET /api/v1/browser/status
# → {"ready": true, ...}
```

### 2. Get a tab
```bash
GET /api/v1/tabs
# → [{"id": "ABC123...", "url": "about:blank", "title": "", "active": true}]
```

### 3. Navigate
```bash
POST /api/v1/tabs/{id}/navigate
{"url": "https://example.com"}
# → {result: {url, title}, events: [...], screenshot_after: {...}, profiling: {total_ms}}
```

### 4. Read the page
```bash
# Full body text
POST /api/v1/tabs/{id}/text
{}
# → {"text": "Example Domain\nThis domain is for..."}

# Or target a specific element
POST /api/v1/tabs/{id}/text
{"selector": "#main-content"}

# Or run arbitrary JS
POST /api/v1/tabs/{id}/execute
{"script": "document.title"}
# → {"result": {"value": "Example Domain"}, "virtual_time": {"paused": true}}
```

### 5. Interact
```bash
# Click (coordinates in CSS pixels)
POST /api/v1/tabs/{id}/click
{"x": 300, "y": 200}

# Type (click an input first to focus it)
POST /api/v1/tabs/{id}/type
{"text": "search query"}

# Press a key
POST /api/v1/tabs/{id}/keyboard/press
{"key": "Enter"}

# Scroll
POST /api/v1/tabs/{id}/scroll
{"x": 640, "y": 400, "scrolls": [{"delta_px": 300, "direction": "y"}]}
```

### 6. Screenshot
```bash
POST /api/v1/tabs/{id}/screenshot
{}
# → {"screenshot_after": {"data": "<base64>", "format": "webp", "width": 1280, "height": 713}}
```

### 7. Tabs
```bash
# Open a new tab
POST /api/v1/tabs
{"url": "https://example.com"}

# Close a tab
DELETE /api/v1/tabs/{id}

# Switch tab
POST /api/v1/tabs/{id}/activate
```

## How the Pause Mechanism Works

This is the key thing that makes ABP different from Puppeteer/Playwright:

1. You send an action (navigate, click, type, etc.)
2. ABP **unfreezes** JavaScript and virtual time
3. ABP executes your action
4. ABP **waits** for network requests to settle (~1-2s)
5. ABP **freezes** JavaScript and virtual time again
6. ABP takes a screenshot and returns the response

Between your API calls, the page is completely frozen. No timers fire, no animations run, `Date.now()` doesn't advance. This means:
- You always see a consistent DOM state
- You can take as long as you want between actions (minutes, hours) without the page changing
- Race conditions between your agent's observations and actions are eliminated

Combined with Unikraft's scale-to-zero: when you're not making API calls, the entire VM is suspended. Your agent can think for 30 seconds between actions and pay nothing for that time.

## Tips

**Finding click targets:** Use JS to get element coordinates:
```bash
POST /api/v1/tabs/{id}/execute
{"script": "const r = document.querySelector('button.submit').getBoundingClientRect(); JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2})"}
```

**Waiting for dynamic content:** ABP's built-in wait handles most cases. For JS-heavy SPAs, add an explicit wait:
```bash
POST /api/v1/tabs/{id}/wait
{"ms": 2000}
```

**Error handling:** If navigation fails or a selector doesn't match, the response will contain an `error` field.

**Multiple tabs:** You can have multiple tabs open simultaneously. Each tab has independent state and virtual time.

## Full Endpoint Reference

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/v1/browser/status` | Browser readiness |
| POST | `/api/v1/browser/shutdown` | Graceful shutdown |
| GET | `/api/v1/tabs` | List all tabs |
| POST | `/api/v1/tabs` | Create new tab |
| GET | `/api/v1/tabs/{id}` | Get tab info |
| DELETE | `/api/v1/tabs/{id}` | Close tab |
| POST | `/api/v1/tabs/{id}/activate` | Switch to tab |
| POST | `/api/v1/tabs/{id}/navigate` | Go to URL |
| POST | `/api/v1/tabs/{id}/back` | History back |
| POST | `/api/v1/tabs/{id}/forward` | History forward |
| POST | `/api/v1/tabs/{id}/reload` | Reload page |
| POST | `/api/v1/tabs/{id}/click` | Click at x,y |
| POST | `/api/v1/tabs/{id}/type` | Type text |
| POST | `/api/v1/tabs/{id}/keyboard/press` | Key press |
| POST | `/api/v1/tabs/{id}/scroll` | Scroll page |
| POST | `/api/v1/tabs/{id}/screenshot` | Capture screenshot |
| POST | `/api/v1/tabs/{id}/execute` | Run JavaScript |
| POST | `/api/v1/tabs/{id}/text` | Get page text |
| POST | `/api/v1/tabs/{id}/wait` | Wait N milliseconds |
| GET | `/api/v1/tabs/{id}/dialog` | Check for alert/confirm |
| POST | `/api/v1/tabs/{id}/dialog/accept` | Accept dialog |
| POST | `/api/v1/tabs/{id}/dialog/dismiss` | Dismiss dialog |
| GET | `/api/v1/downloads` | List downloads |
| GET | `/api/v1/permissions` | Pending permission requests |
| GET | `/api/v1/history/sessions` | Session history |
