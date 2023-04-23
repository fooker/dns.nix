{ config, lib, nodes, ... }@args:

with lib;

let
  record = import ./record.nix args;

  # Match every name that is all-upercase
  isRecord = name: (builtins.match "[A-Z]+" name) != null;

  # Coerces an attrset to a zone submodule by splitting the attrset into three parts:
  # - the well-known attributes of the zone like `ttl`
  # - the resource records of this zone (all uppercase entries)
  # - all child nodes defined in this node (everything else)
  coerceNode = attrs:
    let
      # Get the well-known attributes if they exists in the attrset
      known = getAttrs
        (filter
          (name: hasAttr name attrs)
          [ "ttl" "includes" "parent" ])
        attrs;

      # Partititon all attr names that are not well-know by being a record or not
      partitioned = partition
        isRecord
        (filter
          # Filter for everything that is not well-known
          (name: !(hasAttr name known))
          (attrNames attrs));
    in
    {
      records = getAttrs partitioned.right attrs;
      nodes = getAttrs partitioned.wrong attrs;
    } // known;

  # Option type for node definitions - similar to types.coercedTo but checking specific for
  # being a node by looking node specific records
  coercedNodeSubmodule = mod: mkOptionType rec {
    name = "coercedNodeSubmodule";
    description = "${mod.description} or ${types.attrs.description} convertible to it";

    check = x: mod.check x || (types.attrs.check x && mod.check (coerceNode x));

    merge =
      let
        coerceVal = val:
          if hasAttr "records" val || hasAttr "nodes" val then val
          else coerceNode val;
      in
      loc: defs:
        mod.merge loc (map (def: def // { value = coerceVal def.value; }) defs);

    inherit (mod) emptyValue getSubOptions getSubModules;

    substSubModules = m: coercedNodeSubmodule (mod.substSubModules m);

    typeMerge = _: _: null;

    functor = (defaultFunctor name) // { wrapped = mod; };
  };

  # Submodule for the records of a node
  recordsType = types.submodule ({ config, options, ... }: {
    imports = [ ./records ];
    options = {
      defined = mkOption {
        type = types.listOf types.str;
        description = "The list of defined record types";
        readOnly = true;
        internal = true;
      };
    };
    config = {
      defined = filter
        (name: isRecord name && options.${ name }.isDefined)
        (attrNames config);

      _module.args = { inherit record; };
    };
  });

  # Recursive node type definition as used to configure DNS records
  node = level:
    coercedNodeSubmodule (types.submodule {
      options = {
        ttl = mkOption {
          type = types.nullOr types.int;
          description = "The default TTL for all records in this node";
          default = null;
        };

        includes = mkOption {
          type = types.listOf types.path;
          description = "Other zone files to include";
          default = [ ];
        };

        parent = mkOption {
          type = recordsType;
          description = "Records propagated to the parent zone";
          default = { };
        };

        records = mkOption {
          type = recordsType;
          description = "Records of this node";
          default = { };
        };
      } // optionalAttrs (level <= 127) {
        nodes = mkOption {
          type = types.attrsOf (node (level + 1));
          default = { };
        };
      };
    });

in
{
  options.dns = {
    zones = mkOption {
      type = node 0;
      description = "The DNS tree";
      default = { };
    };

    defaultTTL = mkOption {
      type = types.int;
      description = "The default TTL for all records";
      default = 3600;
    };

    global = mkOption {
      type = node 0;
      description = "The global DNS tree";
      internal = true;
      readOnly = true;
    };

    zoneList = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.domain.absolute;
            readOnly = true;
            description = "The domain name of the zone";
          };

          records = mkOption {
            type = types.listOf (types.submodule {
              imports = [ record.module ];
              options = {
                domain = mkOption {
                  type = types.domain;
                  readOnly = true;
                  description = "The domain name of the record";
                };
              };
            });
            readOnly = true;
            description = "The records in the zone";
          };

          includes = mkOption {
            type = types.listOf (types.submodule {
              options = {
                file = mkOption {
                  type = types.path;
                  readOnly = true;
                  description = "Path of the file to include";
                };

                domain = mkOption {
                  type = types.domain;
                  readOnly = true;
                  description = "The domain name of the record";
                };
              };
            });
            readOnly = true;
            description = "The includes in the zone";
          };
        };
      });
      description = "The internal representation of the zones";
      internal = true;
      readOnly = true;
    };
  };

  config.dns = {
    # Build global DNS tree by merging the local tree from all nodes
    global =
      let
        # Use all defined records while stripping out the data element as it is
        # re-created from the definition.
        cleanupRecords = records: mapAttrs
          (_: record:
            if isList record
            then map (flip removeAttrs [ "data" ]) record
            else removeAttrs record [ "data" ])
          (getAttrs records.defined records);

        walk = cfg: path: {
          inherit (cfg) ttl includes;

          records = cleanupRecords cfg.records;
          parent = cleanupRecords cfg.parent;

          # Recurs into all defined child nodes
          nodes = mapAttrs (name: zone: walk zone (path ++ [ name ])) cfg.nodes;
        };
      in
      mkMerge (map
        (node: walk node.config.dns.zones [ ])
        (attrValues nodes));

    # Build the zone list from the nodes. This is an list where each element is
    # just the zone name and a list of records in the zone.
    zoneList =
      let
        walk = { domain, zone, ttl, config }:
          let
            # If this domain has a SOA record, we found a new (sub) zone
            zone' =
              if elem "SOA" config.records.defined
              then [ domain ] ++ zone
              else zone;

            # If the domain has defined a TTL we use it as default for all records and sub-zones
            ttl' = if config.ttl != null then config.ttl else ttl;

            # Build an entry for some element in the zone
            mkEntry = zone: type: value: {
              inherit zone;
              ${ type } = value;
            };

            # Build the resulting record type from a record in a zone
            mkRecord = zone: record: mkEntry zone "record" {
              inherit domain;
              inherit (record) class type data;

              ttl = if record.ttl != null then record.ttl else ttl';
            };

            # Build the list of records
            mkRecords = zone: records: concatMap
              (record: map
                (mkRecord zone)
                (toList record))
              (attrVals records.defined records);

            records = mkRecords (head zone') config.records;
            parents = mkRecords (head (tail zone')) config.parent;

            # Build an include element from the include in a zone
            mkInclude = file: mkEntry (head zone') "include" {
              inherit domain file;
            };

            # Build the list of includes in the current domain
            includes = map mkInclude config.includes;

            # Recurse into all sub-domain
            next = concatLists (
              mapAttrsToList
                (name: value: walk {
                  domain = domain.resolve (mkDomainRelative name);
                  zone = zone';
                  ttl = ttl';
                  config = value;
                })
                config.nodes);

          in
          records ++ parents ++ includes ++ next;

        # Walk the tree and collect all records
        collected = walk {
          domain = mkDomainAbsolute [ ];
          zone = [ ];
          ttl = config.dns.defaultTTL;
          config = config.dns.global;
        };

        # Group the collected record by zone they are defined in
        # [ { zone, record }, { zone, include } ... ] -> [ { name = zone, records = [ ... ], includes = [ ... ]} ... ]
        grouped = attrValues (groupBy'
          (group: entry: {
            name = entry.zone;
            records = group.records ++ (optional (hasAttr "record" entry) entry.record);
            includes = group.includes ++ (optional (hasAttr "include" entry) entry.include);
          })
          { records = [ ]; includes = [ ]; }
          (entry: toString entry.zone)
          collected);

      in
      grouped;
  };
}
