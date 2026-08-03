import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("https://auralis.test/", {
      headers: {
        accept: "text/html",
        host: "auralis.test",
        "x-forwarded-host": "auralis.test",
        "x-forwarded-proto": "https",
      },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the minimal Auralis landing page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Auralis — Native music for macOS<\/title>/i);
  assert.match(html, /Your music\./);
  assert.match(html, /At home on Mac\./);
  assert.match(html, /Download for macOS/);
  assert.match(html, /macOS Tahoe 26 or later/);
  assert.match(html, /Apple silicon \+ supported Intel Macs/);
  assert.doesNotMatch(html, /macOS 14/);
  assert.match(html, /Native SwiftUI/);
  assert.match(html, /Synced lyrics/);
  assert.match(html, /Smart cache/);
  assert.match(html, /class="minimal-player"/);
  assert.match(html, /class="player-topline"/);
  assert.match(html, /class="equalizer"/);
  assert.match(html, /class="player-main"/);
  assert.match(html, /class="lyric-preview"/);
  assert.match(html, /Now playing/);
  assert.match(html, /Synced lyric/);
  assert.match(html, /Let the quiet find you\./);
  assert.match(html, /aria-label="Pause"/);
  assert.match(html, /src="\/brand-mark\.png"/);
  assert.match(html, /src="\/cover-art\.png"/);
  assert.match(html, /https:\/\/github\.com\/crayonlu\/Auralis\/releases\/latest/);
  assert.doesNotMatch(
    html,
    /\/media\/|view-grid|feature-list|menu-preview|codex-preview|SkeletonPreview|react-loading-skeleton/,
  );
});

test("emits product metadata and retains only brand media", async () => {
  const response = await render();
  const html = await response.text();

  assert.match(html, /property="og:image" content="https:\/\/auralis\.test\/og\.png"/);
  assert.match(html, /name="twitter:card" content="summary_large_image"/);
  assert.match(
    html,
    /name="description" content="A quiet, native NetEase Cloud Music player/,
  );

  await Promise.all([
    access(new URL("../public/brand-mark.png", import.meta.url)),
    access(new URL("../public/cover-art.png", import.meta.url)),
    access(new URL("../public/auralis-liquid-background.png", import.meta.url)),
    access(new URL("../public/og.png", import.meta.url)),
  ]);

  const page = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  const styles = await readFile(
    new URL("../app/globals.css", import.meta.url),
    "utf8",
  );
  const packageJson = await readFile(
    new URL("../package.json", import.meta.url),
    "utf8",
  );
  assert.doesNotMatch(page, /next\/image|\/media\//);
  assert.match(styles, /@keyframes card-arrive/);
  assert.match(styles, /@keyframes equalizer-pulse/);
  assert.match(styles, /@keyframes progress-in/);
  assert.match(styles, /prefers-reduced-motion: reduce/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
});
