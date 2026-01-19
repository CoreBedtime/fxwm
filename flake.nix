{
  description = "fxwm project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/24.11";
    nix-deboogey.url = "github:aspauldingcode/nix-deboogey";
  };

  outputs = { self, nixpkgs, nix-deboogey }:
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

          # Build with nix cmake and xcode clang
          mkdir -p build
          ${pkgsAarch64.cmake}/bin/cmake -S . -B build \
            -DCMAKE_OSX_ARCHITECTURES=arm64e \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_SYSROOT="$SYSROOT" \
            -DCMAKE_C_COMPILER=$(xcrun -find clang) \
            -DCMAKE_CXX_COMPILER=$(xcrun -find clang++)
          ${pkgsAarch64.cmake}/bin/cmake --build build -j$(sysctl -n hw.ncpu)
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
            -framework Metal -framework CoreServices \
            -lc++ \
            libprotein_render.m logonview.m mouse_events.m keyboard_events.m metal_renderer.m ui.m iso_font.c sym.c
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
            sudo launchctl reboot userspace
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
    "file": "mouse_events.m",
    "arguments": ["clang", "-dynamiclib", "-framework", "Foundation", "-c", "mouse_events.m"]
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
        test-tahoe = {
          type = "app";
          program = toString (pkgs.writeShellScript "test-tahoe-tmux" ''
            set -euo pipefail

            # Dependencies
            TMUX="${pkgs.tmux}/bin/tmux"
            TAHOE="${nix-deboogey.packages.${system}.tahoe}/bin/tahoe"
            SSHPASS_BIN="${pkgs.sshpass}/bin/sshpass"
            NC="${pkgs.netcat}/bin/nc"
            RSYNC="${pkgs.rsync}/bin/rsync"
            FSWATCH="${pkgs.fswatch}/bin/fswatch"

            SESSION="tahoe-dev"
            LOCAL_REPO="$(pwd)"
            REMOTE_DIR="Desktop/fxwm"

            # Kill existing session if it exists
            $TMUX kill-session -t "$SESSION" 2>/dev/null || true

            # Create new tmux session with the VM runner in the first pane
            # If the VM stops, wait for user input before killing the session
            $TMUX new-session -d -s "$SESSION" -n "vm" "$TAHOE; echo; echo 'VM process exited.'; read -p 'Press Enter to close session...' ; $TMUX kill-session -t \"$SESSION\""
            
            # Add a hook: if pane 0 (the VM) is CLOSED (manually), kill the whole session
            $TMUX set-hook -t "$SESSION" pane-exited 'if-shell "[ #{pane_index} -eq 0 ]" "kill-session"'

            # Wait for VM to be ready (poll for IP using nix-deboogey's tart-ip)
            TART_IP="${nix-deboogey.packages.${system}.tart-ip}/bin/tart-ip"
            echo "⏳ Waiting for VM to boot and get IP..."
            VM_IP=""
            for i in {1..60}; do
              VM_IP=$($TART_IP deboogey-tahoe 2>/dev/null | tr -d '[:space:]' || true)
              if [[ -n "$VM_IP" ]]; then
                break
              fi
              sleep 2
            done

            if [[ -z "$VM_IP" ]]; then
              echo "❌ Failed to get VM IP after 2 minutes"
              echo "   Attaching to tmux anyway - check VM pane for status"
              $TMUX attach-session -t "$SESSION"
              exit 1
            fi

            echo "✅ VM ready at $VM_IP"

            # Wait for SSH to be available before opening panes
            echo "⏳ Waiting for SSH (IP: $VM_IP) to be ready..."
            for i in {1..60}; do
              if $NC -w 2 -z "$VM_IP" 22 2>/dev/null; then
                echo "✅ SSH is ready!"
                break
              fi
              # If we've waited too long, maybe re-check the IP?
              if (( i % 10 == 0 )); then
                NEW_IP=$($TART_IP deboogey-tahoe 2>/dev/null | tr -d '[:space:]' || true)
                if [[ -n "$NEW_IP" && "$NEW_IP" != "$VM_IP" ]]; then
                   echo "🔄 IP changed from $VM_IP to $NEW_IP, updating..."
                   VM_IP="$NEW_IP"
                fi
              fi
              sleep 2
            done

            # Additional delay to ensure SSH daemon is fully ready
            sleep 3

            # Clear any stale sentinel file
            $SSHPASS_BIN -p admin ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes admin@$VM_IP "rm -f /tmp/initial_sync_done"

            # Sync local repo to VM
            echo "📦 Syncing local repo to VM:~/$REMOTE_DIR..."
            export SSHPASS=admin
            $RSYNC -avz --delete \
              --exclude '.git' \
              --exclude '.direnv' \
              --exclude 'result' \
              --exclude '*.o' \
              --exclude '*.dylib' \
              -e "$SSHPASS_BIN -e ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null" \
              "$LOCAL_REPO/" "admin@$VM_IP:$REMOTE_DIR/"
            
            # Create a sentinel file to tell the SSH pane we are ready
            $SSHPASS_BIN -p admin ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes admin@$VM_IP "touch /tmp/initial_sync_done"
            echo "✅ Initial sync complete!"

            # Split horizontally and open SSH with retry loop
            # Automatically cd to the project and nix run
            $TMUX split-window -h -t "$SESSION:vm" "
              echo 'Connecting to SSH...'
              for attempt in {1..30}; do
                $SSHPASS_BIN -p admin ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=5 admin@$VM_IP -t \"
                  export PATH=\\\"/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:\\\$PATH\\\"
                  echo '⏳ Waiting for initial sync to finalize...'
                  while [ ! -f /tmp/initial_sync_done ]; do sleep 0.5; done
                  
                  # Source profiles to get the full environment (Nix, etc.)
                  [ -e /etc/profile ] && . /etc/profile
                  [ -e /etc/zshrc ] && . /etc/zshrc
                  [ -e ~/.zprofile ] && . ~/.zprofile
                  [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
                  
                  cd $REMOTE_DIR
                  echo '🚀 Initial sync complete. Running nix run...'
                  zsh -c \\\"nix run .\\\"
                  exec zsh -l
                \" && break
                echo \"SSH connection failed, retrying... (\$attempt/30)\"
                sleep 2
              done
              read -p 'SSH disconnected. Press Enter to close...'
            "

            # Split the SSH pane vertically and open file sync watcher
            $TMUX split-window -v -t "$SESSION:vm.1" "
              echo '📁 File Sync Watcher'
              echo '==================='
              echo 'Watching: $LOCAL_REPO'
              echo 'Syncing to: admin@$VM_IP:~/$REMOTE_DIR'
              echo
              echo 'Changes will be synced automatically.'
              echo 'Press Ctrl+C to stop watching.'
              echo
              
              sync_files() {
                echo
                echo \"🔄 [\$(date '+%H:%M:%S')] Syncing changes...\"
                export SSHPASS=admin
                $RSYNC -avz --delete \\
                  --exclude '.git' \\
                  --exclude '.direnv' \\
                  --exclude 'result' \\
                  --exclude '*.o' \\
                  --exclude '*.dylib' \\
                  -e \"$SSHPASS_BIN -e ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null\" \\
                  \"$LOCAL_REPO/\" \"admin@$VM_IP:$REMOTE_DIR/\" 2>&1 | grep -v '^sending\\|^sent\\|^total\\|^$' || true
                echo \"✅ Sync complete\"
              }
              
              # Watch for file changes and sync
              $FSWATCH -o '$LOCAL_REPO' --exclude '.git' --exclude '.direnv' --exclude 'result' | while read -r; do
                sync_files
              done
            "

            # Set layout to main-vertical (VM on left, SSH/Sync stacked on right)
            $TMUX select-layout -t "$SESSION:vm" main-vertical

            # Ensure pane 0 (VM) is focused
            $TMUX select-pane -t "$SESSION:vm.0"

            # Attach to the session
            echo "🚀 Attaching to tmux session '$SESSION'..."
            echo "   Pane 0: VM runner"
            echo "   Pane 1: SSH session"
            echo "   Pane 2: File sync watcher (auto-syncs on changes)"
            echo ""
            echo "   Use Ctrl+B then arrow keys to switch panes"
            echo "   Use Ctrl+B then D to detach"
            echo ""
            $TMUX attach-session -t "$SESSION"
          '');
        };
      });
    };
}
