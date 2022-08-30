let
  pkgs = import <nixpkgs> { };

  inherit (pkgs)
    stdenv fetchurl bubblewrap fuse ostree git lzip writeShellApplication
    runCommand flatpak cacert writeText stdenvNoCC writeShellScript mount
    util-linux lib unixtools python3Packages;
  inherit (builtins) substring readFile toFile concatMap hashFile;
  inherit (pkgs.rustPlatform) buildRustPackage;

  ostreeTool = buildRustPackage {
    name = "ostree-tool";
    src = ./ostree-tool;
    cargoLock = { lockFile = ./ostree-tool/Cargo.lock; };
  };
  runOstreeTool = name: cmd:
    runCommand name { nativeBuildInputs = [ ostreeTool ]; } cmd;
  parseOstreeObject = object:
    lib.importJSON (runOstreeTool "ostree-object-parsed"
      "ostree-tool parse ${object.ostree-object-type} < ${object} > $out");
  splitHash = hash: {
    head = substring 0 2 hash;
    tail = substring 2 64 hash;
  };
  fetchOstreeObjectRaw = { url, hash, type }:
    let
      inherit (splitHash hash) head tail;
      isFile = type == "file";
      ext = if isFile then "filez" else type;
    in fetchurl {
      url = "${url}/objects/${head}/${tail}.${ext}";
      sha256 = hash;
      name = "ostree-object";
      downloadToTemp = isFile;
      # Decompress if filez
      nativeBuildInputs = lib.optional isFile [ ostreeTool ];
      postFetch = lib.optionalString isFile
        "ostree-tool unzip-filez < $downloadedFile > $out";
    };
  fetchOstreeObject = { url, hash, type }:
    let raw = fetchOstreeObjectRaw { inherit url hash type; };
    in (if type == "file" then
      runOstreeTool "ostree-object" "ostree-tool realize-file $out < ${raw}"
    else
      raw) // {
        ostree-object-type = type;
        ostree-object-hash = hash;
      };
  fetchOstree = { url, branch, commit }:
    let
      fetchObject = type: hash: fetchOstreeObject { inherit url type hash; };
      commitObject = fetchObject "commit" commit;
      commitObjectParsed = parseOstreeObject commitObject;
      rootDirtreeObject = fetchObject "dirtree" commitObjectParsed.dirtree;
      rootDirmetaObject = fetchObject "dirmeta" commitObjectParsed.dirmeta;
      walk = dirtree:
        (let
          dirtreeParsed = parseOstreeObject dirtree;
          childDirtrees =
            map (dir: fetchObject "dirtree" dir.dirtree) dirtreeParsed.dirs;
        in map (file: fetchObject "file" file.hash) dirtreeParsed.files
        ++ map (dir: fetchObject "dirmeta" dir.dirmeta) dirtreeParsed.dirs
        ++ childDirtrees ++ concatMap walk childDirtrees);
      objects = [ commitObject rootDirtreeObject rootDirmetaObject ]
        ++ walk rootDirtreeObject;
      objectPath = object:
        let inherit (splitHash object.ostree-object-hash) head tail;
        in "${head}/${tail}.${object.ostree-object-type}";
      objectsDirScript = (lib.concatMapStrings (object: ''
        mkdir -p $(dirname $out/${objectPath object})
        ln --force ${object} $out/${objectPath object}
      '') objects);
      objectsDir = runCommand "ostree-objects-dir" { } objectsDirScript;
      repo = runCommand "ostree-repo" { nativeBuildInputs = [ ostree ]; } ''
        ostree init --repo=$out --mode=bare-user-only
        rmdir $out/objects
        ln -s ${objectsDir} $out/objects
      '';
    in repo;
  wrappedFlatpakScriptRoot = writeShellScript "wrapped-flatpak-script-root" ''
    set -eu

    tmp=$(mktemp -d)
    mnt=$tmp/mnt
    out=$tmp/out
    scratch=$tmp/scratch
    mkdir $mnt $out $scratch
    if [ -n "''${NIX_FLATPAK_PATH:-}" ] && [ -n "''${NIX_FLATPAK_OUT:-}" ]
    then
        ${util-linux}/bin/mount -t overlay overlay \
            -o lowerdir="$NIX_FLATPAK_PATH",upperdir="$out",workdir="$scratch" \
            "$mnt"
    elif [ -n "''${NIX_FLATPAK_PATH:-}" ] && [ -z "''${NIX_FLATPAK_OUT:-}" ]
    then
        if grep --silent ":" <<< "$NIX_FLATPAK_PATH"
        then
            ${util-linux}/bin/mount -t overlay overlay -o lowerdir="$NIX_FLATPAK_PATH" "$mnt"
        else
            ${util-linux}/bin/mount --bind $NIX_FLATPAK_PATH $mnt
        fi
    elif [ -z "''${NIX_FLATPAK_PATH:-}" ] && [ -n "''${NIX_FLATPAK_OUT:-}" ]
    then
        ${util-linux}/bin/mount --bind $out $mnt
    fi
    cmd="$1"
    shift
    FLATPAK_SYSTEM_DIR=/dev/null FLATPAK_USER_DIR=$mnt \
        ${flatpak}/bin/flatpak "$cmd" --user "$@"
    ${util-linux}/bin/umount --quiet $mnt || true
    if [ -n "''${NIX_FLATPAK_OUT:-}" ]
    then
        mkdir -p $NIX_FLATPAK_OUT
        cp -r $out/* "$NIX_FLATPAK_OUT"
    fi
    rm -rf "$tmp"
  '';
  wrappedFlatpakScript = writeShellScript "wrapped-flatpak-script" ''
    ${util-linux}/bin/unshare -rm ${wrappedFlatpakScriptRoot} "$@"
  '';
  wrappedFlatpak = stdenvNoCC.mkDerivation {
    name = "wrapped-flatpak";
    setupHook = writeText "wrapped-flatpak-setup-hook" ''
      addNixFlatpakPath () {
        addToSearchPath NIX_FLATPAK_PATH "$1/flatpak"
      }
      addEnvHooks "$hostOffset" addNixFlatpakPath
      addEnvHooks "$targetOffset" addNixFlatpakPath
    '';
    dontUnpack = true;
    dontPatch = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/bin
      cp ${wrappedFlatpakScript} $out/bin/wrapped-flatpak
    '';
  };
  flathubUrl = "https://dl.flathub.org/repo/";
  getFromFlathub =
    { kind, id, arch ? "x86_64", branch ? "stable", runtime ? null, commit }:
    assert lib.assertOneOf "kind" kind [ "app" "runtime" ];
    let
      repo = fetchOstree {
        url = flathubUrl;
        branch = "${kind}/${id}/${arch}/${branch}";
        inherit commit;
      };
    in runCommand "flathub-${kind}-${id}-${arch}-${branch}" {
      nativeBuildInputs = [ ostree ostreeTool ];
      propagatedBuildInputs = [ wrappedFlatpak ]
        ++ (lib.optional (runtime != null) runtime);
    } ''
      dir=$out/flatpak/${kind}/${id}/${arch}/${branch}
      mkdir -p $dir
      cd $dir
      ostree checkout --repo=${repo} ${commit}
      ln -s ${commit} active
      ostree-tool make-deploy-file flathub ${commit} > active/deploy
    '';
  flathub-org-kde-platform = getFromFlathub {
    kind = "runtime";
    id = "org.kde.Platform";
    branch = "5.15-21.08";
    commit = "b76cb66319a7c5877ea02dcdd4d8bd53b3c6470b6f9c96fb3238ff216bf991c7";
  };
  flathub-org-flatpak-qtdemo = getFromFlathub {
    kind = "app";
    id = "org.flatpak.qtdemo";
    runtime = flathub-org-kde-platform;
    commit = "35ca03c3a7d951314f9e877044db554424bc803206e95c0b77a316e36aafc3d3";
  };
in pkgs.mkShell { packages = [ flathub-org-kde-platform wrappedFlatpak ]; }
