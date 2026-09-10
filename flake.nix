{
  description = "Recents plugin for Yazi based on the desktop-bookmark-spec";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f (import nixpkgs { inherit system; }));

      mkYaziPlugin =
        pkgs: (pkgs.callPackage "${nixpkgs}/pkgs/by-name/ya/yazi/plugins/default.nix" { }).mkYaziPlugin;
    in
    {
      packages = forEachSupportedSystem (pkgs: {
        default = mkYaziPlugin pkgs {
          pname = "recents.yazi";
          version = "0-unstable-2026-09-10";

          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./main.lua
              ./README.md
              ./LICENSE
            ];
          };

          postPatch = ''
            substituteInPlace main.lua --replace-fail \
              'local XML_STARLET_PATH = "xmlstarlet"' \
              'local XML_STARLET_PATH = "${pkgs.lib.getExe pkgs.xmlstarlet}"'
          '';

          meta = {
            description = "Recents plugin for Yazi based on the desktop-bookmark-spec";
            homepage = "https://github.com/nmetschke/recents.yazi";
            license = pkgs.lib.licenses.mit;
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
          };
        };
      });
      devShells = forEachSupportedSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            yazi
            xmlstarlet
          ];

          shellHook = ''
            export YAZI_LOG=debug
            ln -s "$(pwd)"/ ~/.config/yazi/plugins/ || true
          '';
        };
      });
    };
}
