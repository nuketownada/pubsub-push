{
  description = "XMPP pubsub topics delivered over UnifiedPush";

  # Same nixpkgs as mynix, so Prosody matches liver's (13.0.6).
  inputs.nixpkgs.url = "github:nixos/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # mod_unified_push and mod_pubsub_unified_push come from ./prosody
      # (plugin_paths); pubsub_post is only installed, for webhook publishing.
      prosody = pkgs.prosody.override {
        withOnlyInstalledCommunityModules = [ "pubsub_post" ];
      };
      python = pkgs.python3.withPackages (p: [ p.slixmpp p.pytest ]);

      # Android app (./android): devShell build, as in rotorflight-configurator.
      # The SDK is unfree; allowed only in this import.
      androidPkgs = import nixpkgs {
        inherit system;
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
    {
      packages.${system} = {
        inherit prosody;
        # Lint separately: its LUA_CPATH would break prosody (Lua 5.2) in the shell.
        luacheck = pkgs.lua52Packages.luacheck;
        # Publisher for machines (kago-notify, signi's forwarders).
        pubsub-publish = pkgs.writeShellScriptBin "pubsub-publish" ''
          exec ${pkgs.python3.withPackages (p: [ p.slixmpp ])}/bin/python3 -I ${./tools/pubsub_publish.py} "$@"
        '';
        prosody-modules = pkgs.runCommand "pubsub-push-prosody-modules" { } ''
          cp -r ${./prosody} $out
        '';
      };

      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [ prosody python ];
        };

        # nix develop .#android -c gradle -p android assembleDebug
        android = pkgs.mkShell rec {
          packages = [ pkgs.gradle androidPkgs.zulu17 androidSdk pkgs.sops restore-signing-key ];
          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          JAVA_HOME = "${androidPkgs.zulu17}";
          # AGP's aapt2 from Maven is a generic Linux binary; use the SDK's.
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${ANDROID_HOME}/build-tools/${buildToolsVersion}/aapt2";
        };
      };
    };
}
