# programs.pubsub-push.discord (home-manager): Discord with Vencord and the
# PubsubPush plugin, forwarding the notifications Discord would show to a
# topic, with links to the message. See ../README.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.pubsub-push.discord;
  pp = import ./packages.nix pkgs;
  inherit (lib) mkOption types;
in
{
  options.programs.pubsub-push.discord = {
    enable = lib.mkEnableOption "Discord notifications forwarded to a pubsub-push topic";

    package = mkOption {
      type = types.package;
      default = pp.discord-pubsub-push;
      defaultText = lib.literalExpression "discord-pubsub-push";
      description = ''
        Discord running Vencord with the PubsubPush plugin. Installed with
        high priority, so it wins over a plain `discord` in home.packages.
      '';
    };

    publisher = mkOption {
      type = types.package;
      default = pp.pubsub-publish;
      defaultText = lib.literalExpression "pubsub-publish";
    };

    jid = mkOption {
      type = types.str;
      example = "desktop@example.com";
      description = "Account to publish as; must be a publisher of the topic.";
    };

    passwordFile = mkOption {
      type = types.str;
      example = "/run/secrets/xmpp-password";
      description = "File holding that account's password, readable by this user.";
    };

    service = mkOption {
      type = types.str;
      example = "notify.example.com";
    };

    topic = mkOption {
      type = types.str;
      example = "discord";
    };

    forwardIf = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = lib.literalExpression ''[ "''${pkgs.procps}/bin/pgrep" "-xu" "me" "i3lock" ]'';
      description = ''
        Command run before each forward; the notification is published only
        if it exits 0 (e.g. "screen is locked"). null: always forward.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ (lib.hiPrio cfg.package) ];

    xdg.configFile."pubsub-push/discord.json".text = builtins.toJSON ({
      publish = [
        "${cfg.publisher}/bin/pubsub-publish"
        "--jid" cfg.jid
        "--password-file" cfg.passwordFile
        "--service" cfg.service
        "--topic" cfg.topic
      ];
    } // lib.optionalAttrs (cfg.forwardIf != null) { inherit (cfg) forwardIf; });
  };
}
