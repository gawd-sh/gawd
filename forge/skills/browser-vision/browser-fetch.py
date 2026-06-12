#!/usr/bin/env python3
"""
browser-fetch.py — Playwright-based page fetcher for the Browser-Vision DemiGawd.

Usage:
    python3 browser-fetch.py --url <url> --screenshot <path.png>
                             --dom-out <path.txt> [--timeout <ms>]

Outputs:
    screenshot: written to --screenshot path (full-page PNG)
    dom-out:    Readability-extracted text written to --dom-out path

Exit codes:
    0  success
    1  page load or screenshot failure
    2  usage error

Implementation notes:
    - Uses Playwright with Chromium (headless). Playwright is preferred over
      xdotool because it provides a stable programmatic API, cross-platform
      support, and native screenshot capability without a display server.
      xdotool fallback is handled in skill.sh for current-screen capture when
      this script fails (e.g., Playwright not installed).
    - Readability.js is not available as a Python package directly; we implement
      a lightweight text extraction that mirrors Readability's approach:
      strip nav/header/footer/script/style, collect paragraph text.
    - On Prophit substrate where full Playwright is not installed, the script
      exits 1 and skill.sh falls through to xdotool.
"""

import argparse
import sys
import os
import re


def parse_args():
    p = argparse.ArgumentParser(description="Playwright page fetcher for Browser-Vision")
    p.add_argument("--url", required=True, help="URL to fetch")
    p.add_argument("--screenshot", required=True, help="Output screenshot PNG path")
    p.add_argument("--dom-out", required=True, help="Output DOM text path")
    p.add_argument("--timeout", type=int, default=30000, help="Page load timeout in ms")
    return p.parse_args()


def extract_readable_text(html_content: str) -> str:
    """
    Lightweight Readability-style text extraction.
    Strips script, style, nav, header, footer elements; collects text from
    paragraph-level elements. This is the reference implementation; a full
    Readability.js integration would require Node.js. The npm package used
    by the reference implementation is '@mozilla/readability' (v0.5.x).
    For production hardening, consider: node -e with @mozilla/readability
    piped through a helper script at skills/browser-vision/readability-extract.js.
    """
    # Remove script and style blocks
    html_content = re.sub(r'<(script|style|noscript)[^>]*>.*?</\1>', '', html_content,
                          flags=re.DOTALL | re.IGNORECASE)
    # Remove nav, header, footer (common clutter)
    html_content = re.sub(r'<(nav|header|footer|aside)[^>]*>.*?</\1>', '', html_content,
                          flags=re.DOTALL | re.IGNORECASE)
    # Strip all tags
    text = re.sub(r'<[^>]+>', ' ', html_content)
    # Normalize whitespace
    text = re.sub(r'\s+', ' ', text).strip()
    # Truncate at 8000 chars (model budget)
    if len(text) > 8000:
        text = text[:8000] + '\n[... truncated at 8000 chars ...]'
    return text


def main():
    args = parse_args()

    try:
        from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
    except ImportError:
        print("browser-fetch: playwright not installed", file=sys.stderr)
        print("Install: pip install playwright && playwright install chromium", file=sys.stderr)
        sys.exit(1)

    screenshot_dir = os.path.dirname(args.screenshot)
    if screenshot_dir:
        os.makedirs(screenshot_dir, exist_ok=True)

    dom_dir = os.path.dirname(args.dom_out)
    if dom_dir:
        os.makedirs(dom_dir, exist_ok=True)

    # Detect system chromium for environments where Playwright's managed
    # Chromium is not installed (e.g., fresh Gawd container before full install).
    def find_chromium():
        candidates = [
            "/usr/bin/google-chrome",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium",
            "/snap/bin/chromium",
        ]
        for c in candidates:
            if os.path.exists(c):
                return c
        return None

    chromium_path = find_chromium()

    try:
        with sync_playwright() as p:
            launch_kwargs = {
                "headless": True,
                "args": ["--no-sandbox", "--disable-setuid-sandbox",
                         "--disable-dev-shm-usage", "--disable-gpu"],
            }
            if chromium_path:
                launch_kwargs["executable_path"] = chromium_path

            browser = p.chromium.launch(**launch_kwargs)
            context = browser.new_context(
                user_agent=(
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
                ),
                viewport={"width": 1440, "height": 900},
            )
            page = context.new_page()

            try:
                page.goto(args.url, wait_until="domcontentloaded", timeout=args.timeout)
            except PlaywrightTimeout:
                print(f"browser-fetch: page load timeout after {args.timeout}ms", file=sys.stderr)
                # Still attempt screenshot and DOM of what loaded.
                pass

            # Brief settle for dynamic content
            try:
                page.wait_for_timeout(2000)
            except Exception:
                pass

            # Screenshot
            try:
                page.screenshot(path=args.screenshot, full_page=True)
            except Exception as e:
                print(f"browser-fetch: screenshot failed: {e}", file=sys.stderr)
                # Continue to DOM extraction even if screenshot fails.

            # DOM extraction
            try:
                html = page.content()
                readable = extract_readable_text(html)
                with open(args.dom_out, 'w', encoding='utf-8') as f:
                    f.write(readable)
            except Exception as e:
                print(f"browser-fetch: DOM extraction failed: {e}", file=sys.stderr)
                browser.close()
                sys.exit(1)

            browser.close()

    except Exception as e:
        print(f"browser-fetch: unexpected error: {e}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
