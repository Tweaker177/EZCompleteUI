# EZCompleteUI — AI Helpers Package

Three files to drop into your existing Xcode project.

---

## Files Included

| File | Purpose |
|------|---------|
| `helpers.h` | All function declarations — import this in ViewController.m |
| `helpers.m` | Full implementation — add to your Xcode target |
| `ViewController_integration_patch.m` | Step-by-step guide for wiring into your existing ViewController.m |

---

## Mini-Apps / Helper Functions

### 1. 📝 Robust Logging (`EZLog`)
No AI involved — pure file I/O.
- Writes timestamped entries to `Documents/ezui_helpers.log`
- Four levels: DEBUG / INFO / WARN / ERROR
- Auto-rotation via `EZLogRotateIfNeeded(512 * 1024)`
- Use the `EZLogf()` macro for printf-style formatting

### 2. 🧠 Prompt Context Analyzer (`analyzePromptForContext`)
Uses **gpt-4.1-nano** (cheapest model).  
Called *before* sending to the main model. Classifies the prompt as SIMPLE or COMPLEX:
- SIMPLE → prompt sent as-is (no tokens wasted on memory context)
- COMPLEX → recent memory entries are prepended to the prompt automatically

### 3. 💾 Memory Creator (`createMemoryFromCompletion`)
Uses **gpt-4.1-nano**.  
Called *after* each successful completion. Summarizes the Q&A pair in ≤80 words and appends it to `Documents/ezui_memory.log`.

### 4. 📂 Memory Loader (`loadMemoryContext`)
No AI — synchronous file read.  
Returns the N most recent memory entries as a single string for use as context.

### 5. 📊 Helper Stats (`EZHelperStats`)
No AI — parses the log files.  
Returns a formatted stats report: log entry counts by level, context injection rate, memory count, and recent log tail.

---

## Quick Start

### In Xcode
1. Drag `helpers.h` and `helpers.m` into your project.
2. Make sure `helpers.m` is in your app's **Compile Sources** build phase.
3. Add `#import "helpers.h"` at the top of `ViewController.m`.
4. Follow `ViewController_integration_patch.m` for the 6-step wiring guide.

### Model used for AI helpers
All AI helpers use `gpt-4.1-nano` — the cheapest OpenAI model. You can change the model by editing `kEZHelperModel` in `helpers.m`.

### Log file locations (on device)
```
Documents/ezui_helpers.log   — all helper activity logs
Documents/ezui_memory.log    — conversation memory summaries
```
Access via Files app or iTunes File Sharing if enabled.

---

## Token Economy

| Scenario | Main Model Tokens | Helper Tokens |
|----------|-----------------|---------------|
| Simple "Hello" | Prompt only | ~50 (classifier) |
| Complex coding Q | Prompt + memories | ~50 (classifier) + ~80 (memory writer) |

Helper calls are intentionally cheap — typically 50–150 tokens each on nano.
