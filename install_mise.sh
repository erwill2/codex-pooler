#!/bin/sh
set -eu

#region logging setup
if [ "${MISE_DEBUG-}" = "true" ] || [ "${MISE_DEBUG-}" = "1" ]; then
  debug() {
    echo "$@" >&2
  }
else
  debug() {
    :
  }
fi

if [ "${MISE_QUIET-}" = "1" ] || [ "${MISE_QUIET-}" = "true" ]; then
  info() {
    :
  }
else
  info() {
    echo "$@" >&2
  }
fi

warn() {
  printf '%s\n' "$*" >&2
}

error() {
  echo "$@" >&2
  exit 1
}

unsupported_arch() {
  arch="$1"
  warn "unsupported architecture: $arch"
  warn ""
  warn "mise does not provide prebuilt binaries for this platform."
  warn "If Rust/Cargo is available, install from source with:"
  warn "  cargo install --locked mise"
  exit 1
}
#endregion

#region environment setup
get_os() {
  os="$(uname -s)"
  if [ "$os" = Darwin ]; then
    echo "macos"
  elif [ "$os" = Linux ]; then
    echo "linux"
  else
    error "unsupported OS: $os"
  fi
}

get_arch() {
  musl=""
  if type ldd >/dev/null 2>/dev/null; then
    if [ "${MISE_INSTALL_MUSL-}" = "1" ] || [ "${MISE_INSTALL_MUSL-}" = "true" ]; then
      musl="-musl"
    elif [ "$(uname -o)" = "Android" ]; then
      # Android (Termux) always uses musl
      musl="-musl"
    else
      libc=$(ldd /bin/ls | grep 'musl' | head -1 | cut -d ' ' -f1)
      if [ -n "$libc" ]; then
        musl="-musl"
      fi
    fi
  fi
  arch="$(uname -m)"
  if [ "$arch" = x86_64 ]; then
    echo "x64$musl"
  elif [ "$arch" = aarch64 ] || [ "$arch" = arm64 ]; then
    echo "arm64$musl"
  elif [ "$arch" = armv7l ]; then
    echo "armv7$musl"
  else
    unsupported_arch "$arch"
  fi
}

get_ext() {
  if [ -n "${MISE_INSTALL_EXT:-}" ]; then
    echo "$MISE_INSTALL_EXT"
  elif [ -n "${MISE_VERSION:-}" ] && echo "$MISE_VERSION" | grep -q '^v2024'; then
    # 2024 versions don't have zstd tarballs
    echo "tar.gz"
  elif tar_supports_zstd; then
    echo "tar.zst"
  else
    echo "tar.gz"
  fi
}

tar_supports_zstd() {
  if ! command -v zstd >/dev/null 2>&1; then
    false
  # tar is bsdtar
  elif tar --version | grep -q 'bsdtar'; then
    true
  # busybox tar reports a "1.3x" version that matches the GNU check below, but it
  # cannot decompress .tar.zst itself. Detect it so we fall back to the zstd pipe
  # (or a .tar.gz download) instead of running `tar -xf` on a zstd tarball.
  elif tar --version 2>&1 | grep -qi 'busybox'; then
    false
  # tar version is >= 1.31
  elif tar --version | grep -q '1\.\(3[1-9]\|[4-9][0-9]\)'; then
    true
  else
    false
  fi
}

shasum_bin() {
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum"
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
  else
    error "mise install requires shasum or sha256sum but neither is installed. Aborting."
  fi
}

get_checksum() {
  version=$1
  os=$2
  arch=$3
  ext=$4
  url="https://github.com/jdx/mise/releases/download/v${version}/SHASUMS256.txt"
  current_version="v2026.7.14"
  current_version="${current_version#v}"

  # For current version use static checksum otherwise
  # use checksum from releases
  if [ "$version" = "$current_version" ]; then
    checksum_linux_x86_64="7a64615d0a594ac33a15632b0977e0a5b52a97d5d44691c63cb48397958163cf  ./mise-v2026.7.14-linux-x64.tar.gz"
    checksum_linux_x86_64_musl="c0ba6afbd5355686a7bf1e49bbbd090fdc74d5f7bcb64d979bab2d4771dc4d4b  ./mise-v2026.7.14-linux-x64-musl.tar.gz"
    checksum_linux_arm64="c89a2aecf06566ea10bf3c90075588a2c69d07a1d7af428f9a111d910fd1d8b7  ./mise-v2026.7.14-linux-arm64.tar.gz"
    checksum_linux_arm64_musl="151153deef9dc45adb2be7ef0cea6dd3f59fd578f814b4fbb0922c66ce05c60a  ./mise-v2026.7.14-linux-arm64-musl.tar.gz"
    checksum_linux_armv7="fa0dd5aa930c4081157d8647edb480d7e99115ef09317d592cc970b8b9b8f70a  ./mise-v2026.7.14-linux-armv7.tar.gz"
    checksum_linux_armv7_musl="6848ca44de49cf0fad7d15bae629664ef129b975c4eb95a6d7483bb8302fdc9e  ./mise-v2026.7.14-linux-armv7-musl.tar.gz"
    checksum_macos_x86_64="5d21aa0a1e491260ddecb6aca07a5f5975d21e69eb6e3293df677f3722fcf2ba  ./mise-v2026.7.14-macos-x64.tar.gz"
    checksum_macos_arm64="7b2635ddc908e2b009cc8bf77daa24738eb2cf6fe611ced129b47bc407e3b9fe  ./mise-v2026.7.14-macos-arm64.tar.gz"
    checksum_linux_x86_64_zstd="6566d180fec4bcfc3d740162382b2029d6c12bb3d5ead6317626ae5c3c59d2c2  ./mise-v2026.7.14-linux-x64.tar.zst"
    checksum_linux_x86_64_musl_zstd="b6cd4316f628338e95511d3fbfe055773c3547efba4fb06cf817a36b9f0294f3  ./mise-v2026.7.14-linux-x64-musl.tar.zst"
    checksum_linux_arm64_zstd="fdf9851847e23f898c248bd2ca110458fb18cc5222611186beecbc9d0e5d95ff  ./mise-v2026.7.14-linux-arm64.tar.zst"
    checksum_linux_arm64_musl_zstd="53916b6b9cd0cdd1bda759ae79a31ca05db11d135b7eab987c794848cd20239f  ./mise-v2026.7.14-linux-arm64-musl.tar.zst"
    checksum_linux_armv7_zstd="920a75cf487da428dda8fa6ff18331741d5f41a73293aa08cc14da5510b1bef1  ./mise-v2026.7.14-linux-armv7.tar.zst"
    checksum_linux_armv7_musl_zstd="6419e2780d31a1e79f977fa3ff5b82e1c065d78d5f98f12bb052176948d0c44f  ./mise-v2026.7.14-linux-armv7-musl.tar.zst"
    checksum_macos_x86_64_zstd="740f1447c8e36f767256a3da3db75f674ac55dbad99cbf2eb51dc4ae92bbb5e3  ./mise-v2026.7.14-macos-x64.tar.zst"
    checksum_macos_arm64_zstd="2d3951e999f9ec78c0aedffb5869deb205c82003eab0ee763cd90417106219db  ./mise-v2026.7.14-macos-arm64.tar.zst"

    # TODO: refactor this, it's a bit messy
    if [ "$ext" = "tar.zst" ]; then
      if [ "$os" = "linux" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_linux_x86_64_zstd"
        elif [ "$arch" = "x64-musl" ]; then
          echo "$checksum_linux_x86_64_musl_zstd"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_linux_arm64_zstd"
        elif [ "$arch" = "arm64-musl" ]; then
          echo "$checksum_linux_arm64_musl_zstd"
        elif [ "$arch" = "armv7" ]; then
          echo "$checksum_linux_armv7_zstd"
        elif [ "$arch" = "armv7-musl" ]; then
          echo "$checksum_linux_armv7_musl_zstd"
        else
          warn "no checksum for $os-$arch"
        fi
      elif [ "$os" = "macos" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_macos_x86_64_zstd"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_macos_arm64_zstd"
        else
          warn "no checksum for $os-$arch"
        fi
      else
        warn "no checksum for $os-$arch"
      fi
    else
      if [ "$os" = "linux" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_linux_x86_64"
        elif [ "$arch" = "x64-musl" ]; then
          echo "$checksum_linux_x86_64_musl"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_linux_arm64"
        elif [ "$arch" = "arm64-musl" ]; then
          echo "$checksum_linux_arm64_musl"
        elif [ "$arch" = "armv7" ]; then
          echo "$checksum_linux_armv7"
        elif [ "$arch" = "armv7-musl" ]; then
          echo "$checksum_linux_armv7_musl"
        else
          warn "no checksum for $os-$arch"
        fi
      elif [ "$os" = "macos" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_macos_x86_64"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_macos_arm64"
        else
          warn "no checksum for $os-$arch"
        fi
      else
        warn "no checksum for $os-$arch"
      fi
    fi
  else
    if command -v curl >/dev/null 2>&1; then
      debug ">" curl -fsSL "$url"
      checksums="$(curl --compressed -fsSL "$url")"
    else
      if command -v wget >/dev/null 2>&1; then
        debug ">" wget -qO - "$url"
        checksums="$(wget -qO - "$url")"
      else
        error "mise standalone install specific version requires curl or wget but neither is installed. Aborting."
      fi
    fi
    # TODO: verify with minisign or gpg if available

    checksum="$(echo "$checksums" | grep "$os-$arch.$ext")"
    if ! echo "$checksum" | grep -Eq "^([0-9a-f]{32}|[0-9a-f]{64})"; then
      warn "no checksum for mise $version and $os-$arch"
    else
      echo "$checksum"
    fi
  fi
}

#endregion

download_file() {
  url="$1"
  download_dir="$2"
  filename="$(basename "$url")"
  file="$download_dir/$filename"

  info "mise: installing mise..."

  if command -v curl >/dev/null 2>&1; then
    debug ">" curl -#fLo "$file" "$url"
    curl -#fLo "$file" "$url"
  else
    if command -v wget >/dev/null 2>&1; then
      debug ">" wget -qO "$file" "$url"
      stderr=$(mktemp)
      wget -O "$file" "$url" >"$stderr" 2>&1 || error "wget failed: $(cat "$stderr")"
      rm "$stderr"
    else
      error "mise standalone install requires curl or wget but neither is installed. Aborting."
    fi
  fi

  echo "$file"
}

# Prints the version of an installed mise binary (the first field of
# `mise version`, e.g. "2025.6.0"), with any leading "v" stripped. Prints
# nothing if the binary is missing or fails to report a version.
installed_mise_version() {
  bin="$1"
  if [ -x "$bin" ]; then
    installed_version="$("$bin" version 2>/dev/null | head -n1 | cut -d' ' -f1)"
    echo "${installed_version#v}"
  fi
}

install_mise() {
  version="${MISE_VERSION:-v2026.7.14}"
  version="${version#v}"
  current_version="v2026.7.14"
  current_version="${current_version#v}"
  os="${MISE_INSTALL_OS:-$(get_os)}"
  arch="${MISE_INSTALL_ARCH:-$(get_arch)}"
  ext="${MISE_INSTALL_EXT:-$(get_ext)}"
  install_path="${MISE_INSTALL_PATH:-$HOME/.local/bin/mise}"
  install_dir="$(dirname "$install_path")"
  install_from_github="${MISE_INSTALL_FROM_GITHUB:-}"

  # Opt-in: skip the download/install if the binary already at the install
  # path matches the requested version. Only the install path is checked (not
  # the wider PATH) so that skipping never leaves install_path missing.
  skip_if_exists="${MISE_INSTALL_SKIP_IF_EXISTS-}"
  if [ "$skip_if_exists" = "1" ] || [ "$skip_if_exists" = "true" ]; then
    if [ -x "$install_path" ]; then
      existing_version="$(installed_mise_version "$install_path")"
      if [ -n "$existing_version" ] && [ "$existing_version" = "$version" ]; then
        info "mise: $install_path is already at version $version, skipping install"
        return 0
      fi
    fi
  fi
  if [ "$version" != "$current_version" ] || [ "$install_from_github" = "1" ] || [ "$install_from_github" = "true" ]; then
    tarball_url="https://github.com/jdx/mise/releases/download/v${version}/mise-v${version}-${os}-${arch}.${ext}"
  elif [ -n "${MISE_TARBALL_URL-}" ]; then
    tarball_url="$MISE_TARBALL_URL"
  else
    tarball_url="https://mise.jdx.dev/v${version}/mise-v${version}-${os}-${arch}.${ext}"
  fi

  download_dir="$(mktemp -d)"
  cache_file=$(download_file "$tarball_url" "$download_dir")
  debug "mise-setup: tarball=$cache_file"

  debug "validating checksum"
  cd "$(dirname "$cache_file")" && get_checksum "$version" "$os" "$arch" "$ext" | "$(shasum_bin)" -c >/dev/null

  # extract tarball
  if [ -d "$install_path" ]; then
    error "MISE_INSTALL_PATH '$install_path' is a directory. Please set it to a file path, e.g. '$install_path/mise'."
  fi
  mkdir -p "$install_dir"
  rm -f "$install_path"
  extract_dir="$(mktemp -d)"
  cd "$extract_dir"
  if [ "$ext" = "tar.zst" ] && ! tar_supports_zstd; then
    zstd -d -c "$cache_file" | tar --no-same-owner -xf -
  else
    tar --no-same-owner -xf "$cache_file"
  fi
  if [ "$(id -u)" = "0" ]; then
    chown 0:0 mise/bin/mise
    chmod 755 mise/bin/mise
  fi
  mv mise/bin/mise "$install_path"

  # cleanup
  cd / # Move out of $extract_dir before removing it
  rm -rf "$download_dir"
  rm -rf "$extract_dir"

  info "mise: installed successfully to $install_path"
}

after_finish_help() {
  case "${SHELL:-}" in
  */zsh)
    info "mise: run the following to activate mise in your shell:"
    info "echo \"eval \\\"\\\$($install_path activate zsh)\\\"\" >> \"${ZDOTDIR-$HOME}/.zshrc\""
    info ""
    info "mise: run \`mise doctor\` to verify this is set up correctly"
    ;;
  */bash)
    info "mise: run the following to activate mise in your shell:"
    info "echo \"eval \\\"\\\$($install_path activate bash)\\\"\" >> ~/.bashrc"
    info ""
    info "mise: run \`mise doctor\` to verify this is set up correctly"
    ;;
  */fish)
    info "mise: run the following to activate mise in your shell:"
    info "echo \"$install_path activate fish | source\" >> ~/.config/fish/config.fish"
    info ""
    info "mise: run \`mise doctor\` to verify this is set up correctly"
    ;;
  *)
    info "mise: run \`$install_path --help\` to get started"
    ;;
  esac
}

install_mise
if [ "${MISE_INSTALL_HELP-}" != 0 ]; then
  after_finish_help
fi
