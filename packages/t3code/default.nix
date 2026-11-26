# T3 Code 0.1.12 (nixpkgs still has 0.1.8) with two upstream PRs carried as source patches (Joan, 2026-11-26):
# - #36029: an idle Claude thread wakes when its background command finishes (T3 closed the Claude process between
#   Claude's task_notification and the wake turn it starts, so the wake was dropped).
# - #25930: a fixed-time scheduled task can run a missed slot once when T3 is back (`missedRun: "run_once"` on its
#   schedule); without it a slot missed by more than 10 minutes (laptop asleep) is skipped.
# Built from source like nixpkgs' own package (its derivation, with src, pnpm deps and the resource monitor's crates
# re-pinned to 0.1.12). Each patch is the PR's diff at a fixed head, adapted for this build: the header of each patch
# file says what changed from upstream and why, so it's clear when upstream's released version can replace it. A patch
# that no longer applies fails the build. Drop a patch as soon as a T3 release includes its PR, and this whole file once
# nixpkgs packages a release that has both.
#
# The Files panel's white-flash patch (0.1.8) is gone: 0.1.12 fixed it upstream (#37072, #37950).
{
  lib,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpm_12,
  rustPlatform,
  t3code,
}:

let
  # nixpkgs' T3 this overrides. When nixpkgs moves, this fails: check whether its release has the PRs (then drop the
  # patches, or this file), or re-pin.
  nixpkgsVersion = "0.1.8";
  version = "0.1.12";

  unwrapped = t3code.unwrapped.overrideAttrs (
    finalAttrs: old: {
      inherit version;
      src = fetchFromGitHub {
        owner = "pingdotgg";
        repo = "t3code";
        tag = "v${version}";
        hash = "sha256-BeeKQGuTSeOejhzIFzpFLhVjuVRIc7eToWzGrHGNJqc=";
      };
      patches = (old.patches or [ ]) ++ [
        ./pr-36029-claude-background-wake.patch
        ./pr-25930-missed-run-once.patch
      ];
      # The patches don't touch the lockfile, so the deps are 0.1.12's.
      pnpmDeps = fetchPnpmDeps {
        pnpm = pnpm_12;
        inherit (finalAttrs)
          pname
          version
          src
          pnpmWorkspaces
          ;
        fetcherVersion = 5;
        hash = "sha256-5ncmrXOIU3sxrB6XaauC/6PPL4YyHaUO62ST1y1O2B8=";
      };
    }
  );

  # nixpkgs' resource-monitor.nix, with 0.1.12's crates.
  resourceMonitor = rustPlatform.buildRustPackage {
    pname = "t3code-resource-monitor";
    inherit (unwrapped) version src;
    sourceRoot = "${unwrapped.src.name}/native/resource-monitor";
    cargoHash = "sha256-deTy3FFcOwhxZnEbWDXFGVFFoKUex434ADJQtchVzbs=";
    meta = t3code.resourceMonitor.meta;
  };
in
assert lib.assertMsg (t3code.unwrapped.version == nixpkgsVersion)
  "packages/t3code overrides nixpkgs' T3 ${nixpkgsVersion}, but nixpkgs now has ${t3code.unwrapped.version}: check whether it includes PRs #36029 and #25930 (then drop the patches or this file), or re-pin";
t3code.override {
  t3code-unwrapped = unwrapped;
  t3code-resource-monitor = resourceMonitor;
}
