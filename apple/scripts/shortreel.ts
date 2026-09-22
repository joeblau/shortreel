#!/usr/bin/env bun
// Builds ShortReel.app in Release, installs it to /Applications, and launches it.
import { $ } from "bun";
import { existsSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const derivedData = `${root}.build/DerivedData`;
const builtApp = `${derivedData}/Build/Products/Release/ShortReel.app`;
const installedApp = "/Applications/ShortReel.app";

$.cwd(root);

// go-ios provides the `ios` CLI the runner uses to talk to USB phones. It is
// published on npm with prebuilt binaries in `dist/` and relies on an npm
// postinstall to copy one onto PATH; Bun skips that, so place it ourselves.
if ((await $`which ios`.quiet().nothrow()).exitCode !== 0) {
  console.log("→ Installing go-ios");
  const install = await $`bun install -g go-ios`.quiet().nothrow();
  if (install.exitCode !== 0) {
    console.error("go-ios did not install; continuing without it:\n" + install.stderr.toString().trim());
  } else {
    const globalBin = (await $`bun pm bin -g`.quiet().text()).trim();
    const globalModules = `${globalBin}/../install/global/node_modules`;
    const arch = process.arch === "arm64" ? "arm64" : "amd64";
    const binary = `${globalModules}/go-ios/dist/go-ios-darwin-${arch}_darwin_${arch}/ios`;
    if (existsSync(binary)) {
      await $`install -m 755 ${binary} ${globalBin}/ios`.quiet();
      if ((await $`which ios`.quiet().nothrow()).exitCode !== 0) {
        console.error(`go-ios installed to ${globalBin}, which is not on PATH; add it to use the ios CLI.`);
      }
    } else {
      console.error(`go-ios installed but no darwin/${arch} binary was found under ${globalModules}/go-ios/dist.`);
    }
  }
}

// The optional local UI-TARS planner needs llama.cpp. Codex and Claude use their own CLIs.
if (process.env.SHORTREEL_INSTALL_UITARS === "1" && (await $`which llama-server`.quiet().nothrow()).exitCode !== 0) {
  if ((await $`which brew`.quiet().nothrow()).exitCode === 0) {
    console.log("→ Installing llama.cpp with Homebrew");
    const install = await $`brew install llama.cpp`.quiet().nothrow();
    if (install.exitCode !== 0) {
      console.error("llama.cpp did not install; the UI-TARS planner will be unavailable until it does:\n" + install.stderr.toString().trim());
    }
  } else {
    console.log("→ llama.cpp is not installed and Homebrew is unavailable; install llama.cpp to use the UI-TARS planner.");
  }
}

if (existsSync(`${root}project.yml`) && (await $`which xcodegen`.quiet().nothrow()).exitCode === 0) {
  console.log("→ Regenerating Xcode project");
  await $`xcodegen generate`.quiet();
}

console.log("→ Building ShortReel (Release)");
const build = await $`xcodebuild -project ShortReel.xcodeproj -scheme ShortReel -configuration Release -destination platform=macOS -derivedDataPath ${derivedData} build`
  .quiet()
  .nothrow();
if (build.exitCode !== 0) {
  const output = build.stdout.toString() + build.stderr.toString();
  console.error(output);
  process.exit(build.exitCode);
}

if (!existsSync(builtApp)) {
  console.error(`Build finished but ${builtApp} is missing`);
  process.exit(1);
}

// Bluetooth + USB capture is the default and needs no Developer Mode.
// Only include on-device runners when explicitly requested for this build.
const runnerProducts = `${root}.build/runner/Build/Products/Debug-iphoneos`;
const runnerNames = ["ShortReelRunner.app", "ShortReelRunnerUITests-Runner.app"];
const runnerDestination = `${builtApp}/Contents/Resources/PhoneRunner`;
await $`rm -rf ${runnerDestination}`.quiet();
if (process.env.SHORTREEL_INCLUDE_RUNNER === "1") {
  if (!runnerNames.every(name => existsSync(`${runnerProducts}/${name}/embedded.mobileprovision`))) {
    console.error("Build the signed runners first from the repository root: SHORTREEL_DEVELOPMENT_TEAM=<team> bun run runner");
    process.exit(1);
  }
  for (const name of runnerNames) {
    await $`codesign --verify --deep --strict ${runnerProducts}/${name}`.quiet();
    await $`ditto ${runnerProducts}/${name} ${runnerDestination}/${name}`.quiet();
  }
  console.log("→ Bundled signed iPhone runners");
} else {
  console.log("→ Bluetooth control with USB screenshots (no iPhone runner or Developer Mode required)");
}

// Give local builds a stable identity so macOS can retain the user's
// Bluetooth and camera permissions when the executable changes.
let signingIdentity = process.env.SHORTREEL_CODE_SIGN_IDENTITY;
if (!signingIdentity) {
  const identities = await $`security find-identity -v -p codesigning`.quiet().nothrow();
  signingIdentity = identities.stdout.toString().match(
    /\b([A-Fa-f0-9]{40})\s+"Apple Development:[^"]+"/
  )?.[1];
}
if (signingIdentity) {
  console.log("→ Signing ShortReel with the local development identity");
  await $`codesign --force --sign ${signingIdentity} ${builtApp}`.quiet();
  await $`codesign --verify --strict ${builtApp}`.quiet();
} else {
  console.log("→ No development signing identity found; macOS may request permissions again after updates.");
}

console.log("→ Quitting any running ShortReel");
if ((await $`pgrep -x ShortReel`.quiet().nothrow()).exitCode === 0) {
  // Normal Quit lets the app stop its XCTest sessions and port forwards.
  await $`osascript -e 'tell application "ShortReel" to quit'`.quiet();
}
// Wait for termination before replacing the bundle; Launch Services can
// otherwise try to reopen the exiting process and return -600 or -609.
const quitDeadline = Date.now() + 10_000;
while ((await $`pgrep -x ShortReel`.quiet().nothrow()).exitCode === 0) {
  if (Date.now() >= quitDeadline) {
    console.error("ShortReel did not quit; leaving the installed app in place.");
    process.exit(1);
  }
  await Bun.sleep(200);
}

console.log(`→ Installing to ${installedApp}`);
await $`rm -rf ${installedApp}`;
await $`ditto ${builtApp} ${installedApp}`;

console.log("→ Launching ShortReel");
for (let attempt = 0; attempt < 3; attempt++) {
  const launch = await $`open ${installedApp}`.quiet().nothrow();
  if (launch.exitCode === 0) break;
  if (attempt === 2 || !/error -(600|609)\b/.test(launch.stderr.toString())) {
    console.error(launch.stderr.toString());
    process.exit(launch.exitCode);
  }
  await Bun.sleep(1_000);
}
console.log("✓ ShortReel is running from /Applications");
