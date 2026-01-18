{
  description = "fxwm project";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/24.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });

      pkgsAarch64 = pkgsFor."aarch64-darwin";

      # Dobby source
      dobbySrc = pkgsAarch64.fetchFromGitHub {
        owner = "jmpews";
        repo = "Dobby";
        rev = "master";
        sha256 = "sha256-nTwhaQRV6GpMlIxiJ3/YGczQSol5ZTFWB8PaebKZYRQ=";
      };

      # Dobby hooking library for arm64e - using stdenvNoCC to avoid compiler hooks
      dobbyArm64e = pkgsAarch64.stdenvNoCC.mkDerivation {
        pname = "dobby-arm64e";
        version = "git";
        src = dobbySrc;
        __noChroot = true;
        dontFixup = true;
        buildPhase = ''
          # Unset nix SDK-related variables
          unset SDKROOT
          unset DEVELOPER_DIR
          unset NIX_APPLE_SDK_VERSION

          export PATH=/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin
          export HOME=/tmp

          # Now xcrun should use the real system SDK
          SYSROOT=$(xcrun --sdk macosx --show-sdk-path)
          echo "System SDKROOT: $SYSROOT"
          export SDKROOT="$SYSROOT"

          # Build with system cmake and clang
          mkdir -p build
          cmake -S . -B build \
            -DCMAKE_OSX_ARCHITECTURES=arm64e \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_SYSROOT="$SYSROOT"
          cmake --build build -j$(sysctl -n hw.ncpu)
        '';
        installPhase = ''
          mkdir -p $out/lib $out/include
          cp build/libdobby.a $out/lib/
          cp -r include/* $out/include/
        '';
      };

      # arm64e dylib (with pointer authentication) - uses system clang for arm64e support
      dylibArm64e = pkgsAarch64.stdenvNoCC.mkDerivation {
        pname = "libprotein_render-arm64e";
        version = "1.0";
        src = ./manager;
        __noChroot = true;
        dontFixup = true;
        buildPhase = ''
          # Unset nix SDK-related variables
          unset SDKROOT
          unset DEVELOPER_DIR
          unset NIX_APPLE_SDK_VERSION

          export PATH=/usr/bin:/bin:/usr/sbin
          echo "Building from directory: $(pwd)"
          echo "Contents:"
          ls -la
          xcrun clang -arch arm64e -dynamiclib -o libprotein_render.dylib \
            -I"$src" \
            -I${dobbyArm64e}/include \
            -L${dobbyArm64e}/lib -ldobby \
            -framework Foundation -framework IOSurface -framework CoreGraphics -framework QuartzCore \
            -framework Metal \
            -lc++ \
            libprotein_render.m metal_renderer.m iso_font.c sym.c
        '';
        installPhase = ''
          mkdir -p $out/lib
          cp libprotein_render.dylib $out/lib/
        '';
      };

      # arm64e fxwm binary (with pointer authentication) - uses system clang for arm64e support
      fxwmArm64e = pkgsAarch64.stdenvNoCC.mkDerivation {
        pname = "fxwm-arm64e";
        version = "1.0";
        src = ./src;
        __noChroot = true;
        dontFixup = true;
        buildPhase = ''
          # Unset nix SDK-related variables
          unset SDKROOT
          unset DEVELOPER_DIR
          unset NIX_APPLE_SDK_VERSION

          export PATH=/usr/bin:/bin:/usr/sbin
          xcrun clang -arch arm64e main.m dyld_tmp.m rw.m -o fxwm -framework Foundation
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp fxwm $out/bin/
          cp ${dylibArm64e}/lib/libprotein_render.dylib $out/
        '';
      };
    in
    {
      packages = forAllSystems (system: {
        default = fxwmArm64e;
        dylib = dylibArm64e;
        dobby = dobbyArm64e;
      });

      apps = forAllSystems (system: let pkgs = pkgsFor.${system}; in {
        default = {
          type = "app";
          program = toString (pkgs.writeShellScript "fxwm-run" ''
            cd ${fxwmArm64e}/bin
            sudo ./fxwm
          '');
        };
        compile-commands = {
          type = "app";
          program = toString (pkgs.writeShellScript "gen-compile-commands" ''
            SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
            DIR="$(pwd)"
            cat > compile_commands.json << 'JSONEOF'
 [
  {
    "directory": "DIRPLACEHOLDER/src",
    "file": "main.m",
    "arguments": ["clang", "-framework", "Foundation", "-c", "main.m"]
  },
  {
    "directory": "DIRPLACEHOLDER/src",
    "file": "dyld_tmp.m",
    "arguments": ["clang", "-framework", "Foundation", "-c", "dyld_tmp.m"]
  },
  {
    "directory": "DIRPLACEHOLDER/src",
    "file": "rw.m",
    "arguments": ["clang", "-framework", "Foundation", "-c", "rw.m"]
  },
  {
    "directory": "DIRPLACEHOLDER/manager",
    "file": "libprotein_render.m",
    "arguments": ["clang", "-dynamiclib", "-framework", "Foundation", "-c", "libprotein_render.m"]
  },
  {
    "directory": "DIRPLACEHOLDER/manager",
    "file": "metal_renderer.m",
    "arguments": ["clang", "-dynamiclib", "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore", "-c", "metal_renderer.m"]
  }
 ]
JSONEOF
            ${pkgs.gnused}/bin/sed "s#DIRPLACEHOLDER#$DIR#g" compile_commands.json | ${pkgs.gnused}/bin/sed "s#SDKPLACEHOLDER#$SDKROOT#g" > compile_commands.json.tmp
            mv compile_commands.json.tmp compile_commands.json
            echo "Generated compile_commands.json"
          '');
        };
      });
    };
}
