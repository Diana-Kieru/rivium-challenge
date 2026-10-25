#!/usr/bin/env bash
# Build a debug APK for each Android project affected by this pull request.
# Submissions do not share one layout: some keep Gradle under android/ or
# client/, and some compile Rust from scripts/build-android*.sh while others
# expect `cargo ndk` before Gradle.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

apk_count=0
failures=0
should_build=false
dist="$repo_root/dist/apks"
mkdir -p "$dist"

on_exit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "apk_count=$apk_count" >> "$GITHUB_OUTPUT"
    echo "should_build=$should_build" >> "$GITHUB_OUTPUT"
  fi
}
trap on_exit EXIT

if [[ "${BUILD_MODE:-changed}" == "changed" && -n "${BASE_SHA:-}" ]]; then
  if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    echo "BASE_SHA ${BASE_SHA} is not in this checkout. Building every Android project."
    BUILD_MODE=all
  fi
fi

gradlews=()
while IFS= read -r wrapper; do
  [[ -n "$wrapper" ]] || continue
  gradlews+=("$wrapper")
done < <(
  find . \
    -type d \( -name .git -o -name build -o -name target \) -prune -o \
    -type f -name gradlew -print \
    | sed 's#^\./##' \
    | sort
)

if [[ ${#gradlews[@]} -eq 0 ]]; then
  echo "No Gradle wrapper found. Nothing to build."
  exit 0
fi

# 0 when this merge touches the project, 1 otherwise.
project_changed() {
  local submission_root="$1"
  if [[ "${BUILD_MODE:-changed}" == "all" || -z "${BASE_SHA:-}" ]]; then
    return 0
  fi
  if [[ "$submission_root" == "$repo_root" ]]; then
    # A root-level app must not rebuild when only another submission changed.
    git diff --name-only "$BASE_SHA" HEAD -- \
      android src scripts Cargo.toml Cargo.lock rust-toolchain.toml \
      | grep -q .
  else
    local rel="${submission_root#"$repo_root"/}"
    git diff --name-only "$BASE_SHA" HEAD -- "$rel" | grep -q .
  fi
}

# Returns 0 when a native library was built, 1 when Gradle should handle it,
# 2 when the native build failed.
build_native() {
  local submission_root="$1"
  local gradle_dir="$2"
  local -a scripts=()
  local dir script cargo_dir jni_out

  for dir in "$submission_root/scripts" "$gradle_dir/scripts"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r script; do
      scripts+=("$script")
    done < <(find "$dir" -maxdepth 1 -type f -name 'build-android*.sh' | sort)
  done

  if [[ ${#scripts[@]} -gt 0 ]]; then
    for script in "${scripts[@]}"; do
      echo "Native build script: $script"
      # PichaLite's script also runs Gradle unless this is set.
      if ! PICHALITE_NATIVE_ONLY=1 bash "$script"; then
        return 2
      fi
    done
    return 0
  fi

  cargo_dir=""
  if [[ -f "$submission_root/Cargo.toml" ]]; then
    cargo_dir="$submission_root"
  elif [[ -f "$submission_root/rust/Cargo.toml" ]]; then
    cargo_dir="$submission_root/rust"
  fi

  jni_out=""
  if [[ -d "$gradle_dir/app" ]]; then
    jni_out="$gradle_dir/app/src/main/jniLibs"
  elif [[ -d "$gradle_dir/androidApp" ]]; then
    jni_out="$gradle_dir/androidApp/src/main/jniLibs"
  fi

  if [[ -n "$cargo_dir" && -n "$jni_out" ]]; then
    mkdir -p "$jni_out"
    echo "cargo ndk: $cargo_dir -> $jni_out"
    if ! (
      cd "$cargo_dir"
      cargo ndk -t arm64-v8a -o "$jni_out" build --release --lib
    ); then
      return 2
    fi
    return 0
  fi

  echo "No native build script or Cargo library. Leaving the native build to Gradle."
  return 1
}

# Sets gradle_dir, submission_root, and label for a wrapper path.
locate_project() {
  local wrapper="$1"
  local gradle_base
  gradle_dir="$repo_root/$(dirname "$wrapper")"
  gradle_base=$(basename "$gradle_dir")
  if [[ "$gradle_base" == "android" || "$gradle_base" == "client" ]]; then
    submission_root=$(dirname "$gradle_dir")
  else
    submission_root="$gradle_dir"
  fi
  if [[ "$submission_root" == "$repo_root" ]]; then
    label="root"
  else
    label="${submission_root#"$repo_root"/}"
  fi
}

affected=()
for wrapper in "${gradlews[@]}"; do
  locate_project "$wrapper"
  if project_changed "$submission_root"; then
    echo "Affected: $label"
    affected+=("$wrapper")
    should_build=true
  else
    echo "Skipping $label (unchanged in this pull request)."
  fi
done

if [[ "${DETECT_ONLY:-0}" == "1" ]]; then
  echo "Detect only. should_build=$should_build"
  exit 0
fi

if [[ ${#affected[@]} -eq 0 ]]; then
  echo "No Android project to build."
  exit 0
fi

for wrapper in "${affected[@]}"; do
  locate_project "$wrapper"

  echo "::group::Build $label"
  native_built=0
  if build_native "$submission_root" "$gradle_dir"; then
    native_built=1
  elif [[ $? -eq 1 ]]; then
    native_built=0
  else
    echo "::error::Native build failed for $label"
    failures=$((failures + 1))
    echo "::endgroup::"
    continue
  fi

  echo "Gradle assembleDebug in $gradle_dir"
  if ! (
    cd "$gradle_dir"
    # Skip a second Rust compile when Gradle's preBuild hook calls the same script.
    if [[ "$native_built" -eq 1 ]]; then
      export RUST_ANDROID_GRADLE_SKIP=1
    fi
    bash ./gradlew --no-daemon assembleDebug
  ); then
    echo "::error::APK build failed for $label"
    failures=$((failures + 1))
    echo "::endgroup::"
    continue
  fi

  slug=${label//\//-}
  while IFS= read -r apk; do
    cp "$apk" "$dist/${slug}-$(basename "$apk")"
    echo "APK: $dist/${slug}-$(basename "$apk")"
    apk_count=$((apk_count + 1))
  done < <(find "$gradle_dir" -path '*/outputs/apk/debug/*.apk' -type f | sort)
  echo "::endgroup::"
done

echo "Built $apk_count APK(s); $failures project(s) failed."
if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
