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
    in
    {
      packages.${system} = {
        inherit prosody;
        # Lint separately: its LUA_CPATH would break prosody (Lua 5.2) in the shell.
        luacheck = pkgs.lua52Packages.luacheck;
        prosody-modules = pkgs.runCommand "pubsub-push-prosody-modules" { } ''
          cp -r ${./prosody} $out
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ prosody python ];
      };
    };
}
