#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/shortreel-transactions.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
sources=(SemanticIf/Sources/SemanticIf/{SemanticIfPrompt,SemanticIfScoring}.swift
  ShortReel/Services/DevicePrompts/{WarmUpScript,PhonePlaybackTracker,PhoneSubmissionGuard,PhoneSubmissionCheckpoint,DevicePromptPlan,DevicePromptPlanner,DeviceWorkflow,PhoneVisionTypes,PhoneTransaction,PhoneVisualRunner,WarmUpStateTree,WarmUpAccountClassifier,WarmUpFailureClassifier,DeviceRunJournal,DevicePromptSession,HomeScreenRemovalGuard}.swift
  ShortReel/Services/DevicePrompts/PhoneWatchChecks.swift Tests/TransactionTestSupport.swift)
suites=(PhoneVisualRunnerTests PhoneWatchFlowTests DevicePromptSessionTests DeviceWorkflowTests)
if (( $# )); then suites=("$@"); fi
for suite in "${suites[@]}"; do
  swiftc -swift-version 6 "${sources[@]}" "Tests/$suite.swift" -o "$build_dir/$suite"
  "$build_dir/$suite"
done
