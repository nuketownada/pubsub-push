# pubsub-push's packages, built from whatever package set they're given (the
# consumer's, through the overlay or the modules' defaults).
pkgs:
rec {
  # Publish a notification to a topic; exits 0 only once accepted.
  pubsub-publish = pkgs.writeShellScriptBin "pubsub-publish" ''
    exec ${pkgs.python3.withPackages (p: [ p.slixmpp ])}/bin/python3 -I ${../tools/pubsub_publish.py} "$@"
  '';

  # Prosody plugin directory: patched mod_unified_push + mod_pubsub_unified_push.
  pubsub-push-prosody-modules = pkgs.runCommand "pubsub-push-prosody-modules" { } ''
    cp -r ${../prosody} $out
  '';

  # nixpkgs' Vencord with the PubsubPush plugin built in. Copied in at
  # preBuild: pnpmDeps inherits postPatch, so its hash stays nixpkgs'.
  vencord-pubsub-push = pkgs.vencord.overrideAttrs (old: {
    preBuild = (old.preBuild or "") + ''
      mkdir -p src/userplugins
      cp -r ${../vencord/pubsubPush} src/userplugins/pubsubPush
    '';
  });

  # Discord (unfree) running that Vencord.
  discord-pubsub-push = pkgs.discord.override {
    withVencord = true;
    vencord = vencord-pubsub-push;
  };
}
