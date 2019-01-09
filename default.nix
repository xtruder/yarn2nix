{ pkgs ? import <nixpkgs> {}
, nodejs ? pkgs.nodejs-8_x
, yarn ? pkgs.yarn
}:

let
  inherit (pkgs) stdenv lib fetchurl linkFarm callPackage git;
in rec {
  # Export yarn again to make it easier to find out which yarn was used.
  inherit yarn;

  # Re-export pkgs
  inherit pkgs;

  unlessNull = item: alt:
    if item == null then alt else item;

  reformatPackageName = pname:
    let
      # regex adapted from `validate-npm-package-name`
      # will produce 3 parts e.g.
      # "@someorg/somepackage" -> [ "@someorg/" "someorg" "somepackage" ]
      # "somepackage" -> [ null null "somepackage" ]
      parts = builtins.tail (builtins.match "^(@([^/]+)/)?([^/]+)$" pname);
      # if there is no organisation we need to filter out null values.
      non-null = builtins.filter (x: x != null) parts;
    in builtins.concatStringsSep "-" non-null;

  # https://docs.npmjs.com/files/package.json#license
  # TODO: support expression syntax (OR, AND, etc)
  spdxLicense = licstr:
    if licstr == "UNLICENSED" then
      lib.licenses.unfree
    else
      lib.findFirst
        (l: l ? spdxId && l.spdxId == licstr)
        { shortName = licstr; }
        (builtins.attrValues lib.licenses);

  # Generates the yarn.nix from the yarn.lock file
  mkYarnNix = { yarnLock, flags ? [] }:
    pkgs.runCommand "yarn.nix" {}
    "${yarn2nix}/bin/yarn2nix --lockfile ${yarnLock} --no-patch ${lib.escapeShellArgs flags} > $out";

  # Loads the generated offline cache. This will be used by yarn as
  # the package source.
  importOfflineCache = yarnNix:
    let
      pkg = callPackage yarnNix { };
    in
      pkg.offline_cache;

  defaultYarnFlags = [
    "--offline"
    "--frozen-lockfile"
    "--ignore-engines"
  ];

  mkYarnModules = {
    name,
    pname,
    version,
    packageJSON,
    yarnLock,
    yarnNix ? mkYarnNix { inherit yarnLock; },
    yarnFlags ? defaultYarnFlags,
    pkgConfig ? {},
    preBuild ? "",
    workspaceDependencies ? [],
    nohoist ? []
  }:
    let
      offlineCache = importOfflineCache yarnNix;
      extraBuildInputs = (lib.flatten (builtins.map (key:
        pkgConfig.${key} . buildInputs or []
      ) (builtins.attrNames pkgConfig)));
      postInstall = (builtins.map (key:
        if (pkgConfig.${key} ? postInstall) then
          ''
            for f in $(find -L -path '*/node_modules/${key}' -type d); do
              (cd "$f" && (${pkgConfig.${key}.postInstall}))
            done
          ''
        else
          ""
      ) (builtins.attrNames pkgConfig));
      workspaceJSON = pkgs.writeText
        "${name}-workspace-package.json"
        (builtins.toJSON {
          private = true;
          workspaces = {
            inherit nohoist;
            packages = ["deps/**"];
          };  
        }); # scoped packages need second splat
      workspaceDependencyLinks = lib.concatMapStringsSep "\n"
        (dep: ''
          mkdir -p "deps/${dep.pname}"
          ln -sf ${dep.packageJSON} "deps/${dep.pname}/package.json"
        '')
        workspaceDependencies;
    in stdenv.mkDerivation {
      inherit preBuild name;
      phases = ["configurePhase" "buildPhase"];
      buildInputs = [ yarn nodejs git ] ++ extraBuildInputs;

      configurePhase = ''
        # Yarn writes cache directories etc to $HOME.
        export HOME=$PWD/yarn_home
      '';

      buildPhase = ''
        runHook preBuild

        mkdir -p "deps/${pname}"
        cp ${packageJSON} "deps/${pname}/package.json"
        cp ${workspaceJSON} ./package.json
        cp ${yarnLock} ./yarn.lock
        chmod +w ./yarn.lock

        yarn config --offline set nodedir "${nodejs}/include/node"
        yarn config --offline set yarn-offline-mirror ${offlineCache}

        # Do not look up in the registry, but in the offline cache.
        node ${./internal/fixup_yarn_lock.js} yarn.lock

        ${workspaceDependencyLinks}

        yarn install ${lib.escapeShellArgs yarnFlags}

        ${lib.concatStringsSep "\n" postInstall}

        mkdir $out
        mv node_modules $out/
        mv deps $out/
        patchShebangs $out

        runHook postBuild
      '';

      passthru.offlineCache = offlineCache;
    };

  mkYarnWorkspace = {
    src,
    packageJSON ? src + "/package.json",
    yarnLock ? src + "/yarn.lock",
    packageOverrides ? {},
    ...
  }@attrs:
  let
    package = lib.importJSON packageJSON;
    packageGlobs = package.workspaces;
    globElemToRegex = lib.replaceStrings ["*"] [".*"];
    # PathGlob -> [PathGlobElem]
    splitGlob = lib.splitString "/";
    # Path -> [PathGlobElem] -> [Path]
    # Note: Only directories are included, everything else is filtered out
    expandGlobList = base: globElems:
    let
      elemRegex = globElemToRegex (lib.head globElems);
      rest = lib.tail globElems;
      children = lib.attrNames (lib.filterAttrs (name: type: type == "directory") (builtins.readDir base));
      matchingChildren = lib.filter (child: builtins.match elemRegex child != null) children;
    in if globElems == []
      then [ base ]
      else lib.concatMap (child: expandGlobList (base+("/"+child)) rest) matchingChildren;
    # Path -> PathGlob -> [Path]
    expandGlob = base: glob: expandGlobList base (splitGlob glob);
    packagePaths = lib.concatMap (expandGlob src) packageGlobs;
    packages = lib.listToAttrs (map (src:
    let
      packageJSON = src + "/package.json";
      package = lib.importJSON packageJSON;
      allDependencies = lib.foldl (a: b: a // b) {} (map (field: lib.attrByPath [field] {} package) ["dependencies" "devDependencies"]);
    in rec {
      name = reformatPackageName package.name;
      value = mkYarnPackage (builtins.removeAttrs attrs ["packageOverrides"] // {
        inherit src packageJSON yarnLock;
        workspaceDependencies = lib.mapAttrsToList (name: version: packages.${name})
          (lib.filterAttrs (name: version: packages ? ${name}) allDependencies);
      } // lib.attrByPath [name] {} packageOverrides);
    }) packagePaths);
  in packages;

  mkYarnPackage = {
    # Run-time dependencies for the package
    buildInputs ? [],

    # Execute before shell hook
    preShellHook ? "",

    # Execute after shell hook
    postShellHook ? "",

    # package source
    src,

    # packageJSON file
    packageJSON ? src + "/package.json",

    # package
    package ? lib.importJSON packageJSON,

    # name to use for a package (default "${pname}-${version}")
    name ? null,

    # name of the package
    pname ? package.name,

    # version of the package
    version ? package.version,

    # yarn lock file (optional)
    yarnLock ? src + "/yarn.lock",

    # yarnNix file
    yarnNix ? mkYarnNix { inherit yarnLock; },

    # yarnFlags to pass to yarn
    yarnFlags ? defaultYarnFlags,

    # extra yarn flags to pass to yarn
    extraYarnFlags ? [],

    # yarn pre build
    yarnPreBuild ? "",
    pkgConfig ? {},

    # list of package names to publish binaries for
    publishBinsFor ? [pname],

    # whether to install only production modules when releasing package
    useProduction ? lib.hasAttr "devDependencies" package && package.devDependencies != [],

    # extra package dependencies
    workspaceDependencies ? [],

    ...
  }@attrs: let
    safeName = reformatPackageName pname;
    baseName = unlessNull name "${safeName}-${version}";

    deps = mkYarnModules {
      name = "${safeName}-modules-${version}";
      preBuild = yarnPreBuild;
      workspaceDependencies = workspaceDependenciesTransitive;
      yarnFlags = yarnFlags ++ extraYarnFlags;
      inherit packageJSON pname version yarnLock yarnNix pkgConfig;
    };

    prodDeps = mkYarnModules {
      name = "${safeName}-modules-production-${version}";
      preBuild = yarnPreBuild;
      workspaceDependencies = workspaceDependenciesTransitive;
      yarnFlags = yarnFlags ++ extraYarnFlags ++ ["--production"];
      inherit packageJSON pname version yarnLock yarnNix pkgConfig;
    };

    linkDirFunction = ''
      linkDirToDirLinks() {
        target=$1
        if [ ! -f "$target" ]; then
          mkdir -p "$target"
        elif [ -L "$target" ]; then
          local new=$(mktemp -d)
          trueSource=$(realpath "$target")
          if [ "$(ls $trueSource | wc -l)" -gt 0 ]; then
            ln -s $trueSource/* $new/
          fi
          rm -r "$target"
          mv "$new" "$target"
        fi
      }
    '';

    workspaceDependenciesTransitive = lib.unique ((lib.flatten (builtins.map (dep: dep.workspaceDependencies) workspaceDependencies)) ++ workspaceDependencies);

    workspaceDependencyCopy = lib.concatMapStringsSep "\n" (dep: ''
      # ensure any existing scope directory is not a symlink
      linkDirToDirLinks "$(dirname node_modules/${dep.pname})"
      mkdir -p "deps/${dep.pname}"
      tar -xf "${dep.dist}/tarballs/${dep.name}.tgz" --directory "deps/${dep.pname}" --strip-components=1
      if [ ! -e "deps/${dep.pname}/node_modules" ]; then
        ln -s "${deps}/deps/${dep.pname}/node_modules" "deps/${dep.pname}/node_modules"
      fi
    '') workspaceDependenciesTransitive;

    withoutAttrs = ["pkgConfig" "workspaceDependencies" "package"];
  in stdenv.mkDerivation (builtins.removeAttrs attrs withoutAttrs // {
    inherit src version;

    name = baseName;

    buildInputs = [ yarn nodejs ] ++ buildInputs;

    node_modules = deps + "/node_modules";

    prod_node_modules =
      if useProduction then prodDeps + "/node_modules"
      else deps + "/node_modules";

    outputs = ["out" "dist"];

    configurePhase = attrs.configurePhase or ''
      runHook preConfigure

      ${linkDirFunction}

      # remove existing npm-packages-offline-cache and node_modules
      for localDir in npm-packages-offline-cache node_modules; do
        if [[ -d $localDir || -L $localDir ]]; then
          echo "$localDir dir present. Removing."
          rm -rf $localDir
        fi
      done

      mkdir -p "deps/${pname}"
      shopt -s extglob
      cp -r {!(deps),.[^.]*} "deps/${pname}"
      shopt -u extglob
      ln -s ${deps}/deps/${pname}/node_modules "deps/${pname}/node_modules"

      # copy node_modules locally
      cp -r $node_modules node_modules
      chmod -R +w node_modules

      linkDirToDirLinks "$(dirname node_modules/${pname})"
      ln -s "deps/${pname}" "node_modules/${pname}"

      ${workspaceDependencyCopy}

      # Help yarn commands run in other phases find the package
      echo "--cwd deps/${pname}" > .yarnrc

      runHook postConfigure
    '';

    # Replace this phase on frontend packages where only the generated
    # files are an interesting output.
    installPhase = attrs.installPhase or ''
      runHook preInstall

      mkdir -p $out/{bin,libexec/${pname}}

      rm "deps/${pname}/node_modules"
      ${if useProduction then ''
      cp -r $prod_node_modules $out/libexec/${pname}/node_modules
      chmod -R +w $out/libexec/${pname}/node_modules

      if [ -d "${prodDeps}/deps/${pname}/node_modules" ]; then
        cp -R ${prodDeps}/deps/${pname}/node_modules "deps/${pname}"
        chmod -R +w "deps/${pname}/node_modules"
      fi
      '' else ''
      mv node_modules $out/libexec/${pname}/node_modules

      if [ -d "${deps}/deps/${pname}/node_modules" ]; then
        cp -R ${deps}/deps/${pname}/node_modules "deps/${pname}"
        chmod -R +w "deps/${pname}/node_modules"
      ff
      ''}

      mv deps $out/libexec/${pname}/deps
      node ${./internal/fixup_bin.js} $out/bin $out/libexec/${pname}/node_modules ${lib.concatStringsSep " " publishBinsFor}

      runHook postInstall
    '';

    doDist = true;
    doCheck = attrs.doCheck or true;

    distPhase = attrs.distPhase or ''
      # pack command ignores cwd option
      rm -f .yarnrc
      cd $out/libexec/${pname}/deps/${pname}
      mkdir -p $dist/tarballs/
      yarn pack --offline --ignore-scripts --filename $dist/tarballs/${baseName}.tgz
    '';

    shellHook = attrs.shellHook or ''
      ${preShellHook}

      HOME=$PWD yarn config --offline set nodedir "${nodejs}/include/node"
      yarn install

      ${postShellHook}
    '';

    passthru = {
      inherit pname package packageJSON deps;
      workspaceDependencies = workspaceDependenciesTransitive;
      offlineCache = deps.offlineCache;
    } // (attrs.passthru or {});

    meta = {
      inherit (nodejs.meta) platforms;
      description = packageJSON.description or "";
      homepage = packageJSON.homepage or "";
      version = packageJSON.version or "";
      license = if packageJSON ? license then spdxLicense packageJSON.license else "";
    } // (attrs.meta or {});
  });

  yarn2nix = mkYarnPackage {
    src = lib.cleanSourceWith {
      filter = name: type: let baseName = baseNameOf (toString name); in !(
        lib.hasSuffix ".nix" baseName
      );
      src = lib.cleanSource ./.;
    };

    # yarn2nix is the only package that requires the yarnNix option.
    # All the other projects can auto-generate that file.
    yarnNix = ./yarn.nix;
    yarnLock = ./yarn.lock;
    packageJSON = ./package.json;

    checkPhase = ''
      yarn run lint

      ${import ./nix/testFileShFunctions.nix}

      testFilePresent ./node_modules/.yarn-integrity

      # check dependencies are installed
      testFilePresent ./node_modules/@yarnpkg/lockfile/package.json
    '';
  };
}
