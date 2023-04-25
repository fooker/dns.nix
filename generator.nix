{ lib
, configs # List of evaluated NixOS configs build with this `dns.nix` module
, writeText
, ... }:

with lib.extend (import ./lib.nix);

let
  # Apply `f` to every element of `x` if `x` is a list, otherwise apply `f` to `x` directly
  mapSingleOrList = f: x:
    if isList x
    then map f x
    else f x;

  # Normalize record trees from all configs and push inherited values (TTL)
  # down the tree.
  normalizedTrees = map (config: let
    walk = node: { ttl }: let
      # If the node defines a TTL we use it for all records and child nodes
      ttl' = if node.ttl != null then node.ttl else ttl;
      
      # Maps record configurations of defined records to normalized form.
      # The attribute set is lazy defined for all possible record types and
      # has an additional attribute which reflects a list of actually defined
      # record names.
      mkRecords = records: mapAttrs
        (_: mapSingleOrList (record: {
          inherit (record) class type data;
          
          # Prefer record TTL with fallback to TTL of current node
          ttl = if record.ttl != null then record.ttl else ttl';
        }))
        (getAttrs records.defined records); 

    in {
      records = mkRecords node.records;
      parent = mkRecords node.parent;

      inherit (node) includes;

      # Recurse into child nodes
      nodes = mapAttrs
        (name: node: walk node {
          ttl = ttl';
        })
        node.nodes;
    };
  in walk config.dns.zones {
    ttl = null; # TTL is undefined until set first time in the tree
  }) configs;

  # Merge the DNS configuration from all normalized configs.
  # Allows duplicated records for singletone types only if both sides are equal
  mergedTree = let
    # Resolves the path to a node in the config or `null` of no such node exists
    resolve = node: path:
      if path == []
        then node
        else if node.nodes ? ${head path}
          then resolve node.nodes.${head path} (tail path)
          else null;

    walk = path: let
      # Merge two records by concatenating if both records are lists or by
      # ensuring both sides are equal and return just one side
      mergeRecord = type: lhs: rhs:
        if isList lhs && isList rhs
          then lhs ++ rhs
          else assert assertMsg (lhs == rhs) ''
            Record with type "${type}" is defined multiple times for domain "${concatStringsSep "." path}" and values differ:
            
            ${generators.toPretty {} lhs}

            ${generators.toPretty {} rhs}
          ''; lhs;
      
      # Merge attribute sets of records
      mergeRecords = records:
        zipAttrsWith
          (type: values:
            if values == [] then []
            else foldl (mergeRecord type) (head values) (tail values))
          records;
      nodes = filter
        (node: node != null)
        (map (config: resolve config path) normalizedTrees);
    in {
      records = mergeRecords (catAttrs "records" nodes);
      parent = mergeRecords (catAttrs "parent" nodes);

      includes = concatLists (catAttrs "includes" nodes);

      nodes = listToAttrs (map
        (name: nameValuePair name (walk (path ++ [name])))
        (unique (concatMap
          (node: attrNames node.nodes)
          nodes)));
    };
  in walk [];

  # Collect all records in the merge tree to a flat list records extended with
  # domain and zone info. Zones are resolved by finding SOA records.
  records = let
    walk = node: {
      domain, # Domain of the current node
      zones, # Stack of zones build while encountering SOA records
    }: let
      # If this domain has a SOA record, we push a new (sub) zone to the stack
      zones' =
        if hasAttr "SOA" node.records
        then [ domain ] ++ zones
        else zones;

      # Build an entry for some element in the zone
      mkEntry = zone: type: value: {
        inherit zone;
        ${type} = value;
      };

      # Build the resulting record type from a record in a zone
      mkRecord = zone: record: mkEntry zone "record" {
        inherit domain;
        inherit (record) class type data ttl;
      };

      # Build the list of records
      mkRecords = zone: records: concatMap
        (record: map
          (mkRecord zone)
          (toList record))
        (attrValues records);

      records = mkRecords (head zones') node.records;
      parents = mkRecords (head (tail zones')) node.parent;

      # Build an include element from the include in a zone
      mkInclude = file: mkEntry (head zones') "include" {
        inherit domain file;
      };

      # Build the list of includes in the current domain
      includes = map mkInclude node.includes;

      # Recurse into nodes
      nodes = (mapAttrsToList (name: node: walk node {
        domain = domain.resolve (mkDomainRelative name);
        zones = zones';
      }) node.nodes);

    in concatLists ([ records parents includes ] ++ nodes);
  in walk mergedTree {
    domain = mkDomainAbsolute [ ];
    zones = [ ];
  };

  # Group the collected record by zone they are defined in
  # [ { zone, record }, { zone, include } ... ] -> [ { name = zone, records = [ ... ], includes = [ ... ]} ... ]
  zones = attrValues (groupBy'
    (group: entry: {
      name = entry.zone;
      records = group.records ++ (optional (hasAttr "record" entry) entry.record);
      includes = group.includes ++ (optional (hasAttr "include" entry) entry.include);
    })
    { records = [ ]; includes = [ ]; }
    (entry: toString entry.zone)
    records);
  
  # Extend zones with derivation for the according zone file
  withZoneFile = map (zone: zone // {
    zoneFile = let
      mkRecord = { domain, ttl, type, class, data }:
        ''${toString domain} ${toString ttl} ${class} ${type} ${concatStringsSep " " data}'';
      mkInclude = { domain, file }:
        ''$INCLUDE "${file}" ${toString domain}'';
    in writeText "${zone.name.toSimpleString}.zone" (concatStringsSep "\n" (concatLists [
      (map mkRecord zone.records)
      (map mkInclude zone.includes)
    ]));
  }) zones;

in {
  zones = withZoneFile;
}
