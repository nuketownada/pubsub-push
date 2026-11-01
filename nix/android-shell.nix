# Dev shell for ./android: devShell build, as in rotorflight-configurator.
{ nixpkgs, pkgs }:
let
  # The SDK is unfree; allowed only in this import.
  androidPkgs = import nixpkgs {
    system = pkgs.stdenv.hostPlatform.system;
    config = { allowUnfree = true; android_sdk.accept_license = true; };
  };
  buildToolsVersion = "35.0.0"; # AGP 8.13's default
  androidSdk = (androidPkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ buildToolsVersion ];
    includeEmulator = false;
    includeSystemImages = false;
    includeNDK = false;
  }).androidsdk;

  # Signing key from secrets/signing.yaml (sops: josh, ada) into
  # android/signing/, so any clone builds APKs that update the installed
  # app. Never replaces a different existing key.
  restore-signing-key = pkgs.writeShellApplication {
    name = "restore-signing-key";
    runtimeInputs = [ pkgs.sops pkgs.coreutils pkgs.git ];
    text = ''
      root=$(git rev-parse --show-toplevel)
      dest=$root/android/signing/pubsub-push.keystore
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      sops -d --extract '["android"]["keystore"]' "$root/secrets/signing.yaml" | base64 -d > "$tmp"
      if [ -e "$dest" ]; then
        if cmp -s "$tmp" "$dest"; then echo "$dest already matches"; exit 0; fi
        echo "$dest exists and differs; not replacing it" >&2; exit 1
      fi
      mkdir -p "$(dirname "$dest")"
      install -m 600 "$tmp" "$dest"
      echo "restored $dest"
    '';
  };
in
pkgs.mkShell rec {
  packages = [ pkgs.gradle androidPkgs.zulu17 androidSdk pkgs.sops restore-signing-key ];
  ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
  JAVA_HOME = "${androidPkgs.zulu17}";
  # AGP's aapt2 from Maven is a generic Linux binary; use the SDK's.
  GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${ANDROID_HOME}/build-tools/${buildToolsVersion}/aapt2";
}
