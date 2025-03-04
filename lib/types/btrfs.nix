{
  config,
  options,
  diskoLib,
  lib,
  rootMountPoint,
  parent,
  device,
  ...
}:
let
  btrfsConfig = config;

  swapType =
    swapTypeArgs@{ parent, ... }:
    lib.mkOption {
      type = lib.types.attrsOf (
        diskoLib.mkSubType (
          {
            config,
            name,
            options,
            parent,
            ...
          }:
          {
            options = {
              type = lib.mkOption {
                type = lib.types.enum [ "btrfs_swap" ];
                default = "btrfs_swap";
                internal = true;
                description = "Type";
              };

              size = lib.mkOption {
                type = lib.types.strMatching "^([0-9]+[KMGTP])?$";
                description = "Size of the swap file (e.g. 2G)";
              };

              path = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Path to the swap file (relative to the mountpoint)";
              };

              mountpoint = lib.mkOption {
                type = lib.types.nullOr diskoLib.optionTypes.absolute-pathname;
                internal = true;
                description = "Path to the swap file (absolute).";
                default = if parent._mountpoint != null then "${parent._mountpoint}/${config.path}" else null;
              };

              discardPolicy = lib.mkOption {
                default = null;
                example = "once";
                type = lib.types.nullOr (
                  lib.types.enum [
                    "once"
                    "pages"
                    "both"
                  ]
                );
                description = ''
                  Specify the discard policy for the swap device. If "once", then the
                  whole swap space is discarded at swapon invocation. If "pages",
                  asynchronous discard on freed pages is performed, before returning to
                  the available pages pool. With "both", both policies are activated.
                  See swapon(8) for more information.
                '';
              };

              priority = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = ''
                  Specify the priority of the swap file. Priority is a value between 0 and 32767.
                  Higher numbers indicate higher priority.
                  null lets the kernel choose a priority, which will show up as a negative value.
                '';
              };

              options = lib.mkOption {
                type = lib.types.listOf lib.types.nonEmptyStr;
                default = [ "defaults" ];
                example = [ "nofail" ];
                description = "Options used to mount the swap.";
              };

              _create = diskoLib.mkCreateOption {
                inherit config options;
                prefixed = true;
                default = ''
                  if ! test -e "$btrfs_swap__MNTPOINT/$btrfs_swap__path"; then
                    btrfs filesystem mkswapfile --size "$btrfs_swap__size" "$btrfs_swap__MNTPOINT/$btrfs_swap__path"
                  fi
                '';
              };

              _mount = diskoLib.mkMountOption {
                inherit config options;
                prefixed = true;
                default = {
                  fs = {
                    ${if parent.mountpoint != null then config.mountpoint else null} = ''
                      ${lib.strings.toShellVars {
                        inherit rootMountPoint;
                      }}
                      declare -a btrfs_swap__optionArgs=()
                      case "$btrfs_swap__discardPolicy" in
                        'both') btrfs_swap__optionArgs+=(--discard) ;;
                        ?*) btrfs_swap__optionArgs+=(--discard="$btrfs_swap__discardPolicy") ;;
                      esac
                      case "$btrfs_swap__priority" in
                        ?*) btrfs_swap__optionArgs+=(--priority="$btrfs_swap__priority") ;;
                      esac
                      btrfs_swap__optionArg='''
                      for btrfs_swap__option in "''${btrfs_swap__options[@]}"; do
                        case "$btrfs_swap__optionArg" in
                          ''') btrfs_swap__optionArg+="$btrfs_swap__option" ;;
                          ?*) btrfs_swap__optionArg+=",$btrfs_swap__option" ;;
                        esac
                      done
                      btrfs_swap__optionArgs+=("--options=$btrfs_swap__optionArg")
                      if test "''${DISKO_SKIP_SWAP:-}" != 1 && ! swapon --show | grep -q "^$(readlink -f "$rootMountPoint$btrfs_swap__mountpoint") "; then
                        swapon "''${btrfs_swap__optionArgs[@]}" "$rootMountPoint$btrfs_swap__mountpoint"
                      fi
                    '';
                  };
                };
              };

              _unmount = diskoLib.mkUnmountOption {
                inherit config options;
                prefixed = true;
                default = {
                  fs = {
                    ${if config.mountpoint == null then config.mountpoint else null} = ''
                      ${lib.strings.toShellVars {
                        inherit rootMountPoint;
                      }}
                      if swapon --show | grep -q "^$(readlink -f "$rootMountPoint$btrfs_swap__mountpoint") "; then
                        swapoff "$rootMountPoint$btrfs_swap__mountpoint"
                      fi
                    '';
                  };
                };
              };

              _config = lib.mkOption {
                internal = true;
                description = "NixOS configuration generated by disko";
                default = [
                  {
                    swapDevices = [
                      {
                        device = config.mountpoint;
                        inherit (config) discardPolicy priority options;
                      }
                    ];
                  }
                ];
              };
            };

            config = {
              _module.args.parent = swapTypeArgs.parent;
            };
          }
        )
      );
      default = { };
      description = "Swap files";
    };
in
{
  options = {
    type = lib.mkOption {
      type = lib.types.enum [ "btrfs" ];
      internal = true;
      description = "Type";
    };
    device = lib.mkOption {
      type = lib.types.str;
      default = device;
      description = "Device to use";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments";
    };
    mountOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "defaults" ];
      description = "A list of options to pass to mount.";
    };
    subvolumes = lib.mkOption {
      type = lib.types.attrsOf (
        diskoLib.mkSubType (
          {
            config,
            options,
            parent,
            ...
          }:
          {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                default = config._module.args.name;
                description = "Name of the BTRFS subvolume.";
              };
              type = lib.mkOption {
                type = lib.types.enum [ "btrfs_subvol" ];
                default = "btrfs_subvol";
                internal = true;
                description = "Type";
              };
              extraArgs = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Extra arguments";
              };
              mountOptions = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "defaults" ];
                description = "Options to pass to mount";
              };
              mountpoint = lib.mkOption {
                type = lib.types.nullOr diskoLib.optionTypes.absolute-pathname;
                default = null;
                description = "Location to mount the subvolume to.";
              };
              _mountpoint = lib.mkOption {
                type = lib.types.nullOr diskoLib.optionTypes.absolute-pathname;
                default =
                  if config.mountpoint != null then
                    config.mountpoint
                  else if parent._mountpoint != null then
                    "${parent._mountpoint}/${config.name}"
                  else
                    null;
                description = "Location to mount the subvolume to.";
                internal = true;
              };
              swap = swapType { parent = config; };
              _create = diskoLib.mkCreateOption {
                inherit config options;
                prefixed = true;
                default = ''
                  btrfs_subvol__MNTPOINT=$(mktemp -d)
                  mount "$device" "$btrfs_subvol__MNTPOINT" -o subvol=/
                  trap 'umount "$btrfs_subvol__MNTPOINT"; rm -rf "$btrfs_subvol__MNTPOINT"' EXIT
                  btrfs_subvol__ABS_PATH="$btrfs_subvol__MNTPOINT/$btrfs_subvol__name"
                  mkdir -p "$(dirname "$btrfs_subvol__ABS_PATH")"
                  if ! btrfs subvolume show "$btrfs_subvol__ABS_PATH" > /dev/null 2>&1; then
                    btrfs subvolume create "$btrfs_subvol__ABS_PATH" "''${btrfs_subvol__extraArgs[@]}"
                  fi
                '';
              };
              _mount = diskoLib.mkMountOption {
                inherit config options;
                prefixed = true;
                default = {
                  fs =
                    lib.attrsets.concatMapAttrs (_: swap: swap._mount.fs) config.swap
                    // lib.warnIf (config.mountOptions != options.mountOptions.default && config.mountpoint == null)
                      "Subvolume ${config.name} has mountOptions but no mountpoint. See upgrade guide (2023-07-09 121df48)."
                      lib.optionalAttrs
                      (config.mountpoint != null)
                      {
                        ${config.mountpoint} = ''
                          ${lib.strings.toShellVars {
                            inherit rootMountPoint;
                          }}
                          declare -a btrfs_subvol__mountOptionArgs=()
                          for btrfs_subvol__mountOption in "''${btrfs_subvol__mountOptions[@]}"; do
                            btrfs_subvol__mountOptionArgs+=(-o "$btrfs_subvol__mountOption")
                          done
                          if ! findmnt "$device" "$rootMountPoint$btrfs_subvol__mountpoint" > /dev/null 2>&1; then
                            mount "$device" "$rootMountPoint$btrfs_subvol__mountpoint" \
                            "''${btrfs_subvol__mountOptionArgs[@]}" -o "subvol=$btrfs_subvol__name" -o X-mount.mkdir
                          fi
                        '';
                      };
                };
              };
              _unmount = diskoLib.mkUnmountOption {
                inherit config options;
                prefixed = true;
                default = {
                  fs = lib.attrsets.concatMapAttrs (_: swap: swap._unmount.fs) config.swap // {
                    ${config.mountpoint} = ''
                      ${lib.strings.toShellVars {
                        inherit rootMountPoint;
                      }}
                      if findmnt "$device" "$rootMountPoint$btrfs_subvol__mountpoint" > /dev/null 2>&1; then
                        umount "$rootMountPoint$btrfs_subvol__mountpoint"
                      fi
                    '';
                  };
                };
              };
              _config = lib.mkOption {
                internal = true;
                description = "NixOS configuration generated by disko";
                default =
                  lib.optional (config.mountpoint != null) {
                    fileSystems.${config.mountpoint} = {
                      device = parent.device;
                      fsType = "btrfs";
                      options = config.mountOptions ++ [ "subvol=${config.name}" ];
                    };
                  }
                  ++ (lib.lists.concatMap (swap: swap._config) (lib.attrsets.attrValues config.swap));
              };
            };
            config = {
              _module.args.parent = btrfsConfig;

              postCreateHook = lib.mkAfter (
                lib.optionalString (config.swap != { }) (
                  diskoLib.subshell null ''
                    btrfs_swap__MNTPOINT="$btrfs_subvol__ABS_PATH"
                    ${diskoLib.concatMapLines' (swap: swap._create) (lib.attrsets.attrValues config.swap)}
                  ''
                )
              );
            };
          }
        )
      );
      default = { };
      description = "Subvolumes to define for BTRFS.";
    };
    mountpoint = lib.mkOption {
      type = lib.types.nullOr diskoLib.optionTypes.absolute-pathname;
      default = null;
      description = "A path to mount the BTRFS filesystem to.";
    };
    _mountpoint = lib.mkOption {
      type = lib.types.nullOr diskoLib.optionTypes.absolute-pathname;
      default = config.mountpoint;
      description = "A path to mount the BTRFS filesystem to.";
      internal = true;
    };
    swap = swapType { parent = config; };
    _parent = lib.mkOption {
      internal = true;
      default = parent;
    };
    _meta = lib.mkOption {
      internal = true;
      readOnly = true;
      type = lib.types.functionTo diskoLib.jsonType;
      default = _dev: { };
      description = "Metadata";
    };
    _create = diskoLib.mkCreateOption {
      inherit config options;
      default = ''
        # create the filesystem only if the device seems empty
        if ! (blkid "$device" -o export | grep -q '^TYPE='); then
          mkfs.btrfs "$device" "''${extraArgs[@]}"
        fi
      '';
    };
    _mount = diskoLib.mkMountOption {
      inherit config options;
      default = {
        fs =
          lib.attrsets.concatMapAttrs (_: subvol: subvol._mount.fs) config.subvolumes
          // lib.attrsets.concatMapAttrs (_: swap: swap._mount.fs) config.swap
          // lib.optionalAttrs (config.mountpoint != null) {
            ${config.mountpoint} = ''
              ${lib.strings.toShellVars {
                inherit rootMountPoint;
              }}
              declare -a mountOptionArgs=()
              for mountOption in "''${mountOptions[@]}"; do
                mountOptionArgs+=(-o "$mountOption")
              done
              if ! findmnt "$device" "$rootMountPoint$mountpoint" > /dev/null 2>&1; then
                mount "$device" "$rootMountPoint$mountpoint" \
                "''${mountOptionArgs[@]}" -o X-mount.mkdir
              fi
            '';
          };
      };
    };
    _unmount = diskoLib.mkUnmountOption {
      inherit config options;
      default = {
        fs =
          lib.attrsets.concatMapAttrs (_: subvol: subvol._unmount.fs) config.subvolumes
          // lib.attrsets.concatMapAttrs (_: swap: swap._unmount.fs) config.swap
          // lib.optionalAttrs (config.mountpoint != null) {
            ${config.mountpoint} = ''
              ${lib.strings.toShellVars {
                inherit rootMountPoint;
              }}
              if findmnt "$device" "$rootMountPoint$mountpoint" > /dev/null 2>&1; then
                umount "$rootMountPoint$mountpoint"
              fi
            '';
          };
      };
    };
    _config = lib.mkOption {
      internal = true;
      readOnly = true;
      default =
        lib.optional (config.mountpoint != null) {
          fileSystems.${config.mountpoint} = {
            device = config.device;
            fsType = "btrfs";
            options = config.mountOptions;
          };
        }
        ++ lib.lists.concatMap (swap: swap._config) (lib.attrsets.attrValues config.swap)
        ++ lib.lists.concatMap (subvol: subvol._config) (lib.attrsets.attrValues config.subvolumes);
      description = "NixOS configuration";
    };
    _pkgs = lib.mkOption {
      internal = true;
      readOnly = true;
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = pkgs: [
        pkgs.btrfs-progs
        pkgs.gnugrep
      ];
      description = "Packages";
    };
  };
  config = {
    postCreateHook = lib.mkAfter (
      diskoLib.concatLines' [
        (lib.optionalString (config.swap != { }) (
          diskoLib.subshell null ''
            if (blkid "$device" -o export | grep -q '^TYPE=btrfs$'); then
              btrfs_swap__MNTPOINT=$(mktemp -d)
              mount "$device" "$btrfs_swap__MNTPOINT" -o subvol=/
              trap 'umount "$btrfs_swap__MNTPOINT"; rm -rf "$btrfs_swap__MNTPOINT"' EXIT
              ${diskoLib.indent (
                diskoLib.concatMapLines' (swap: swap._create) (lib.attrsets.attrValues config.swap)
              )}
            fi
          ''
        ))
        (lib.optionalString (config.subvolumes != { }) (
          diskoLib.subshell null ''
            if (blkid "$device" -o export | grep -q '^TYPE=btrfs$'); then
              ${diskoLib.indent (
                diskoLib.concatMapLines' (subvol: subvol._create) (lib.attrsets.attrValues config.subvolumes)
              )}
            fi
          ''
        ))
      ]
    );
  };
}
