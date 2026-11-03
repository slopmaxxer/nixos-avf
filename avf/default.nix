{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  base = pkgs.fetchgit {
    url = "https://android.googlesource.com/platform/packages/modules/Virtualization/";
    rev = "android-16.0.0_r3";
    hash = "sha256-boWayfOI88ejnXZ5yQzYdSuMANJLB5/Wd30ZWtsXuHw=";
  };
  extraPkgs = pkgs.callPackage ./pkgs.nix { inherit base; };

  serialDevice = "ttyS0";

  mkService = name: {
    serviceConfig = {
      ExecStart = "${
        lib.getExe extraPkgs.android_virt.${name}
      } --grpc-port-file /mnt/internal/debian_service_port";
      Type = "simple";
      Restart = "on-failure";
      RestartSec = 1;
      User = "root";
      Group = "root";
      StandardOutput = "journal";
      StandardError = "journal";
    };
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "network.target"
      "mnt-internal.mount"
    ];

    restartIfChanged = false;
  };

  vmConfig = pkgs.formats.json { };

  # Android 17: the Terminal talks to ttyd over vsock port 7681, bridged to this socket
  ttydSocket = "/run/ttyd/ttyd.sock";

  cfg = config.avf;
in

with lib;
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  options = {
    avf = {
      terminal = mkOption {
        description = ''
          Android Terminal app generation this system runs under.

          16: the Terminal boots the image's own EFI partition. The image replaces the
          Terminal's disk, build_id and vm_config.json (initial/replace.sh).

          17: the Terminal boots its bundled Debian kernel and initrd directly and rejects
          foreign images ("Upgrade to newer terminal"). NixOS is installed in place on
          the Debian root filesystem (initial/install-in-place.sh) and started through
          /sbin/init; the Terminal's own files stay untouched.
        '';
        type = types.enum [
          16
          17
        ];
        default = 16;
      };

      vmConfig = mkOption {
        description = "VM config for AVF";
        default = { };
        type = vmConfig.type;
      };

      defaultUser = mkOption {
        description = "Default user to create";
        type = types.str;
        default = "droid";
      };

      extraFiles = mkOption {
        description = "Extra files to include in the image";
        type = types.attrsOf types.path;
        default = { };
        example = {
          "README.md" = ../README.md;
        };
      };

      enableConfigReplace = mkEnableOption "vm_config.json replace (WARNING ALPHA MAY BRICK INSTALL)";
      useGenericKernel = mkEnableOption "use latest standard kernel";
      enableGraphics = mkEnableOption "graphics support (Weston + gfxstream)" // {
        default = cfg.terminal == 16;
        defaultText = literalExpression "config.avf.terminal == 16";
      };
    };
  };

  config = mkMerge [
    {
      avf.vmConfig = {
        # VM name must be "debian" for display output to work
        name = "debian";
        disks = [
          {
            partitions = [
              {
                label = "ESP";
                path = "$PAYLOAD_DIR/efi_part";
                writable = true;
                guid = "{efi_part_guid}";
              }
              {
                label = "nixos";
                path = "$PAYLOAD_DIR/root_part";
                writable = true;
                guid = "{root_part_guid}";
              }
            ];
            writable = true;
          }
        ];
        sharedPath = [
          {
            sharedPath = "/storage/emulated";
          }
          {
            sharedPath = "$APP_DATA_DIR/files";
          }
        ];
        protected = false;
        cpu_topology = "match_host";
        platform_version = "~1.0";
        memory_mib = 4096;
        debuggable = true;
        console_out = true;
        console_input_device = "ttyS0";
        network = true;
        auto_memory_balloon = true;
        gpu = {
          backend = "2d";
        };
      };

      /*
        services.ttyd = {
          enable = true;
          enableSSL = true;
          caFile = = "/mnt/internal/ca.crt";
          keyFile = "/etc/ttyd/server.key";
          clientOptions = [ "disableLeaveAlert=true" ];
          certFile = "/etc/ttyd/server.ct";
          entrypoint = [ "${pkgs.shadow}/bin/login" "-f" "${cfg.defaultUser}" ];
          writeable = true;
        };
      */

      system.build.avfImage = pkgs.callPackage ./finish.nix {
        raw_disk_image = import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
          inherit pkgs lib config;

          partitionTableType = "efi";
          copyChannel = false;
          memSize = "2048";
          # make sure image can be used
          additionalSpace = "2G";
        };

        vm_config = config.system.build.vmConfig;
        extraFiles = cfg.extraFiles;
      };

      system.build.vmConfig = vmConfig.generate "vm_config.json" cfg.vmConfig;

      nix.settings.substituters = [
        "https://nix-community.cachix.org"
      ];

      nix.settings.trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];

      fileSystems."/mnt/shared" = {
        device = "android";
        fsType = "virtiofs";
      };

      services.zram-generator = {
        enable = true;
        settings = {
          "zram0" = {
            zram-size = "ram / 4";
          };

          "" = {
            compression-algorithm = "zstd";
          };
        };
      };

      users.users.${cfg.defaultUser} = {
        isNormalUser = true;
        extraGroups = [
          "${cfg.defaultUser}"
          "wheel"
        ]
        ++ lib.optionals cfg.enableGraphics [
          "video"
          "render"
          "seat"
        ];
        initialHashedPassword = "";
      };
      users.groups.${cfg.defaultUser} = { };
      security.sudo.wheelNeedsPassword = false;

      /*
        programs.bash.interactiveShellInit = ''
          # Show title of current running command
          trap 'echo -ne "\e]0;\$BASH_COMMAND\007"' DEBUG
        '';
      */

      environment.systemPackages = mkIf cfg.enableGraphics (
        with pkgs;
        [
          mesa
          weston
          libdrm
        ]
      );

      # Enable hardware acceleration
      hardware.graphics.enable = mkIf cfg.enableGraphics true;

      # Enable seatd for seat management (required for DRM access in user services)
      services.seatd.enable = mkIf cfg.enableGraphics true;

      environment.variables = mkIf cfg.enableGraphics {
        VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/gfxstream_vk_icd.${pkgs.stdenv.hostPlatform.uname.processor}.json";
        MESA_LOADER_DRIVER_OVERRIDE = "zink";
        MESA_VK_WSI_DEBUG = "sw,linear";
        WAYLAND_DISPLAY = "wayland-0";
        DISPLAY = ":0";
      };

      systemd.user.services.weston = mkIf cfg.enableGraphics {
        description = "Weston Wayland compositor";

        requires = [ "weston.socket" ];
        after = [ "weston.socket" ];
        wantedBy = [ "default.target" ];

        serviceConfig = {
          Type = "notify";
          ExecStart = "${pkgs.weston}/bin/weston --backend=drm --modules=systemd-notify.so --xwayland --shell=kiosk-shell.so --continue-without-input";
          StandardOutput = "journal";
          StandardError = "journal";
          Restart = "on-failure";
        };

        environment = {
          LIBGL_DRIVERS_PATH = "${pkgs.mesa.drivers}/lib/dri";
          LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        };
      };

      systemd.user.sockets.weston = mkIf cfg.enableGraphics {
        description = "Weston Wayland compositor socket";

        socketConfig = {
          ListenStream = "%t/wayland-0";
        };

        wantedBy = [ "sockets.target" ];
      };

      systemd.network.enable = true;
      networking.useNetworkd = true;
      networking.dhcpcd.enable = false;
      services.resolved.dnssec = "false";
      networking.useDHCP = true;
      networking.firewall.enable = true; # default
      networking.nftables.enable = true;
    }

    (mkIf (cfg.terminal == 16) {
      systemd.package = pkgs.systemd.overrideAttrs (a: {
        patches = a.patches ++ [
          ./systemd-esp-type-ignore.patch
        ];
      });

      systemd.services.ttyd = {
        serviceConfig = {
          ExecStart = "${extraPkgs.ttyd}/bin/ttyd --ssl --ssl-cert /etc/ttyd/server.crt --ssl-key /etc/ttyd/server.key --ssl-ca /mnt/internal/ca.crt -t disableLeaveAlert=true -W ${config.services.ttyd.entrypoint} -f ${cfg.defaultUser}";
          Type = "simple";
          Restart = "always";
          User = "root";
          Group = "root";
        };

        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "network.target"
          "mnt-internal.mount"
        ];

        restartIfChanged = false;
      };

      systemd.services.avahi_ttyd = {
        description = "avahi_TTYD";

        after = [
          "ttyd.service"
          "avahi-daemon.socket"
        ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          ExecStart = "${pkgs.avahi}/bin/avahi-publish-service ttyd _http._tcp 7681";
          Type = "simple";
          Restart = "always";
          User = "root";
          Group = "root";
        };
      };

      services.avahi = {
        enable = true;
        # Sometimes during startup, Terminal will discover only the IPv6 address
        # and then only whitelist that one for GRPC.
        # Remove once this is solved. See #5
        ipv6 = false;
        publish = {
          enable = true;
          userServices = true;
        };
      };

      boot.growPartition = true;
      boot.loader.systemd-boot.enable = true;
      boot.initrd.systemd.enable = true;
      boot.loader.systemd-boot.extraInstallCommands = mkIf (cfg.enableConfigReplace) ''
        # update vm_config if on live machine
        if [ -e /mnt/internal/linux ]; then
          ${pkgs.coreutils}/bin/cp -v ${config.system.build.vmConfig} /tmp/vm_config.json.new
          ${pkgs.gnused}/bin/sed -i "s/{efi_part_guid}/$(${pkgs.util-linux}/bin/sfdisk --part-uuid /dev/vda 1)/g" /tmp/vm_config.json.new
          ${pkgs.gnused}/bin/sed -i "s/{root_part_guid}/$(${pkgs.util-linux}/bin/sfdisk --part-uuid /dev/vda 2)/g" /tmp/vm_config.json.new
          ${pkgs.coreutils}/bin/mv -v /tmp/vm_config.json.new /mnt/internal/linux/vm_config.json
        fi
      '';

      # image building needs to know what device to install bootloader on
      boot.loader.grub.device = "/dev/vda";
      # Faster boot. User can't access bootloader currently anyways (?)
      boot.loader.timeout = 0;

      # avf patches only available for 6.1 right now
      boot.kernelPackages = mkIf (!cfg.useGenericKernel) pkgs.linuxPackages_6_1;

      boot.kernelPatches = mkIf (!cfg.useGenericKernel) [
        {
          name = "avf-ballon";
          patch = "${base}/build/debian/kernel/patches/avf/arm64-balloon.patch";
          ${
            if lib.versionAtLeast lib.trivial.release "25.05" then
              "structuredExtraConfig"
            else
              "extraStructuredConfig"
          } =
            with lib.kernel;
            {
              SND_VIRTIO = module;
              SND = yes;
              SOUND = yes;
            };
        }
        {
          name = "avf-cpufreq";
          patch = "${base}/build/debian/kernel/patches/avf/virtual-cpufreq.patch";
          ${
            if lib.versionAtLeast lib.trivial.release "25.05" then
              "structuredExtraConfig"
            else
              "extraStructuredConfig"
          } =
            with lib.kernel;
            {
              CPU_FREQ = yes;
              IKCONFIG = yes;
              IKCONFIG_PROC = yes;
            }
            // (
              if pkgs.stdenv.targetPlatform.isAarch64 then
                {
                  ANDROID_V_CPUFREQ_VIRT = yes;
                }
              else
                { }
            );
        }
      ];

      boot.kernelParams = [
        "console=tty1"
        "console=${serialDevice}"
      ];

      boot.kernelModules = [ "vhost_vsock" ] ++ lib.optionals cfg.enableGraphics [ "virtio_gpu" ];

      fileSystems = {
        "/" = {
          device = "/dev/disk/by-label/nixos";
          autoResize = true;
          fsType = "ext4";
        };
        "/boot" = {
          device = "/dev/disk/by-label/ESP";
          fsType = "vfat";
        };

        "/mnt/internal" = {
          device = "internal";
          fsType = "virtiofs";
        };
        /*
          "/mnt/backup" = {
            device = "/dev/vdb";
            fsType = "virtiofs";
          };
        */
      };

      # from Virtualization/guest/storage_balloon_agent/debian/service

      systemd.services.storage_balloon_agent = mkService "storage_balloon_agent";

      # from Virtualization/guest/forwarder_guest_launcher/debian/service

      systemd.services.forwarder_guest_launcher = mkService "forwarder_guest_launcher" // {
        path = [
          extraPkgs.android_virt.forwarder_guest
          pkgs.bcc
          "/run/current-system/sw"
        ];
      };

      # from Virtualization/guest/shutdown_runner/debian/service

      systemd.services.shutdown_runner = mkService "shutdown_runner";

      programs.bcc.enable = true;

      networking.firewall.allowedTCPPorts = [ 7681 ];
    })

    (mkIf (cfg.terminal == 17) {
      # The Terminal boots its bundled kernel and initrd (vm_config.json "kernel"/"initrd",
      # root=/dev/vda1), which mount the root filesystem read-only and run /sbin/init.
      # Debian keeps its kernel modules only in that initrd, so there are none to load.
      boot.kernel.enable = false;
      boot.initrd.enable = false;
      boot.loader.grub.enable = false;
      boot.loader.initScript.enable = true;

      fileSystems."/" = {
        # Partition label ROOT; not a filesystem label, a failed Terminal upgrade can
        # attach a second disk with the same filesystem label
        device = "/dev/vda1";
        autoResize = true;
        fsType = "ext4";
      };

      # The share is missing when the Terminal has no storage permission; like Debian's
      # mnt-shared.automount, don't fail the boot over it
      fileSystems."/mnt/shared".options = [
        "nofail"
        "x-systemd.automount"
      ];

      # Same as ttyd_uds.service and ttyd_vsock_bridge.{path,service} of the Debian image
      systemd.services.ttyd = {
        description = "ttyd (unix socket backend for the Terminal app)";
        serviceConfig = {
          ExecStart = "${extraPkgs.ttyd}/bin/ttyd -i ${ttydSocket} -t disableLeaveAlert=true -W ${config.services.ttyd.entrypoint} -f ${cfg.defaultUser}";
          Type = "simple";
          Restart = "always";
          RestartSec = 3;
          RuntimeDirectory = assert hasPrefix "/run/ttyd/" ttydSocket; "ttyd";
          RuntimeDirectoryMode = "0755";
        };
        wantedBy = [ "multi-user.target" ];
        # restarting would kill the open terminal sessions
        restartIfChanged = false;
      };

      systemd.services.ttyd-vsock-bridge = {
        description = "Bridge vsock port 7681 to ttyd";
        requires = [ "ttyd.service" ];
        after = [ "ttyd.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:7681,fork,reuseaddr UNIX-CONNECT:${ttydSocket}";
          Type = "simple";
          Restart = "always";
          RestartSec = 3;
        };
        restartIfChanged = false;
      };

      systemd.paths.ttyd-vsock-bridge = {
        description = "Start the ttyd vsock bridge once ttyd listens";
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathExists = ttydSocket;
      };

      # The rpfilter chain needs the nft_fib_inet module
      networking.firewall.checkReversePath = false;
    })
  ];
}
