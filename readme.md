NixOS module to manage DNS records.

## What is `dns.nix`
`dns.nix` is a NixOs module and library that makes declarative management of DNS records as simple as possible, while still utilizing the flexibility of NixOS configurations.

## Features
* Typed and format checked DNS records
* Support for multiple zones and sub-zones
* Tool-agnostic record collection for multiple nodes
* Zone file generation

## Usage
`dns.nix` can be used as a flake or by directly importing `default.nix` in your module system.

Example using flakes:
```
{
  inputs = {
    dns.url = "github:fooker/dns.nix";
  };

  outputs = { dns, ... }: {
    nixosSystem = {
      modules = [ dns.nixosModules.default ];
    };
  };
}
```

Example using imports:
```
{
  imports = [ /path/to/dns.nix/default.nix ];
}
```

The module defines the `dns` option which is used to define DNS zones and records.

Example module with a simple zone definition:
```
{ ... }: {
  dns.zones = {
    com.example = {
      # Havine a SOA record makes this a zone
      SOA = {
        mname = "ns.example.com.";
        rname = "hostmaster";
      };
      
      # Records can have one or multiple values and will be coerced if the record type allows multiple values
      NS = [
        "ns.example.com"
        "ns2.example.com"
      ];

      # Lower-case name form record names where upper-case names are interpreted as record types.
      something = {
        # Set TTL for everything under `something.example.com`
        ttl = 60;

        # Defines an AAAA record for something.example.com
        AAAA = "2001:0db8:85a3::8a2e:0370:7334";
      };
    };
  };
}
```

This simple form of a DNS record tree is transformed to a tree where each level is an attribute set containing the following elements:
* **`ttl`**: The TTL in seconds for all records in node and below.
* **`records`**: The records defined for this node
* **`nodes`**: The child nodes for this node.
* **`includes`**: Includes of a static zone files on this node level. This is only evaluated during zone-file generation.
* **`parent`**: Records propagated to the parent zone.

