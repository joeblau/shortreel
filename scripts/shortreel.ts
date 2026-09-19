#!/usr/bin/env bun
// Builds ShortReel.app in Release, installs it to /Applications, and launches it.
import { $ } from "bun";
import { existsSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const derivedData = `${root}.build/DerivedData`;
const builtApp = `${derivedData}/Build/Products/Release/ShortReel.app`;
const installedApp = "/Applications/ShortReel.app";

$.cwd(root);

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
  console.error(output.split("\n").filter((line) => /error:|BUILD FAILED/.test(line)).join("\n") || output);
  process.exit(build.exitCode);
}

if (!existsSync(builtApp)) {
  console.error(`Build finished but ${builtApp} is missing`);
  process.exit(1);
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
await $`pkill -x ShortReel`.quiet().nothrow();
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
