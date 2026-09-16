#!/usr/bin/env bun
// Builds Engage.app in Release, installs it to /Applications, and launches it.
import { $ } from "bun";
import { existsSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const derivedData = `${root}.build/DerivedData`;
const builtApp = `${derivedData}/Build/Products/Release/Engage.app`;
const installedApp = "/Applications/Engage.app";

$.cwd(root);

if (existsSync(`${root}project.yml`) && (await $`which xcodegen`.quiet().nothrow()).exitCode === 0) {
  console.log("→ Regenerating Xcode project");
  await $`xcodegen generate`.quiet();
}

console.log("→ Building Engage (Release)");
const build = await $`xcodebuild -project Engage.xcodeproj -scheme Engage -configuration Release -destination platform=macOS -derivedDataPath ${derivedData} build`
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

console.log("→ Quitting any running Engage");
await $`pkill -x Engage`.quiet().nothrow();

console.log(`→ Installing to ${installedApp}`);
await $`rm -rf ${installedApp}`;
await $`ditto ${builtApp} ${installedApp}`;

console.log("→ Launching Engage");
await $`open ${installedApp}`;
console.log("✓ Engage is running from /Applications");
