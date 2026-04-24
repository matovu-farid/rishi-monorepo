#!/usr/bin/env node
/**
 * Meta-test: Launches the tauri-cypress-runner GUI, polls for debug HTML
 * snapshots saved by the app to /tmp/tauri-cypress-debug/, then uses
 * Playwright to open each HTML file and take a PNG screenshot.
 *
 * Usage:
 *   node meta-test.mjs [--project-dir=../../apps/main]
 */

import { chromium } from "playwright";
import { execFileSync, spawn } from "child_process";
import { existsSync, mkdirSync, rmSync, readdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { tmpdir } from "os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCREENSHOT_DIR = join(__dirname, "meta-screenshots");
const RUNNER_URL = "http://localhost:1421";
const PROJECT_DIR = process.argv.find(a => a.startsWith("--project-dir="))?.split("=")[1] || "../../apps/main";
const RUNNER_BIN = join(__dirname, "src-tauri/target/release/tauri-cypress-runner");
const DEBUG_HTML_DIR = join(tmpdir(), "tauri-cypress-debug");

// --- Helpers ---
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function killPort(port) {
  try { execFileSync("sh", ["-c", `lsof -ti:${port} | xargs kill -9 2>/dev/null`], { stdio: "ignore" }); } catch {}
}

function killProcess(pattern) {
  try { execFileSync("pkill", ["-f", pattern], { stdio: "ignore" }); } catch {}
}

function isProcessRunning(pattern) {
  try { execFileSync("pgrep", ["-f", pattern], { stdio: "ignore" }); return true; } catch { return false; }
}

function cleanup() {
  console.log("[meta] Cleaning up stale processes...");
  killProcess("tauri-cypress-runner");
  killProcess("npx serve");
  killProcess("target/debug/rishi");
  for (const port of [1420, 1421, 9223]) killPort(port);
}

async function waitForUrl(url, timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok) return true;
    } catch {}
    await sleep(500);
  }
  return false;
}

// --- Main ---
async function main() {
  const report = { screenshots: [], checks: [], errors: [], startTime: Date.now() };

  // 1. Clear screenshot folder and debug HTML folder
  if (existsSync(SCREENSHOT_DIR)) rmSync(SCREENSHOT_DIR, { recursive: true });
  mkdirSync(SCREENSHOT_DIR, { recursive: true });
  if (existsSync(DEBUG_HTML_DIR)) rmSync(DEBUG_HTML_DIR, { recursive: true });
  console.log(`[meta] Screenshot dir: ${SCREENSHOT_DIR}`);
  console.log(`[meta] Debug HTML dir: ${DEBUG_HTML_DIR}`);

  // 2. Clean up stale processes
  cleanup();
  await sleep(2000);

  // 3. Launch runner GUI
  console.log(`[meta] Launching runner GUI...`);
  const resolvedProjectDir = join(__dirname, PROJECT_DIR);
  const runner = spawn(RUNNER_BIN, ["open", resolvedProjectDir], {
    stdio: "ignore",
    detached: true,
  });
  runner.unref();

  // 4. Wait for frontend server
  console.log("[meta] Waiting for runner frontend on :1421...");
  const ready = await waitForUrl(RUNNER_URL);
  if (!ready) {
    report.errors.push("Runner frontend did not start within 30s");
    writeReport(report);
    process.exit(1);
  }
  console.log("[meta] Frontend ready");

  // 5. Launch Playwright browser for screenshotting HTML files
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });

  // Also take a live screenshot of the runner URL with mocked Tauri APIs
  const livePage = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  await livePage.addInitScript(() => {
    window.__TAURI_INTERNALS__ = {
      invoke: (cmd) => {
        if (cmd === "get_initial_project_dir") return Promise.resolve(null);
        if (cmd === "get_test_files") return Promise.resolve([]);
        if (cmd === "get_config") return Promise.resolve({});
        if (cmd === "save_debug_html") return Promise.resolve("mocked");
        return Promise.resolve(null);
      },
      transformCallback: () => 0,
    };
  });

  try {
    await livePage.goto(RUNNER_URL, { waitUntil: "networkidle", timeout: 15000 });
    await takeScreenshot(livePage, report, "00-live-runner-ui");
  } catch (e) {
    report.errors.push(`Live page load failed: ${e.message}`);
  }

  // Run UI checks on the live page
  const uiChecks = [
    { name: "title-visible", selector: "text=tauri-cypress" },
    { name: "sidebar-visible", selector: "text=TESTS" },
    { name: "command-log-visible", selector: "text=COMMAND LOG" },
    { name: "dark-background", evaluator: () => {
      const bg = getComputedStyle(document.body).backgroundColor;
      return bg !== "rgb(255, 255, 255)" && bg !== "rgba(0, 0, 0, 0)";
    }},
    { name: "filter-input-visible", selector: "input[placeholder*='Filter']" },
    { name: "status-bar-visible", selector: "text=tauri-cypress v" },
  ];

  for (const check of uiChecks) {
    try {
      let passed = false;
      if (check.selector) {
        passed = await livePage.locator(check.selector).first().isVisible({ timeout: 3000 }).catch(() => false);
      } else if (check.evaluator) {
        passed = await livePage.evaluate(check.evaluator);
      }
      report.checks.push({ name: check.name, passed });
      console.log(`[meta] UI check "${check.name}": ${passed ? "PASS" : "FAIL"}`);
    } catch (e) {
      report.checks.push({ name: check.name, passed: false, error: e.message });
      console.log(`[meta] UI check "${check.name}": ERROR`);
    }
  }

  await livePage.close();

  // 6. Poll for debug HTML files saved by the runner
  console.log("[meta] Polling for debug HTML snapshots...");
  const maxWaitMs = 180000; // 3 minutes
  const startTime = Date.now();
  const seen = new Set();

  while (Date.now() - startTime < maxWaitMs) {
    await sleep(5000);

    if (!isProcessRunning("tauri-cypress-runner")) {
      report.errors.push("Runner process died");
      console.log("[meta] Runner process died!");
      break;
    }

    // Check for new HTML files
    if (existsSync(DEBUG_HTML_DIR)) {
      for (const file of readdirSync(DEBUG_HTML_DIR)) {
        if (file.endsWith('.html') && !seen.has(file)) {
          seen.add(file);
          const htmlPath = join(DEBUG_HTML_DIR, file);
          const pngName = file.replace('.html', '');
          const pngPath = join(SCREENSHOT_DIR, pngName + '.png');

          try {
            await page.goto('file://' + htmlPath, { waitUntil: 'load', timeout: 10000 });
            await sleep(500); // let styles settle
            await page.screenshot({ path: pngPath, fullPage: true });
            report.screenshots.push({ name: pngName, path: pngPath, timestamp: Date.now() });
            console.log(`[meta] Captured: ${file} -> ${pngName}.png`);
          } catch (e) {
            report.errors.push(`Screenshot of ${file} failed: ${e.message}`);
            console.log(`[meta] Failed to screenshot ${file}: ${e.message}`);
          }
        }
      }
    }

    // Stop if we see the "tests-complete" snapshot
    if (seen.has('tests-complete.html')) {
      console.log("[meta] Tests complete snapshot found, finishing...");
      break;
    }

    // Also stop on error snapshots (give some extra time for them)
    const errorSnapshots = ['build-failed.html', 'launch-failed.html', 'connect-failed.html', 'run-error.html'];
    const hasError = errorSnapshots.some(f => seen.has(f));
    if (hasError) {
      console.log("[meta] Error snapshot found, waiting 10s for any additional snapshots...");
      await sleep(10000);
      // Capture any final snapshots
      if (existsSync(DEBUG_HTML_DIR)) {
        for (const file of readdirSync(DEBUG_HTML_DIR)) {
          if (file.endsWith('.html') && !seen.has(file)) {
            seen.add(file);
            const htmlPath = join(DEBUG_HTML_DIR, file);
            const pngName = file.replace('.html', '');
            const pngPath = join(SCREENSHOT_DIR, pngName + '.png');
            try {
              await page.goto('file://' + htmlPath, { waitUntil: 'load', timeout: 10000 });
              await sleep(500);
              await page.screenshot({ path: pngPath, fullPage: true });
              report.screenshots.push({ name: pngName, path: pngPath, timestamp: Date.now() });
              console.log(`[meta] Captured: ${file} -> ${pngName}.png`);
            } catch (e) {
              report.errors.push(`Screenshot of ${file} failed: ${e.message}`);
            }
          }
        }
      }
      break;
    }

    const elapsed = Math.round((Date.now() - startTime) / 1000);
    console.log(`[meta] Waiting... ${elapsed}s elapsed, ${seen.size} snapshots captured so far`);
  }

  if (Date.now() - startTime >= maxWaitMs) {
    report.errors.push("Timed out waiting for test completion (3 min)");
  }

  await browser.close();

  // Write report
  writeReport(report);
  cleanup();
  console.log("[meta] Done.");
}

async function takeScreenshot(page, report, name) {
  const path = join(SCREENSHOT_DIR, `${name}.png`);
  try {
    await page.screenshot({ path, fullPage: true });
    report.screenshots.push({ name, path, timestamp: Date.now() });
    console.log(`[meta] Screenshot: ${name}.png`);
  } catch (e) {
    report.errors.push(`Screenshot ${name} failed: ${e.message}`);
  }
}

function writeReport(report) {
  report.endTime = Date.now();
  report.duration = report.endTime - report.startTime;
  const reportPath = join(SCREENSHOT_DIR, "report.json");
  writeFileSync(reportPath, JSON.stringify(report, null, 2));

  const passedChecks = report.checks.filter(c => c.passed).length;
  const totalChecks = report.checks.length;
  const ssCount = report.screenshots.filter(s => s.path).length;

  console.log(`\n--- META-TEST REPORT ---`);
  console.log(`Duration:    ${(report.duration / 1000).toFixed(1)}s`);
  console.log(`Screenshots: ${ssCount}`);
  console.log(`UI Checks:   ${passedChecks}/${totalChecks} passed`);
  console.log(`Errors:      ${report.errors.length}`);
  if (report.errors.length > 0) {
    report.errors.forEach(e => console.log(`  - ${e}`));
  }
  console.log(`Report:      ${reportPath}`);
}

main().catch(e => {
  console.error("[meta] Fatal:", e);
  cleanup();
  process.exit(1);
});
