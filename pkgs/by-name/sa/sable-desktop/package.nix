{
  lib,
  rustPlatform,
  addDriverRunpath,
  cargo-tauri,
  cef-binary,
  desktop-file-utils,
  fetchFromGitHub,
  fetchPnpmDeps,
  gtk3,
  libGL,
  libpulseaudio,
  libxkbcommon,
  nix-update-script,
  nodejs-slim_24,
  pipewire,
  pkg-config,
  pnpm_10,
  pnpmConfigHook,
  swift,
  swiftpm,
  symlinkJoin,
  webkitgtk_4_1,
  writeText,
  xdg-utils,
  libayatana-appindicator,
  wrapGAppsHook3,
  stdenv,
  runtime ? if stdenv.hostPlatform.isLinux then "cef" else "wry",
}:

#todo: wry on linux will not work with this flake, wait on what upstream does
assert lib.assertOneOf "runtime" runtime [
  "cef"
  "wry"
];

let
  isCef = runtime == "cef";
  nodejs-slim = nodejs-slim_24;
  pnpm = pnpm_10.override { inherit nodejs-slim; };
  cef = cef-binary.override {
    version = "150.0.14";
    gitRevision = "7c1aa68";
    chromiumVersion = "150.0.7871.129";
    srcHashes = {
      x86_64-linux = "sha256-QO9hPkVcrNB6p8gfQl76qLb3frg/E8wo1HDuuk5h+Y8=";
      aarch64-linux = "sha256-tA4hWg9G/UDQSxXUuDO+IRjvc8Qx1cEdGOtiXg3ktk0=";
    };
  };
  # fake archive.json to prevent automatically downloading CEF here
  # as per https://github.com/tauri-apps/cef-rs/issues/426
  fakeArchiveJson = writeText "archive.json" (
    builtins.toJSON {
      name = cef.src.name;
      sha1 = "";
      type = "minimal";
    }
  );
  cefFlat = symlinkJoin {
    name = "cef-${cef.version}-flat";
    paths = [
      "${cef}/${cef.buildType}"
      "${cef}/Resources"
    ];
    postBuild = ''
      ln -s ${cef}/libcef_dll "$out/"
      ln -s ${fakeArchiveJson} "$out/archive.json"
    '';
  };
in
rustPlatform.buildRustPackage (finalAttrs: {
  __darwinAllowLocalNetworking = true;
  __structuredAttrs = true;

  pname = "sable-desktop";
  version = "nightly-unstable-2026-08-12";

  src = fetchFromGitHub {
    owner = "SableClient";
    repo = "Sable";
    rev = "6ce0c5c565710dd57dc33f775acab3c9495ae5ef";
    hash = "sha256-ALFlg1ckceIctm0mNcACGB/tx6/KsOZGkhQlMKmUo4U=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 3;
    hash = "sha256-/24e3haQyRY2YMmnm4SEtDgDeA0o+/V5SXNLdSld+CM=";
  };

  env = {
    VITE_BUILD_HASH = finalAttrs.src.rev;
    VITE_IS_RELEASE_TAG = "true";
  }
  // lib.optionalAttrs isCef { CEF_PATH = "${cefFlat}"; };

  cargoRoot = "src-tauri";
  buildAndTestSubdir = finalAttrs.cargoRoot;

  cargoHash = "sha256-oDgEXNatSnCpq1WZ4o1fnAg/J8gSqRuoJBQkIRL9XU8=";
  cargoDepsName = finalAttrs.pname;

  tauriBuildFlags = "--no-sign";
  buildNoDefaultFeatures = true;
  buildFeatures = [
    runtime
    "custom-protocol"
  ];

  postPatch = ''
    substituteInPlace src-tauri/src/lib.rs \
      --replace-fail "                use tauri_plugin_deep_link::DeepLinkExt;" "" \
      --replace-fail "                app.deep_link().register_all()?;" ""
  '';

  nativeBuildInputs = [
    cargo-tauri.hook
    nodejs-slim
    pkg-config
    pnpm
    pnpmConfigHook
  ]
  ++ lib.optionals isCef [
    wrapGAppsHook3
    desktop-file-utils
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    swift
    swiftpm
  ];

  buildInputs = lib.optionals isCef [
    gtk3
    # needed at least until https://github.com/tauri-apps/tauri/pull/15068 gets merged
    webkitgtk_4_1
    libayatana-appindicator
  ];

  preFixup = lib.optionalString isCef ''
    gappsWrapperArgs+=(
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}"
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libayatana-appindicator
          libGL
          libxkbcommon
          libpulseaudio
          pipewire
        ]
      }:${addDriverRunpath.driverLink}/lib"
    )
  '';

  postFixup = lib.optionalString isCef ''
    ln -s ${cef}/${cef.buildType}/* ${cef}/Resources/* "$out/bin/"
    desktop-file-edit \
      --set-key="Categories" --set-value="Network;InstantMessaging;Chat;" \
      --set-key="Exec" --set-value="sable %u" \
      "$out/share/applications/Sable.desktop"
  '';

  passthru.updateScript = nix-update-script { extraArgs = [ "--version=branch" ]; };

  meta = {
    description = "An almost stable Matrix client";
    homepage = "https://github.com/SableClient/Sable";
    changelog = "https://github.com/SableClient/Sable/blob/${finalAttrs.src.rev}/CHANGELOG.md";
    maintainers = with lib.maintainers; [
      toasteruwu
      lunar-seal
    ];
    license = [
      lib.licenses.agpl3Only
    ];
    mainProgram = "sable";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
      "aarch64-linux"
    ];
  };
})
