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
  swapType = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            size = lib.mkOption {
              type = lib.types.strMatching "^([0-9]+[KMGTP])?$";
              description = "Size of the swap file (e.g. 2G)";
            };

            path = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Path to the swap file (relative to the mountpoint)";
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
          };
        }
      )
    );
    default = { };
    description = "Swap files";
  };

  swapConfig =
    { mountpoint, swap }:
    {
      swapDevices = builtins.map (file: {
        device = "${mountpoint}/${file.path}";
        inherit (file) priority options;
      }) (lib.attrValues swap);
    };

  swapCreate =
    swap:
    lib.concatMapStringsSep "\n" (file: ''
      ${lib.strings.toShellVars {
        btrfs_swap__path = file.path;
        btrfs_swap__size = file.size;
      }}
      if ! test -e "$btrfs_swap__MNTPOINT/$btrfs_swap__path"; then
        btrfs filesystem mkswapfile --size "$btrfs_swap__size" "$btrfs_swap__MNTPOINT/$btrfs_swap__path"
      fi
    '') (lib.attrValues swap);

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
        lib.types.submodule (
          { config, ... }:
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
              swap = swapType;
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
    swap = swapType;
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
        ${lib.optionalString (config.swap != { } || config.subvolumes != { }) ''
          if (blkid "$device" -o export | grep -q '^TYPE=btrfs$'); then
            ${lib.optionalString (config.swap != { }) (
              diskoLib.indent ''
                (
                  btrfs_swap__MNTPOINT=$(mktemp -d)
                  mount "$device" "$btrfs_swap__MNTPOINT" -o subvol=/
                  trap 'umount "$btrfs_swap__MNTPOINT"; rm -rf "$btrfs_swap__MNTPOINT"' EXIT
                  ${diskoLib.indent (swapCreate config.swap)}
                )
              ''
            )}
            ${lib.concatMapStrings (
              subvol:
              diskoLib.indent ''
                (
                  ${diskoLib.indent (
                    lib.strings.toShellVars {
                      btrfs_subvol__name = subvol.name;
                      btrfs_subvol__extraArgs = subvol.extraArgs;
                    }
                  )}
                  btrfs_subvol__MNTPOINT=$(mktemp -d)
                  mount "$device" "$btrfs_subvol__MNTPOINT" -o subvol=/
                  trap 'umount "$btrfs_subvol__MNTPOINT"; rm -rf "$btrfs_subvol__MNTPOINT"' EXIT
                  btrfs_subvol__ABS_PATH="$btrfs_subvol__MNTPOINT/$btrfs_subvol__name"
                  mkdir -p "$(dirname "$btrfs_subvol__ABS_PATH")"
                  if ! btrfs subvolume show "$btrfs_subvol__ABS_PATH" > /dev/null 2>&1; then
                    btrfs subvolume create "$btrfs_subvol__ABS_PATH" "''${btrfs_subvol__extraArgs[@]}"
                  fi
                  btrfs_swap__MNTPOINT="$btrfs_subvol__ABS_PATH"
                  ${diskoLib.indent (swapCreate subvol.swap)}
                )
              ''
            ) (lib.attrValues config.subvolumes)}
          fi
        ''}
      '';
    };
    _mount = diskoLib.mkMountOption {
      inherit config options;
      default =
        let
          subvolMounts = lib.concatMapAttrs (
            _: subvol:
            lib.warnIf
              (
                subvol.mountOptions != (options.subvolumes.type.getSubOptions [ ]).mountOptions.default
                && subvol.mountpoint == null
              )
              "Subvolume ${subvol.name} has mountOptions but no mountpoint. See upgrade guide (2023-07-09 121df48)."
              lib.optionalAttrs
              (subvol.mountpoint != null)
              {
                ${subvol.mountpoint} = ''
                  ${lib.strings.toShellVars {
                    inherit rootMountPoint;
                    btrfs_subvol__mountOptions = subvol.mountOptions;
                    btrfs_subvol__mountpoint = subvol.mountpoint;
                    btrfs_subvol__name = subvol.name;
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
              }
          ) config.subvolumes;
        in
        {
          fs =
            subvolMounts
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
      default =
        let
          subvolMounts = lib.concatMapAttrs (
            _: subvol:
            lib.optionalAttrs (subvol.mountpoint != null) {
              ${subvol.mountpoint} = ''
                ${lib.strings.toShellVars {
                  inherit rootMountPoint;
                  btrfs_subvol__mountpoint = subvol.mountpoint;
                }}
                if findmnt "$device" "$rootMountPoint$btrfs_subvol__mountpoint" > /dev/null 2>&1; then
                  umount "$rootMountPoint$btrfs_subvol__mountpoint"
                fi
              '';
            }
          ) config.subvolumes;
        in
        {
          fs =
            subvolMounts
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
      default = [
        (map (
          subvol:
          lib.optional (subvol.mountpoint != null) {
            fileSystems.${subvol.mountpoint} = {
              device = config.device;
              fsType = "btrfs";
              options = subvol.mountOptions ++ [ "subvol=${subvol.name}" ];
            };
          }
        ) (lib.attrValues config.subvolumes))
        (lib.optional (config.mountpoint != null) {
          fileSystems.${config.mountpoint} = {
            device = config.device;
            fsType = "btrfs";
            options = config.mountOptions;
          };
        })
        (map (
          subvol:
          swapConfig {
            inherit (subvol) mountpoint swap;
          }
        ) (lib.attrValues config.subvolumes))
        (swapConfig {
          inherit (config) mountpoint swap;
        })
      ];
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
}
