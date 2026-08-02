{
  lib,
  rustPlatform,
  addDriverRunpath,
  cargo-tauri,
  cef-binary,
  desktop-file-utils,
  glib-networking,
  gst_all_1,
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
  stdenv,
  runtime ? if stdenv.hostPlatform.isDarwin || stdenv.hostPlatform.isAarch64 then "wry" else "cef",
  withScreenSharing ? true,
}:

assert lib.assertOneOf "runtime" runtime [
  "cef"
  "wry"
];
# cef-binary does not support aarch64-darwin
assert lib.assertMsg (
  !(stdenv.hostPlatform.isDarwin && runtime == "cef")
) "sable-desktop: CEF is unsupported on aarch64-darwin";

let
  isCef = runtime == "cef";
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
      TAURI_ENV_PLATFORM = if stdenv.hostPlatform.isDarwin then "macos" else "linux";
    };
  });
  cef =
    (cef-binary.override {
      version = "150.0.14";
      gitRevision = "7c1aa68";
      chromiumVersion = "150.0.7871.129";
      srcHashes = {
        x86_64-linux = "sha256-QO9hPkVcrNB6p8gfQl76qLb3frg/E8wo1HDuuk5h+Y8=";
        aarch64-linux = "sha256-tA4hWg9G/UDQSxXUuDO+IRjvc8Qx1cEdGOtiXg3ktk0=";
      };
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
  # fake archive.json to prevent automatically downloading CEF here
  # as per https://github.com/tauri-apps/cef-rs/issues/426
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
  buildNoDefaultFeatures = true;
  buildFeatures = [
    runtime
    "custom-protocol"
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
    pkg-config
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    wrapGAppsHook3
    desktop-file-utils
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux (
    [
      gtk3
      # needed at least until https://github.com/tauri-apps/tauri/pull/15068 gets merged
      webkitgtk_4_1
      libayatana-appindicator
    ]
    ++ lib.optionals (!isCef) (
      [ glib-networking ]
      ++ (with gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
        gst-libav
      ])
    )
  );

  preBuild = lib.optionalString isCef ''
    export CEF_PATH="$(realpath -E cef)"
    mkdir -p "$CEF_PATH"
    ln -s ${cef}/${cef.buildType}/* ${cef}/Resources/* ${cef}/libcef_dll "$CEF_PATH/"
    ln -s ${cefArchive} "$CEF_PATH/archive.json"
  '';

  preFixup =
    lib.optionalString stdenv.hostPlatform.isLinux ''
      gappsWrapperArgs+=(
        --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}"
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libayatana-appindicator ]}"
      )
    ''
    + lib.optionalString (!isCef && stdenv.hostPlatform.isLinux) ''
      gappsWrapperArgs+=(
        --prefix WEBKIT_GST_ALLOWED_URI_PROTOCOLS , "sable-media"
      )
    ''
    + lib.optionalString isCef ''
      gappsWrapperArgs+=(
        --prefix LD_LIBRARY_PATH : "${
          lib.makeLibraryPath [
            libGL
            libxkbcommon
          ]
        }:${addDriverRunpath.driverLink}/lib"
      )
    '';

  postFixup =
    lib.optionalString isCef ''
      ln -s ${cef}/${cef.buildType}/* ${cef}/Resources/* "$out/bin/"
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      desktop-file-edit \
        --set-key="Categories" --set-value="Network;InstantMessaging;Chat;" \
        --set-key="Exec" --set-value="sable %u" \
        "$out/share/applications/Sable.desktop"
    '';

  meta = {
    description = "An almost stable Matrix client";
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
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
      "aarch64-linux"
    ];
    sourceProvenance = [
      lib.sourceTypes.fromSource
    ]
    ++ lib.optional isCef lib.sourceTypes.binaryNativeCode;
  };
})
