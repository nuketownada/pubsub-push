{
  description = "XMPP pubsub topics delivered to phones over UnifiedPush";

  # Pinned for the dev shells and tests (Prosody 13.0.6). Consumers should
  # `inputs.nixpkgs.follows` their own: the overlay and modules build from
  # the consumer's package set either way.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # pubsub-publish, pubsub-push-prosody-modules, vencord-pubsub-push,
      # discord-pubsub-push (unfree), from the consumer's pkgs.
      overlays.default = final: prev: import ./nix/packages.nix final;

      # services.pubsub-push.prosody: the server side, on services.prosody.
      nixosModules.prosody = import ./nix/prosody.nix;
      nixosModules.default = self.nixosModules.prosody;

      # programs.pubsub-push.discord: Discord notifications to a topic.
      homeManagerModules.discord = import ./nix/discord.nix;

      packages = forAllSystems (pkgs:
        let pp = import ./nix/packages.nix pkgs; in {
          inherit (pp) pubsub-publish pubsub-push-prosody-modules vencord-pubsub-push;
          default = pp.pubsub-publish;
          # Test harness Prosody: our modules come from ./prosody
          # (plugin_paths); pubsub_post is only installed, for webhooks.
          prosody = pkgs.prosody.override {
            withOnlyInstalledCommunityModules = [ "pubsub_post" ];
          };
          # Lint separately: its LUA_CPATH would break prosody (Lua 5.2) in a shell.
          luacheck = pkgs.lua52Packages.luacheck;
        });

      devShells = forAllSystems (pkgs: {
        # Tests: nix develop -c bash -c 'cd tests && python -m pytest'
        default = pkgs.mkShell {
          packages = [
            self.packages.${pkgs.stdenv.hostPlatform.system}.prosody
            (pkgs.python3.withPackages (p: [ p.slixmpp p.pytest ]))
          ];
        };
      } // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        # Android app: nix develop .#android -c gradle -p android assembleDebug
        android = import ./nix/android-shell.nix { inherit nixpkgs pkgs; };
      });
    };
}
