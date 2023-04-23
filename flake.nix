{
  inputs = {
    ipam.url = "github:fooker/ipam.nix";
  };

  outputs = { ... }: rec {
    nixosModules = rec {
      dns = import ./default.nix;
      default = dns;
    };
    nixosModule = nixosModules.default;

    lib = import ./lib.nix;
  };
}