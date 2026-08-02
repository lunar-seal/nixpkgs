{
  lib,
  rustPlatform,
  addDriverRunpath,
  cargo-tauri,
  cef-binary,
  desktop-file-utils,
  gtk3,
  libGL,
  libpulseaudio,
  libxkbcommon,
  pipewire,
  pkg-config,
  sable-unwrapped,
  webkitgtk_4_1,
  writeText,
  xdg-utils,
  libayatana-appindicator,
  wrapGAppsHook3,
  withScreenSharing ? true,
}:

let
  frontend = sable-unwrapped.overrideAttrs (oldAttrs: {
    version = "1.20.1-nightly.260730155923";
    src = oldAttrs.src.override {
      rev = "fd5c07b641ba44efc44f0e0e1abd687146067c25";
      tag = null;
      hash = "sha256-laWNK7e3xFjW42smGyFJYrayg7AyRIz8WOhk4Ft/41I=";
    };
    pnpmDeps = oldAttrs.pnpmDeps.overrideAttrs {
      outputHash = "sha256-RUyjP9tJ9BrF23IvbvDujXFDn6be0ddxV5b4etMJDeg=";
    };
    env = oldAttrs.env // {
      TAURI_ENV_PLATFORM = "linux";
    };
  });
  cef =
    (cef-binary.override {
      version = "150.0.14";
      gitRevision = "7c1aa68";
      chromiumVersion = "150.0.7871.129";
      srcHashes.x86_64-linux = "sha256-QO9hPkVcrNB6p8gfQl76qLb3frg/E8wo1HDuuk5h+Y8=";
    }).overrideAttrs
      (_: {
        dontStrip = false;
        stripAllList = [ "Release" ];
        # needs libpulseaudio/pipewire for voicechat/screensharing
        postInstall = ''
          patchelf --add-rpath "${
            lib.makeLibraryPath ([ libpulseaudio ] ++ lib.optional withScreenSharing pipewire)
          }" "$out/Release/libcef.so"
        '';
      });
  # https://github.com/tauri-apps/cef-rs/issues/426
  cefArchive = writeText "archive.json" (
    builtins.toJSON {
      name = cef.src.name;
      sha1 = "";
      type = "minimal";
    }
  );
in
rustPlatform.buildRustPackage (finalAttrs: {
  __structuredAttrs = true;

  pname = "sable-desktop";
  inherit (frontend) version src;

  cargoRoot = "src-tauri";
  buildAndTestSubdir = finalAttrs.cargoRoot;

  cargoHash = "sha256-sokkOw0ByGUx6GE8ZulaSVXgTsNkrtOLx3pZQqevleM=";
  cargoDepsName = finalAttrs.pname;

  tauriBuildFlags = "--no-sign";
  tauriBundleType = "deb";
  buildNoDefaultFeatures = true;
  buildFeatures = [
    "custom-protocol"
    "cef"
  ];

  postPatch = ''
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail '"frontendDist": "../dist"' '"frontendDist": "${frontend}"' \
      --replace-fail '"beforeBuildCommand": "pnpm build"' '"beforeBuildCommand": "true"'
    substituteInPlace src-tauri/src/lib.rs \
      --replace-fail "                use tauri_plugin_deep_link::DeepLinkExt;" "" \
      --replace-fail "                app.deep_link().register_all()?;" ""
  '';

  nativeBuildInputs = [
    cargo-tauri.hook
    wrapGAppsHook3
    desktop-file-utils
    pkg-config
  ];

  buildInputs = [
    gtk3
    # needed at least until https://github.com/tauri-apps/tauri/pull/15068 gets merged
    webkitgtk_4_1
    libayatana-appindicator
  ];

  preBuild = ''
    export CEF_PATH="$(realpath -E cef)"
    mkdir -p "$CEF_PATH"
    ln -s ${cef}/${cef.buildType}/* ${cef}/Resources/* ${cef}/libcef_dll "$CEF_PATH/"
    ln -s ${cefArchive} "$CEF_PATH/archive.json"
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}"
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libayatana-appindicator
          libGL
          libxkbcommon
        ]
      }:${addDriverRunpath.driverLink}/lib"
    )
  '';

  postFixup = ''
    ln -s ${cef}/${cef.buildType}/* ${cef}/Resources/* "$out/bin/"
    desktop-file-edit \
      --set-key="Categories" --set-value="Network;InstantMessaging;Chat;" \
      --set-key="Exec" --set-value="sable %u" \
      "$out/share/applications/Sable.desktop"
  '';

  meta = {
    description = "Almost stable Matrix client focused on quality-of-life features";
    homepage = "https://github.com/SableClient/Sable";
    changelog = "https://github.com/SableClient/Sable/blob/${finalAttrs.src.rev}/CHANGELOG.md";
    maintainers = with lib.maintainers; [
      lunar-seal
    ];
    license = with lib.licenses; [
      agpl3Only
      bsd3
    ];
    mainProgram = "sable";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode
    ];
  };
})
