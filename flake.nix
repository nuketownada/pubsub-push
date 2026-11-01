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
          packages = [ pkgs.gradle androidPkgs.zulu17 androidSdk ];
          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          JAVA_HOME = "${androidPkgs.zulu17}";
          # AGP's aapt2 from Maven is a generic Linux binary; use the SDK's.
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${ANDROID_HOME}/build-tools/${buildToolsVersion}/aapt2";
        };
      };
    };
}
