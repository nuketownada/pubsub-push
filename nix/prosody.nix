# services.pubsub-push.prosody: push topics on an existing services.prosody.
# Adds the patched mod_unified_push and mod_pubsub_unified_push, and a pubsub
# component holding the topics. See ../README.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.pubsub-push.prosody;
  inherit (lib) mkOption types;

  str = builtins.toJSON; # a JSON string is a valid Lua string literal here
  list = l: "{ ${lib.concatMapStringsSep ", " str l} }";
  topic = name: t:
    "  [${str name}] = { publishers = ${list t.publishers}, members = ${list t.members}, max_items = ${toString t.maxItems}"
    + lib.optionalString (t.title != null) ", title = ${str t.title}"
    + " };";
in
{
  options.services.pubsub-push.prosody = {
    enable = lib.mkEnableOption "pubsub-push topics delivered over UnifiedPush";

    package = mkOption {
      type = types.package;
      default = (import ./packages.nix pkgs).pubsub-push-prosody-modules;
      defaultText = lib.literalExpression "pubsub-push-prosody-modules";
      description = "Prosody plugin directory with mod_unified_push and mod_pubsub_unified_push.";
    };

    service = mkOption {
      type = types.str;
      example = "notify.example.com";
      description = ''
        Domain of the pubsub component holding the topics. Publishers send
        to it; only local users need to reach it, so no DNS is required.
      '';
    };

    topics = mkOption {
      default = { };
      description = ''
        Topics (pubsub nodes), created and kept in line with this on start:
        affiliations not listed here are removed.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          publishers = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Bare JIDs that may publish.";
          };
          members = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Bare JIDs whose devices may register for the topic.";
          };
          maxItems = mkOption {
            type = types.ints.between 1 256;
            default = 100;
            description = "Items kept for devices that are offline.";
          };
          title = mkOption {
            type = types.nullOr types.str;
            default = null;
          };
        };
      });
      example = lib.literalExpression ''
        { alerts = { publishers = [ "server@example.com" ]; members = [ "me@example.com" ]; }; }
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = "pubsub_unified_push_retry_interval = 120";
      description = "Extra global Prosody config for the modules (Lua).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = !(lib.elem "unified_push" (config.services.prosody.package.communityModules or [ ]));
      message = ''
        services.pubsub-push.prosody brings a patched mod_unified_push; remove
        "unified_push" from the Prosody package's withCommunityModules.
      '';
    }];

    services.prosody = {
      extraPluginPaths = [ cfg.package ];
      extraModules = [ "unified_push" "pubsub_unified_push" ];
      # mkAfter: the Component line must come last, since everything after
      # it is the component's config.
      extraConfig = lib.mkAfter ''
        -- pubsub-push (services.pubsub-push.prosody)
        pubsub_unified_push_service = ${str cfg.service}
        pubsub_unified_push_nodes = {
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList topic cfg.topics)}
        }
        ${cfg.extraConfig}
        Component ${str cfg.service} "pubsub"
      '';
    };
  };
}
